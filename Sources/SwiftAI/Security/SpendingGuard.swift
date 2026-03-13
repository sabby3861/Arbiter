// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "SpendingGuard")

/// Tracks and enforces spending limits for cloud AI providers.
///
/// All budget operations are serialized through actor isolation,
/// preventing TOCTOU races between checking and recording spend.
public actor SpendingGuard {
    private var totalSpent: Double = 0
    private let budgetLimit: Double

    /// Create a spending guard with a budget limit in USD
    /// - Parameter budgetLimit: Maximum allowed spend in USD
    public init(budgetLimit: Double) {
        self.budgetLimit = budgetLimit
    }

    /// Atomically check the budget and reserve the estimated cost.
    ///
    /// This prevents TOCTOU races — the cost is reserved immediately so concurrent
    /// requests can't both pass the check before either records spending.
    /// - Parameter estimatedCost: The estimated cost in USD for the upcoming request
    /// - Returns: A `Reservation` that must be finalized with the actual cost when the request completes
    public func reserveBudget(estimatedCost: Double) throws -> Reservation {
        let projectedSpend = totalSpent + estimatedCost
        if projectedSpend > budgetLimit {
            logger.warning("Budget exceeded: spent=$\(self.totalSpent, privacy: .public) est=$\(estimatedCost, privacy: .public) limit=$\(self.budgetLimit, privacy: .public)")
            throw SwiftAIError.budgetExceeded(spent: totalSpent, limit: budgetLimit)
        }

        totalSpent += estimatedCost
        logger.debug("Reserved $\(estimatedCost, privacy: .public), total now: $\(self.totalSpent, privacy: .public)")
        return Reservation(estimatedCost: estimatedCost)
    }

    /// Finalize a reservation with the actual cost.
    ///
    /// Adjusts the running total by replacing the estimated cost with the actual cost.
    /// If the request was cancelled, pass `actualCost: 0` to release the reservation.
    public func finalizeReservation(_ reservation: Reservation, actualCost: Double) {
        let adjustment = actualCost - reservation.estimatedCost
        totalSpent += adjustment
        logger.debug("Finalized: estimated=$\(reservation.estimatedCost, privacy: .public) actual=$\(actualCost, privacy: .public) total=$\(self.totalSpent, privacy: .public)")
    }

    /// Current total amount spent in USD
    public var currentSpend: Double { totalSpent }

    /// Remaining budget in USD
    public var remainingBudget: Double { max(0, budgetLimit - totalSpent) }

    /// Reset the spending tracker (e.g., for a new billing period)
    public func reset() {
        totalSpent = 0
        logger.info("Spending tracker reset")
    }

    /// Represents a reserved portion of the spending budget
    public struct Reservation: Sendable {
        let estimatedCost: Double
    }
}
