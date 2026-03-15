// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
import Foundation
@testable import Arbiter

@Suite("FallbackChain")
struct FallbackChainTests {
    @Test("Uses primary provider when healthy")
    func primarySuccess() async throws {
        let chain = FallbackChain(maxFallbacks: 2)
        let primary = MockProvider(id: .anthropic, responseContent: "primary response")
        let fallback = MockProvider(id: .openAI, responseContent: "fallback response")
        let request = AIRequest.chat("Hello")

        let response = try await chain.execute(
            providers: [primary, fallback],
            providerOrder: [.anthropic, .openAI]
        ) { provider in
            try await provider.generate(request)
        }

        #expect(response.content == "primary response")
        #expect(response.provider == .anthropic)
    }

    @Test("Falls back to secondary on primary failure")
    func fallbackOnPrimaryFailure() async throws {
        let chain = FallbackChain(maxFallbacks: 2, retryDelay: .milliseconds(10))
        let primary = MockProvider(
            id: .anthropic,
            shouldError: .networkError(underlying: URLError(.timedOut))
        )
        let fallback = MockProvider(id: .openAI, responseContent: "fallback response")
        let request = AIRequest.chat("Hello")

        let response = try await chain.execute(
            providers: [primary, fallback],
            providerOrder: [.anthropic, .openAI]
        ) { provider in
            try await provider.generate(request)
        }

        #expect(response.content == "fallback response")
        #expect(response.provider == .openAI)
    }

    @Test("Throws allProvidersFailed when all fail")
    func allProvidersFail() async throws {
        let chain = FallbackChain(maxFallbacks: 1, retryDelay: .milliseconds(10))
        let provider1 = MockProvider(
            id: .anthropic,
            shouldError: .networkError(underlying: URLError(.timedOut))
        )
        let provider2 = MockProvider(
            id: .openAI,
            shouldError: .networkError(underlying: URLError(.timedOut))
        )
        let request = AIRequest.chat("Hello")

        do {
            _ = try await chain.execute(
                providers: [provider1, provider2],
                providerOrder: [.anthropic, .openAI]
            ) { provider in
                try await provider.generate(request)
            }
            Issue.record("Expected allProvidersFailed error")
        } catch let error as ArbiterError {
            if case .allProvidersFailed(let attempts) = error {
                #expect(attempts.count >= 2)
            } else {
                Issue.record("Expected allProvidersFailed, got \(error)")
            }
        }
    }

    @Test("Does not fallback on permanent errors")
    func noFallbackOnAuthError() async throws {
        let chain = FallbackChain(maxFallbacks: 2, retryDelay: .milliseconds(10))
        let primary = MockProvider(
            id: .anthropic,
            shouldError: .authenticationFailed(.anthropic)
        )
        let fallback = MockProvider(id: .openAI, responseContent: "fallback")
        let request = AIRequest.chat("Hello")

        do {
            _ = try await chain.execute(
                providers: [primary, fallback],
                providerOrder: [.anthropic, .openAI]
            ) { provider in
                try await provider.generate(request)
            }
            Issue.record("Expected auth error")
        } catch let error as ArbiterError {
            if case .authenticationFailed = error {
                // Auth errors should not trigger fallback
            } else {
                Issue.record("Expected authenticationFailed, got \(error)")
            }
        }
    }

    @Test("Respects maxFallbacks limit")
    func maxFallbacksLimit() async throws {
        let chain = FallbackChain(maxFallbacks: 1, retryDelay: .milliseconds(10))
        let providers = [
            MockProvider(id: .anthropic, shouldError: .networkError(underlying: URLError(.timedOut))),
            MockProvider(id: .openAI, shouldError: .networkError(underlying: URLError(.timedOut))),
            MockProvider(id: .gemini, responseContent: "third provider"),
        ]
        let request = AIRequest.chat("Hello")

        do {
            _ = try await chain.execute(
                providers: providers,
                providerOrder: [.anthropic, .openAI, .gemini]
            ) { provider in
                try await provider.generate(request)
            }
            Issue.record("Expected failure — third provider should not be tried")
        } catch {
            // maxFallbacks: 1 means try at most 2 providers (primary + 1 fallback)
        }
    }
}
