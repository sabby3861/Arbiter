// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("Integration")
struct IntegrationTests {
    // MARK: - Fallback chain with call tracking

    @Test func fallbackVerifiesFirstProviderWasAttempted() async throws {
        let primary = TrackingMockProvider(id: .anthropic, failCount: 1)
        let secondary = TrackingMockProvider(id: .openAI, responseContent: "Fallback worked")

        let ai = SwiftAI {
            $0.cloud(primary)
            $0.cloud(secondary)
            $0.routing(.smart)
        }

        let response = try await ai.generate("Hello")
        #expect(response.content == "Fallback worked")
        #expect(response.provider == .openAI)
        #expect(primary.callCount == 1)
        #expect(secondary.callCount == 1)
    }

    @Test func fallbackDisabledStopsAfterFirstFailure() async throws {
        var policy = RoutingPolicy.smart
        policy.fallbackEnabled = false

        let ai = SwiftAI {
            $0.cloud(MockProvider(
                id: .anthropic,
                shouldError: .networkError(underlying: URLError(.timedOut))
            ))
            $0.cloud(MockProvider(id: .openAI, responseContent: "Should not reach"))
            $0.routing(policy)
        }

        await #expect(throws: SwiftAIError.self) {
            try await ai.generate("Hello")
        }
    }

    @Test func maxRetriesLimitsFallbackAttempts() async throws {
        var policy = RoutingPolicy.smart
        policy.maxRetries = 0

        let ai = SwiftAI {
            $0.cloud(MockProvider(
                id: .anthropic,
                shouldError: .networkError(underlying: URLError(.timedOut))
            ))
            $0.cloud(MockProvider(id: .openAI, responseContent: "Fallback"))
            $0.routing(policy)
        }

        await #expect(throws: SwiftAIError.self) {
            try await ai.generate("Hello")
        }
    }

    @Test func fallbackChainTriesMultipleProviders() async throws {
        let primary = TrackingMockProvider(id: .anthropic, failCount: 1)
        let secondary = TrackingMockProvider(id: .openAI, failCount: 1)

        var policy = RoutingPolicy(strategy: .priority([.anthropic, .openAI, .mlx]))
        policy.fallbackEnabled = true
        policy.maxRetries = 3

        let ai = SwiftAI {
            $0.cloud(primary)
            $0.cloud(secondary)
            $0.local(MockLocalProvider())
            $0.routing(policy)
        }

        let response = try await ai.generate("Hello")
        #expect(response.provider == .mlx)
        #expect(primary.callCount >= 1)
        #expect(secondary.callCount >= 1)
    }

    // MARK: - Streaming fallback

    @Test func streamingFallbackToSecondProvider() async throws {
        let primary = TrackingMockProvider(id: .anthropic, failCount: 1)
        let secondary = TrackingMockProvider(id: .openAI, responseContent: "Stream fallback")

        let ai = SwiftAI {
            $0.cloud(primary)
            $0.cloud(secondary)
            $0.routing(.smart)
        }

        var chunks: [AIStreamChunk] = []
        let stream = ai.stream("Hello")
        for try await chunk in stream {
            chunks.append(chunk)
        }

        #expect(!chunks.isEmpty)
        #expect(primary.callCount >= 1)
        #expect(secondary.callCount == 1)
    }

    // MARK: - Tags end-to-end

    @Test func tagsRouteToLocalProvider() async throws {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic, responseContent: "Cloud"))
            $0.local(MockLocalProvider())
            $0.routing(.smart)
        }

        let options = RequestOptions(tags: [.health])
        let response = try await ai.generate("My blood pressure", options: options)
        #expect(response.provider == .mlx)
    }

    @Test func tagsWithOnlyCloudFails() async throws {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic, responseContent: "Cloud"))
            $0.routing(.smart)
        }

        let options = RequestOptions(tags: [.private])
        await #expect(throws: SwiftAIError.self) {
            try await ai.generate("Secret data", options: options)
        }
    }

    // MARK: - Configuration

    @Test func privacyGuardConfigWiredCorrectly() async throws {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic, responseContent: "Cloud"))
            $0.local(MockLocalProvider())
            $0.privacy(.localOnly)
            $0.routing(.smart)
        }

        let response = try await ai.generate("Hello")
        #expect(response.provider == .mlx)
    }

    @Test func systemProviderRegistered() async throws {
        let ai = SwiftAI {
            $0.system(MockLocalProvider())
        }

        let response = try await ai.generate("Hello")
        #expect(response.provider == .mlx)
    }

    @Test func spendingLimitBlockAction() async throws {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic))
            $0.spendingLimit(0.0000001, action: .block)
        }

        await #expect(throws: SwiftAIError.self) {
            try await ai.generate("Hello")
        }
    }

    // MARK: - Conflicting flags

    @Test func forceLocalAndForceCloudConflictYieldsEmpty() async throws {
        var policy = RoutingPolicy.smart
        policy.forceLocal = true
        policy.forceCloud = true

        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic))
            $0.local(MockLocalProvider())
            $0.routing(policy)
        }

        await #expect(throws: SwiftAIError.self) {
            try await ai.generate("Hello")
        }
    }

    // MARK: - Edge cases

    @Test func emptyPromptStillWorks() async throws {
        let ai = SwiftAI(provider: MockProvider(responseContent: "Response"))
        let response = try await ai.generate("")
        #expect(response.content == "Response")
    }

    @Test func zeroProvidersConfigured() async throws {
        let ai = SwiftAI { _ in }

        await #expect(throws: SwiftAIError.self) {
            try await ai.generate("Hello")
        }
    }

    @Test func emptyMessagesArrayChat() async throws {
        let ai = SwiftAI(provider: MockProvider(responseContent: "Response"))
        // Empty messages should still route (provider decides what to do)
        let response = try await ai.chat([])
        #expect(response.content == "Response")
    }

    // MARK: - Request builder

    @Test func aiRequestWithTagsBuilder() {
        let request = AIRequest.chat("Test")
            .withTags([.health, .personal])
        #expect(request.tags.count == 2)
        #expect(request.tags.contains(.health))
        #expect(request.tags.contains(.personal))
    }

    @Test func aiRequestDefaultTagsEmpty() {
        let request = AIRequest.chat("Test")
        #expect(request.tags.isEmpty)
    }

    @Test func mlxFactoryCreatesProvider() throws {
        let factory = ProviderFactory.mlx(.auto)
        let provider = try factory.createProvider()
        #expect(provider.id == .mlx)
    }

    @Test func appleFoundationFactoryCreatesProvider() throws {
        let factory = ProviderFactory.appleFoundation()
        let provider = try factory.createProvider()
        #expect(provider.id == .appleFoundation)
    }

    @Test func threeTierConfigurationCompiles() {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic))
            $0.local(MLXProvider(.auto))
            $0.system(AppleFoundationProvider())
            $0.routing(.smart)
        }
        _ = ai
    }
}
