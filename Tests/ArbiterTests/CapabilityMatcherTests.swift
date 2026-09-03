// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("CapabilityMatcher")
struct CapabilityMatcherTests {
    let cloudCaps = ProviderCapabilities(
        supportedTasks: [.chat], maxContextTokens: 200_000,
        supportsStreaming: true, supportsToolCalling: true, supportsImageInput: true,
        costPerMillionInputTokens: 3.0, costPerMillionOutputTokens: 15.0,
        estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
    )

    let localCaps = ProviderCapabilities(
        supportedTasks: [.chat], maxContextTokens: 8_000,
        supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
        costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
        estimatedLatency: .fast, privacyLevel: .onDevice
    )

    @Test func balancedWeightsProducePositiveScore() {
        let request = AIRequest.chat("Hello")
        let score = CapabilityMatcher.score(
            providerID: .anthropic, capabilities: cloudCaps,
            for: request, weights: .balanced
        )
        #expect(score.baseScore > 0)
        #expect(score.adjustedScore > 0)
    }

    @Test func toolCallingBoostsCapabilityScore() {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get weather",
            inputSchema: .object(["location": .string("city")])
        )
        let request = AIRequest.chat("What's the weather?").withTools([tool])

        // Use capability-heavy weights to isolate the tool calling factor
        let capWeights = ScoringWeights(capability: 5.0, quality: 0.1, latency: 0.1, privacy: 0.1, cost: 0.1)

        let withTools = CapabilityMatcher.score(
            providerID: .anthropic, capabilities: cloudCaps,
            for: request, weights: capWeights
        )
        let withoutTools = CapabilityMatcher.score(
            providerID: .ollama, capabilities: localCaps,
            for: request, weights: capWeights
        )

        #expect(withTools.baseScore > withoutTools.baseScore)
    }

    @Test func privacyFirstWeightsBoostOnDevice() {
        let request = AIRequest.chat("Hello")

        let cloudScore = CapabilityMatcher.score(
            providerID: .anthropic, capabilities: cloudCaps,
            for: request, weights: .privacyFirst
        )
        let localScore = CapabilityMatcher.score(
            providerID: .ollama, capabilities: localCaps,
            for: request, weights: .privacyFirst
        )

        #expect(localScore.baseScore > cloudScore.baseScore)
    }

    @Test func costOptimizedPrefersFreeProviders() {
        let request = AIRequest.chat("Hello")

        let cloudScore = CapabilityMatcher.score(
            providerID: .anthropic, capabilities: cloudCaps,
            for: request, weights: .costOptimized
        )
        let localScore = CapabilityMatcher.score(
            providerID: .ollama, capabilities: localCaps,
            for: request, weights: .costOptimized
        )

        #expect(localScore.baseScore > cloudScore.baseScore)
    }

    @Test func qualityFirstPrefersExpensiveProviders() {
        let request = AIRequest.chat("Hello")

        let cloudScore = CapabilityMatcher.score(
            providerID: .anthropic, capabilities: cloudCaps,
            for: request, weights: .qualityFirst
        )
        let localScore = CapabilityMatcher.score(
            providerID: .ollama, capabilities: localCaps,
            for: request, weights: .qualityFirst
        )

        #expect(cloudScore.baseScore > localScore.baseScore)
    }

    @Test func scoreNeverNegative() {
        let request = AIRequest.chat("Hello")
        let score = CapabilityMatcher.score(
            providerID: .anthropic, capabilities: cloudCaps,
            for: request, weights: .balanced
        )
        #expect(score.baseScore >= 0)
    }

    @Test func reasoningExplainsToolSupport() {
        let tool = ToolDefinition(
            name: "test", description: "Test",
            inputSchema: .object([:])
        )
        let request = AIRequest.chat("Test").withTools([tool])

        let score = CapabilityMatcher.score(
            providerID: .anthropic, capabilities: cloudCaps,
            for: request, weights: .balanced
        )

        #expect(score.reasoning.contains { $0.contains("tool") })
    }
}

