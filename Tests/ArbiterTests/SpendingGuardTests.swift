// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("SpendingGuard Advanced")
struct SpendingGuardAdvancedTests {
    @Test func perRequestLimitBlocks() async throws {
        let guard_ = SpendingGuard(budgetLimit: 10.0, perRequestLimit: 0.05)

        await #expect(throws: ArbiterError.self) {
            _ = try await guard_.reserveBudget(estimatedCost: 0.10)
        }
    }

    @Test func perRequestLimitAllowsSmallRequests() async throws {
        let guard_ = SpendingGuard(budgetLimit: 10.0, perRequestLimit: 0.50)
        let reservation = try await guard_.reserveBudget(estimatedCost: 0.10)
        #expect(reservation?.estimatedCost == 0.10)
    }

    @Test func dailyRequestLimitThrowsDailyLimitExceeded() async throws {
        let guard_ = SpendingGuard(budgetLimit: 100.0, dailyRequestLimit: 3)

        _ = try await guard_.reserveBudget(estimatedCost: 0.01)
        _ = try await guard_.reserveBudget(estimatedCost: 0.01)
        _ = try await guard_.reserveBudget(estimatedCost: 0.01)

        do {
            _ = try await guard_.reserveBudget(estimatedCost: 0.01)
            Issue.record("Expected dailyLimitExceeded to be thrown")
        } catch let error as ArbiterError {
            guard case .dailyLimitExceeded(let count, let limit) = error else {
                Issue.record("Expected dailyLimitExceeded but got \(error)")
                return
            }
            #expect(count == 3)
            #expect(limit == 3)
        }
    }

    @Test func dailyRequestLimitCountsCorrectly() async throws {
        let guard_ = SpendingGuard(budgetLimit: 100.0, dailyRequestLimit: 5)

        for _ in 0..<5 {
            _ = try await guard_.reserveBudget(estimatedCost: 0.001)
        }

        await #expect(throws: ArbiterError.self) {
            _ = try await guard_.reserveBudget(estimatedCost: 0.001)
        }
    }

    @Test func effectiveMaxTokensReturnsConfigured() {
        let guard_ = SpendingGuard(budgetLimit: 10.0, maxTokensPerRequest: 2048)
        #expect(guard_.effectiveMaxTokens == 2048)
    }

    @Test func effectiveMaxTokensNilByDefault() {
        let guard_ = SpendingGuard(budgetLimit: 10.0)
        #expect(guard_.effectiveMaxTokens == nil)
    }

    @Test func blockActionDoesNotFallback() {
        let guard_ = SpendingGuard(budgetLimit: 10.0, limitAction: .block)
        #expect(!guard_.shouldFallbackOnBudgetExceeded)
    }

    @Test func fallbackToCheaperActionFallsBack() {
        let guard_ = SpendingGuard(budgetLimit: 10.0, limitAction: .fallbackToCheaper)
        #expect(guard_.shouldFallbackOnBudgetExceeded)
    }

    @Test func fallbackToCheaperReturnsNilOnDailyLimit() async throws {
        let guard_ = SpendingGuard(
            budgetLimit: 100.0,
            dailyRequestLimit: 1,
            limitAction: .fallbackToCheaper
        )
        _ = try await guard_.reserveBudget(estimatedCost: 0.01)
        // Second request hits daily limit — should return nil (fallback) not throw
        let reservation = try await guard_.reserveBudget(estimatedCost: 0.01)
        #expect(reservation == nil)
    }

    @Test func perRequestLimitCheckedBeforeBudget() async throws {
        let guard_ = SpendingGuard(
            budgetLimit: 100.0,
            perRequestLimit: 0.01
        )

        await #expect(throws: ArbiterError.self) {
            _ = try await guard_.reserveBudget(estimatedCost: 0.05)
        }

        // Budget should not have been charged
        let remaining = await guard_.remainingBudget
        #expect(remaining == 100.0)
    }

    @Test func reservationFinalizationAdjustsTotal() async throws {
        let guard_ = SpendingGuard(budgetLimit: 1.0)

        let reservation = try #require(try await guard_.reserveBudget(estimatedCost: 0.50))
        #expect(await guard_.remainingBudget == 0.50)

        await guard_.finalizeReservation(reservation, actualCost: 0.30)
        #expect(await guard_.remainingBudget == 0.70)
    }

    @Test func resetClearsAllState() async throws {
        let guard_ = SpendingGuard(budgetLimit: 1.0, dailyRequestLimit: 100)

        _ = try await guard_.reserveBudget(estimatedCost: 0.50)
        await guard_.reset()

        #expect(await guard_.currentSpend == 0)
        #expect(await guard_.remainingBudget == 1.0)
    }
}
