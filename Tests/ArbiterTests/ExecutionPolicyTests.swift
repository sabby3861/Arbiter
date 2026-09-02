// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

/// The precedence table: which guard or recovery mechanism decides a request's fate first.
@Suite("Execution policy")
struct ExecutionPolicyTests {
    @Test func stagesRunInPrecedenceOrder() {
        #expect(ExecutionPolicy.stages == [
            .budgetGuard, .privacy, .health, .providerRetry, .providerFallback,
        ])
    }

    @Test func theAttemptLimitCountsTheFirstProviderPlusItsFallbacks() {
        let policy = RoutingPolicy(maxFallbackProviders: 2)
        #expect(ExecutionPolicy(routingPolicy: policy, retry: nil, timeout: nil)
            .providerAttemptLimit == 3)

        var noFallback = policy
        noFallback.fallbackEnabled = false
        #expect(ExecutionPolicy(routingPolicy: noFallback, retry: nil, timeout: nil)
            .providerAttemptLimit == 1)
    }

    // MARK: - Budget comes first

    @Test func aRequestThatBreachesTheBudgetNeverReachesTheProvider() async throws {
        let provider = TrackingMockProvider(id: .anthropic)
        let ai = Arbiter {
            $0.cloud(provider)
            $0.spendingLimit(0.0)
        }

        var thrown: (any Error)?
        do {
            _ = try await ai.generate("Hello")
        } catch {
            thrown = error
        }

        let failure = try #require(thrown as? ArbiterError)
        guard case .allProvidersFailed(let attempts) = failure else {
            Issue.record("Expected allProvidersFailed, got \(failure)")
            return
        }
        // The budget guard is what stopped it, and it stopped it before the call.
        #expect(attempts.count == 1)
        if case .budgetExceeded = attempts[0].1 as? ArbiterError {} else {
            Issue.record("Expected budgetExceeded, got \(attempts[0].1)")
        }
        #expect(provider.callCount == 0)
    }

    // MARK: - Then privacy

    @Test func privacyDecidesTheTierBeforeHealthOrdersTheCandidates() async throws {
        let cloud = TrackingMockProvider(id: .anthropic, responseContent: "cloud")
        let ai = Arbiter {
            $0.cloud(cloud)
            $0.local(MockLocalProvider())
            $0.routing(.smart)
        }

        let response = try await ai.generate(
            "Something sensitive", options: RequestOptions(privacyRequired: true)
        )

        #expect(response.provider == .mlx)
        #expect(cloud.callCount == 0)
    }

    // MARK: - Then in-provider retry, then fallback

    @Test func aTransientFailureRetriesTheSameProviderBeforeFallingOver() async throws {
        // Previously retry was only wired up when fallback was *off*. It is now a stage of
        // its own, so a transient failure costs a retry before it costs a provider.
        let primary = TrackingMockProvider(id: .anthropic, failCount: 1, responseContent: "primary")
        let secondary = TrackingMockProvider(id: .openAI, responseContent: "secondary")
        let ai = Arbiter {
            $0.cloud(primary)
            $0.cloud(secondary)
            $0.routing(.firstAvailable)
            $0.retry(maxAttempts: 2, baseDelay: .milliseconds(1))
        }

        let response = try await ai.generate("Hello")

        #expect(response.content == "primary")
        #expect(primary.callCount == 2)
        #expect(secondary.callCount == 0)
    }

    @Test func aPermanentFailureSkipsTheRetryAndFallsOverImmediately() async throws {
        let primary = MockProvider(
            id: .anthropic, shouldError: .authenticationFailed(.anthropic)
        )
        let secondary = TrackingMockProvider(id: .openAI, responseContent: "secondary")
        let ai = Arbiter {
            $0.cloud(primary)
            $0.cloud(secondary)
            $0.routing(.firstAvailable)
            $0.retry(maxAttempts: 3, baseDelay: .milliseconds(1))
        }

        let response = try await ai.generate("Hello")

        #expect(response.content == "secondary")
        #expect(secondary.callCount == 1)
    }

    @Test func fallbackStopsAtTheConfiguredNumberOfProviders() async throws {
        let first = TrackingMockProvider(id: .anthropic, failCount: 10)
        let second = TrackingMockProvider(id: .openAI, failCount: 10)
        let third = TrackingMockProvider(id: .gemini, failCount: 10)
        var policy = RoutingPolicy.firstAvailable
        policy.maxFallbackProviders = 1

        let ai = Arbiter {
            $0.cloud(first)
            $0.cloud(second)
            $0.cloud(third)
            $0.routing(policy)
        }

        await #expect(throws: ArbiterError.self) { try await ai.generate("Hello") }
        #expect(first.callCount == 1)
        #expect(second.callCount == 1)
        #expect(third.callCount == 0)
    }

    @Test @available(*, deprecated, message: "Exercises the deprecated alias on purpose")
    func theRenamedFallbackCountKeepsItsOldName() {
        var policy = RoutingPolicy(maxFallbackProviders: 2)
        #expect(policy.maxRetries == 2)
        policy.maxRetries = 4
        #expect(policy.maxFallbackProviders == 4)
        #expect(RoutingPolicy(maxRetries: 7).maxFallbackProviders == 7)
    }

    // MARK: - Quality retry

    @Test func theQualityRetryGoesThroughTheSameExecutionPathAsTheFirstAttempt() async throws {
        // A first response the validator calls low quality, then a good one. The retry must
        // be a full execution — budget, timeout, cost tracking — not a bare provider call.
        let provider = ScriptedProvider(script: [
            .answerTurn("um"),
            .answerTurn("A complete and useful answer to the question that was asked."),
        ])
        let ai = Arbiter {
            $0.cloud(provider)
            $0.responseValidation(.enabled)
        }

        let response = try await ai.generate(
            "Explain in detail how a hash table resolves collisions, with examples."
        )

        #expect(provider.callCount == 2)
        #expect(response.content.hasPrefix("A complete"))
    }
}