/// A provider that reports `supportsToolCalling == false` is *disqualified* for a
/// tool-carrying request — `scoreCapability` returns 0 and `score` returns early with
/// the whole provider at zero. The `+15` on-device complexity boost can rescue it, and
/// when it does, it can rescue it past a fully capable cloud provider: the weighted
/// scores are normalised into roughly the 5–20 range, so +15 is not a tie-breaker but a
/// landslide. Pinned because four documents describe this behaviour and the arithmetic
/// is what makes their description true.
@Suite("Capability disqualification arithmetic")
struct CapabilityDisqualificationTests {
    private let cloud = ProviderCapabilities(
        supportedTasks: [.chat], maxContextTokens: 1_000_000,
        supportsStreaming: true, supportsToolCalling: true, supportsImageInput: true,
        costPerMillionInputTokens: 2.0, costPerMillionOutputTokens: 10.0,
        estimatedLatency: .moderate, privacyLevel: .thirdPartyCloud
    )
    private let onDevice = ProviderCapabilities(
        supportedTasks: [.chat], maxContextTokens: 8_000,
        supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
        costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
        estimatedLatency: .fast, privacyLevel: .onDevice
    )
    private var toolRequest: AIRequest {
        AIRequest.chat("Go").withTools([
            ToolDefinition(name: "t", description: "d", inputSchema: .object([:]))
        ])
    }

    /// The whole score goes to zero, not one term of the weighted sum.
    @Test func aMissingCapabilityZeroesTheWholeScoreNotOneTerm() {
        let score = CapabilityMatcher.score(
            providerID: .appleFoundation, capabilities: onDevice,
            for: toolRequest, weights: .balanced
        )
        #expect(score.baseScore == 0)
        #expect(score.adjustedScore == 0)

        // Without tools the same provider scores well, so the zero is the
        // disqualification and not a weak provider.
        let withoutTools = CapabilityMatcher.score(
            providerID: .appleFoundation, capabilities: onDevice,
            for: AIRequest.chat("Go"), weights: .balanced
        )
        #expect(withoutTools.adjustedScore > 10)
    }

    /// The rescue is larger than the gap it has to close, so a *disqualified*
    /// provider can outrank a capable one. The capable provider stays in the
    /// decision's alternatives, so the fallback chain is what recovers the run —
    /// not the score.
    @Test func theOnDeviceBoostCanOutrankAFullyCapableCloudProvider() {
        let cloudScore = CapabilityMatcher.score(
            providerID: .anthropic, capabilities: cloud,
            for: toolRequest, weights: .balanced
        ).adjustedScore
        let rescuedDeviceScore = CapabilityMatcher.score(
            providerID: .appleFoundation, capabilities: onDevice,
            for: toolRequest, weights: .balanced
        ).adjustedScore + 15  // SmartRouter.applyComplexityAdjustments

        #expect(cloudScore > 0)
        #expect(rescuedDeviceScore > cloudScore)
    }
}

/// `supportedTasks` is the self-description a provider publishes. It is only
/// consumed today by `SmartRouter`'s structured-output boost, so a task missing
/// from the set is not a routing bug — but the set contradicting the boolean
/// beside it, or naming no provider at all for a task the enum defines, is a
/// defect in the description itself.
@Suite("Declared capabilities")
struct DeclaredCapabilityTests {
    private var providers: [(String, ProviderCapabilities)] {
        [
            ("Anthropic", AnthropicProvider(resolvedKey: "k", baseURL: nil, defaultModel: .claudeSonnet5).capabilities),
            ("OpenAI", OpenAIProvider(resolvedKey: "k", baseURL: nil).capabilities),
            ("Gemini", GeminiProvider(resolvedKey: "k", baseURL: nil).capabilities),
            ("Ollama", OllamaProvider().capabilities),
        ]
    }

    /// A provider that accepts images says so in both places it can.
    @Test func imageInputAndImageUnderstandingAgree() {
        for (name, caps) in providers {
            #expect(
                caps.supportsImageInput == caps.supportedTasks.contains(.imageUnderstanding),
                "\(name) disagrees with itself about image input"
            )
        }
    }

    /// Every `EmbeddingProvider` declares `.embedding`; a provider that cannot
    /// embed does not.
    @Test func embeddingProvidersDeclareTheEmbeddingTask() {
        #expect(OpenAIProvider(resolvedKey: "k", baseURL: nil)
            .capabilities.supportedTasks.contains(.embedding))
        #expect(OllamaProvider().capabilities.supportedTasks.contains(.embedding))

        #expect(!AnthropicProvider(resolvedKey: "k", baseURL: nil, defaultModel: .claudeSonnet5)
            .capabilities.supportedTasks.contains(.embedding))
        #expect(!GeminiProvider(resolvedKey: "k", baseURL: nil)
            .capabilities.supportedTasks.contains(.embedding))
    }
}
