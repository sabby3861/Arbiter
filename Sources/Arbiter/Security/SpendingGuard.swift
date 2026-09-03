// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "SpendingGuard")

/// What to do when a spending limit is exceeded.
public enum LimitAction: Sendable {
    /// Throw an error and block the request
    case block
    /// Fall back to a cheaper or free provider
    case fallbackToCheaper
}

/// Tracks and enforces spending limits for cloud AI providers.
///
/// All budget operations are serialized through actor isolation,
/// preventing TOCTOU races between checking and recording spend.
public actor SpendingGuard {
    private var totalSpent: Double = 0
    private let budgetLimit: Double
    private let perRequestLimit: Double?
    private let maxTokensPerRequest: Int?
    private let dailyRequestLimit: Int?
    private let limitAction: LimitAction
    private var dailyRequestCount: Int = 0
    private var lastResetDay: String = ""

    public init(
        budgetLimit: Double,
        perRequestLimit: Double? = nil,
        maxTokensPerRequest: Int? = nil,
        dailyRequestLimit: Int? = nil,
        limitAction: LimitAction = .block
    ) {
        self.budgetLimit = budgetLimit
        self.perRequestLimit = perRequestLimit
        self.maxTokensPerRequest = maxTokensPerRequest
        self.dailyRequestLimit = dailyRequestLimit
        self.limitAction = limitAction
    }

    /// Atomically check the budget and reserve the estimated cost.
    ///
    /// When `limitAction` is `.block`, throws `budgetExceeded` on any limit violation.
    /// When `limitAction` is `.fallbackToCheaper`, returns `nil` to signal the caller
    /// should fall back to a cheaper or free provider instead of blocking.
    ///
    /// That `nil` is a *refusal*, not permission: nothing was reserved and nothing will
    /// be billed, so a caller that goes on to spend money on the strength of it spends
    /// it untracked. Callers inside the package use `attemptReservation(estimatedCost:)`
    /// instead, which hands back the refusal's reason so it cannot be mistaken for a
    /// provider that costs nothing.
    public func reserveBudget(estimatedCost: Double) throws -> Reservation? {
        switch attemptReservation(estimatedCost: estimatedCost) {
        case .reserved(let reservation):
            return reservation
        case .refused(let error):
            if limitAction == .fallbackToCheaper { return nil }
            throw error
        }
    }

    /// What an atomic budget check decided.
    ///
    /// Deliberately internal: it exists so the runtime can fail closed on a refusal, not
    /// to widen the package's configuration surface.
    enum ReservationOutcome: Sendable {
        case reserved(Reservation)
        /// The limit that stopped the request, as the error a caller with nowhere
        /// cheaper to go should surface.
        case refused(ArbiterError)
    }

    /// Atomically check every limit and, if the request fits, reserve its estimated cost.
    ///
    /// The check and the reservation are one actor hop, so two concurrent requests cannot
    /// both see room for the last of the budget. `limitAction` does not enter into it:
    /// this reports what the limits say, and the caller decides whether that means
    /// blocking or looking for a cheaper provider.
    func attemptReservation(estimatedCost: Double) -> ReservationOutcome {
        resetDayIfNeeded()

        if let perRequest = perRequestLimit, estimatedCost > perRequest {
            logger.warning("Per-request limit exceeded: $\(estimatedCost, privacy: .public) > $\(perRequest, privacy: .public)")
            return .refused(.budgetExceeded(spent: totalSpent, limit: budgetLimit))
        }

        if let dailyLimit = dailyRequestLimit, dailyRequestCount >= dailyLimit {
            logger.warning("Daily request limit reached: \(self.dailyRequestCount, privacy: .public)")
            return .refused(.dailyLimitExceeded(count: dailyRequestCount, limit: dailyLimit))
        }

        let projectedSpend = totalSpent + estimatedCost
        if projectedSpend > budgetLimit {
            logger.warning("Budget exceeded: spent=$\(self.totalSpent, privacy: .public) est=$\(estimatedCost, privacy: .public) limit=$\(self.budgetLimit, privacy: .public)")
            return .refused(.budgetExceeded(spent: totalSpent, limit: budgetLimit))
        }

        totalSpent += estimatedCost
        dailyRequestCount += 1
        logger.debug("Reserved $\(estimatedCost, privacy: .public), total now: $\(self.totalSpent, privacy: .public)")
        return .reserved(Reservation(estimatedCost: estimatedCost))
    }

    /// Finalize a reservation with the actual cost.
    public func finalizeReservation(_ reservation: Reservation, actualCost: Double) {
        let adjustment = actualCost - reservation.estimatedCost
        totalSpent += adjustment
        logger.debug("Finalized: estimated=$\(reservation.estimatedCost, privacy: .public) actual=$\(actualCost, privacy: .public) total=$\(self.totalSpent, privacy: .public)")
    }

    /// Current total amount spent in USD
    public var currentSpend: Double { totalSpent }

    /// Remaining budget in USD
    public var remainingBudget: Double { max(0, budgetLimit - totalSpent) }

    /// Whether the guard should fall back to cheaper providers on budget exceeded
    public nonisolated var shouldFallbackOnBudgetExceeded: Bool { limitAction == .fallbackToCheaper }

    /// Effective max tokens per request (nil = no limit)
    public nonisolated var effectiveMaxTokens: Int? { maxTokensPerRequest }

    /// Reset the spending tracker
    public func reset() {
        totalSpent = 0
        dailyRequestCount = 0
        logger.info("Spending tracker reset")
    }

    /// Represents a reserved portion of the spending budget
    public struct Reservation: Sendable {
        public let estimatedCost: Double
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func resetDayIfNeeded() {
        let today = Self.dayFormatter.string(from: Date())
        if lastResetDay != today {
            dailyRequestCount = 0
            lastResetDay = today
        }
    }
}
