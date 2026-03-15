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
