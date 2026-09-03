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

/// What `.fallbackToCheaper` does when the budget refuses the provider the router picked.
///
/// The action's promise is that the request moves to something cheaper, not that the
/// limit stops applying: every test here asserts on money actually reserved and billed,
/// because the failure this suite exists to prevent is a request that goes out and spends
/// without being counted.
@Suite("Budget fallback")
struct BudgetFallbackTests {
    static func pricedCloud(
        inputPerMillion: Double, outputPerMillion: Double
    ) -> ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .completion], maxContextTokens: 100_000,
            supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
            costPerMillionInputTokens: inputPerMillion,
            costPerMillionOutputTokens: outputPerMillion,
            estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
        )
    }

    /// `.priority` rather than `.smart`: the point of the test is which provider the
    /// *budget* chooses, so the routing order it starts from is pinned explicitly instead
    /// of being scored out of the machine's device and performance state.
    static func priority(_ order: [ProviderID]) -> RoutingPolicy {
        RoutingPolicy(strategy: .priority(order))
    }

    /// TokenUsage(10, 20) — what `TrackingMockProvider.generate` reports — priced at
    /// `capabilities`' rates.
    static func billedForOneGenerate(inputPerMillion: Double, outputPerMillion: Double) -> Double {
        (10 * inputPerMillion + 20 * outputPerMillion) / 1_000_000
    }

    @Test("A refused provider hands the request to the cheapest one that fits — reserved and billed")
    func fallbackProviderIsTheCheapestThatFitsAndIsBilled() async throws {
        let expensive = TrackingMockProvider(
            id: .anthropic, responseContent: "expensive",
            capabilities: Self.pricedCloud(inputPerMillion: 100, outputPerMillion: 500)
        )
        let middling = TrackingMockProvider(
            id: .openAI, responseContent: "middling",
            capabilities: Self.pricedCloud(inputPerMillion: 1, outputPerMillion: 5)
        )
        let cheapest = TrackingMockProvider(
            id: .gemini, responseContent: "cheapest",
            capabilities: Self.pricedCloud(inputPerMillion: 0.1, outputPerMillion: 0.1)
        )
        let spending = SpendingGuard(budgetLimit: 0.05, limitAction: .fallbackToCheaper)
        let ai = Arbiter { config in
            config.cloud(expensive)
            config.cloud(middling)
            config.cloud(cheapest)
            config.spendingGuard = spending
            config.routing(Self.priority([.anthropic, .openAI, .gemini]))
        }

        let response = try await ai.generate("Hello")

        // Anthropic is first in the routing order and estimates well past $0.05, so it is
        // refused. Refusals do not consume attempts — `refusedProvidersDoNotConsumeTheAttemptLimit`
        // pins that — so the chain reaches every candidate here regardless of the limit. OpenAI is next in that order and would fit — but the budget's question
        // is cost, so the chain re-orders and Gemini answers.
        #expect(response.provider == .gemini)
        #expect(response.content == "cheapest")
        #expect(expensive.callCount == 0)
        #expect(middling.callCount == 0)
        #expect(cheapest.callCount == 1)

        // The fallback was billed: the estimate was reserved and then settled at Gemini's
        // rates for the usage it reported. Nothing was charged at Anthropic's.
        let spent = await spending.currentSpend
        let expected = Self.billedForOneGenerate(inputPerMillion: 0.1, outputPerMillion: 0.1)
        #expect(abs(spent - expected) < 1e-12)
        #expect(spent > 0)
    }

    @Test("Refusals do not spend the attempt limit, so a fitting provider is still reached")
    func refusedProvidersDoNotConsumeTheAttemptLimit() async throws {
        let expensive = TrackingMockProvider(
            id: .anthropic, responseContent: "expensive",
            capabilities: Self.pricedCloud(inputPerMillion: 100, outputPerMillion: 500)
        )
        let alsoExpensive = TrackingMockProvider(
            id: .openAI, responseContent: "also expensive",
            capabilities: Self.pricedCloud(inputPerMillion: 90, outputPerMillion: 450)
        )
        let affordable = TrackingMockProvider(
            id: .gemini, responseContent: "affordable",
            capabilities: Self.pricedCloud(inputPerMillion: 0.1, outputPerMillion: 0.1)
        )
        let spending = SpendingGuard(budgetLimit: 0.05, limitAction: .fallbackToCheaper)
        // One fallback: the attempt limit is two providers, and the only one that fits is
        // third in the routing order. It is still reached, because the two refusals ahead
        // of it were never sent and so are not attempts.
        let ai = Arbiter { config in
            config.cloud(expensive)
            config.cloud(alsoExpensive)
            config.cloud(affordable)
            config.spendingGuard = spending
            config.routing(RoutingPolicy(
                strategy: .priority([.anthropic, .openAI, .gemini]), maxFallbackProviders: 1
            ))
        }

        let response = try await ai.generate("Hello")

        #expect(response.provider == .gemini)
        #expect(expensive.callCount == 0)
        #expect(alsoExpensive.callCount == 0)
        #expect(affordable.callCount == 1)
        #expect(await spending.currentSpend > 0)
    }

    @Test("When nothing fits the budget the request is refused, not sent unreserved")
    func nothingThatFitsRefusesRatherThanSpendingUnreserved() async throws {
        let expensive = TrackingMockProvider(
            id: .anthropic, responseContent: "expensive",
            capabilities: Self.pricedCloud(inputPerMillion: 100, outputPerMillion: 500)
        )
        let alsoExpensive = TrackingMockProvider(
            id: .openAI, responseContent: "also expensive",
            capabilities: Self.pricedCloud(inputPerMillion: 80, outputPerMillion: 400)
        )
        let spending = SpendingGuard(budgetLimit: 0.05, limitAction: .fallbackToCheaper)
        let ai = Arbiter { config in
            config.cloud(expensive)
            config.cloud(alsoExpensive)
            config.spendingGuard = spending
            config.routing(Self.priority([.anthropic, .openAI]))
        }

        var thrown: (any Error)?
        do {
            _ = try await ai.generate("Hello")
        } catch {
            thrown = error
        }

        let failure = try #require(thrown as? ArbiterError)
        guard case .budgetExceeded(let spent, let limit) = failure else {
            Issue.record("Expected budgetExceeded — no candidate fits — got \(failure)")
            return
        }
        #expect(spent == 0)
        #expect(limit == 0.05)

        // Refused means refused: neither provider was called and nothing was reserved.
        #expect(expensive.callCount == 0)
        #expect(alsoExpensive.callCount == 0)
        #expect(await spending.currentSpend == 0)
    }

    @Test("A stream refused on budget falls back rather than streaming unreserved")
    func streamingFallsBackAndBillsTheProviderThatAnswered() async throws {
        let expensive = TrackingMockProvider(
            id: .anthropic, responseContent: "expensive",
            capabilities: Self.pricedCloud(inputPerMillion: 100, outputPerMillion: 500)
        )
        let cheap = TrackingMockProvider(
            id: .openAI, responseContent: "cheap",
            capabilities: Self.pricedCloud(inputPerMillion: 0.1, outputPerMillion: 0.1)
        )
        let spending = SpendingGuard(budgetLimit: 0.05, limitAction: .fallbackToCheaper)
        let ai = Arbiter { config in
            config.cloud(expensive)
            config.cloud(cheap)
            config.spendingGuard = spending
            config.routing(Self.priority([.anthropic, .openAI]))
        }

        var received = ""
        for try await chunk in ai.stream("Hello") {
            received += chunk.delta
        }

        #expect(received == "cheap")
        #expect(expensive.callCount == 0)
        // TokenUsage(10, 5) — what `TrackingMockProvider.stream` reports — at OpenAI's rates.
        let spent = await spending.currentSpend
        #expect(abs(spent - (10 * 0.1 + 5 * 0.1) / 1_000_000) < 1e-12)
        #expect(spent > 0)
    }

    @Test("A refusal carries the limit that caused it, so callers are not told the wrong one")
    func refusalNamesTheLimitThatStoppedTheRequest() async throws {
        let spending = SpendingGuard(
            budgetLimit: 100.0, dailyRequestLimit: 1, limitAction: .fallbackToCheaper
        )
        _ = try await spending.reserveBudget(estimatedCost: 0.01)

        switch await spending.attemptReservation(estimatedCost: 0.01) {
        case .reserved:
            Issue.record("Expected the daily limit to refuse the second request")
        case .refused(let error):
            guard case .dailyLimitExceeded(let count, let limit) = error else {
                Issue.record("Expected dailyLimitExceeded, got \(error)")
                return
            }
            #expect(count == 1)
            #expect(limit == 1)
        }
    }
}
