// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
@testable import SwiftAI

@Suite("CostEstimate")
struct CostEstimateTests {
    @Test("Estimates include all registered providers")
    func estimatesIncludeAll() async {
        let provider1 = MockProvider(id: .anthropic)
        let provider2 = MockProvider(id: .openAI)
        let ai = SwiftAI {
            $0.cloud(provider1)
            $0.cloud(provider2)
        }

        let estimates = await ai.estimateCost("Hello world")
        let providerIDs = Set(estimates.map(\.provider))
        #expect(providerIDs.contains(.anthropic))
        #expect(providerIDs.contains(.openAI))
    }

    @Test("Cloud providers have non-zero cost")
    func cloudNonZeroCost() async {
        let provider = MockProvider(
            id: .anthropic,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat],
                maxContextTokens: 200_000,
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsImageInput: true,
                costPerMillionInputTokens: 3.0,
                costPerMillionOutputTokens: 15.0,
                estimatedLatency: .moderate,
                privacyLevel: .thirdPartyCloud
            )
        )
        let ai = SwiftAI(provider: provider)
        let estimates = await ai.estimateCost("Write something")
        let anthropicEstimate = estimates.first { $0.provider == .anthropic }
        #expect(anthropicEstimate != nil)
        #expect((anthropicEstimate?.estimatedCost ?? 0) > 0)
    }

    @Test("Free providers have zero cost")
    func freeZeroCost() async {
        let provider = MockLocalProvider()
        let ai = SwiftAI(provider: provider)
        let estimates = await ai.estimateCost("Hello")
        let mlxEstimate = estimates.first { $0.provider == .mlx }
        #expect(mlxEstimate?.estimatedCost == 0)
    }

    @Test("wouldBeSelected is true for exactly one provider")
    func exactlyOneSelected() async {
        let provider1 = MockProvider(id: .anthropic)
        let provider2 = MockProvider(id: .openAI)
        let ai = SwiftAI {
            $0.cloud(provider1)
            $0.cloud(provider2)
        }

        let estimates = await ai.estimateCost("Hello")
        let selectedCount = estimates.filter(\.wouldBeSelected).count
        #expect(selectedCount == 1)
    }
}
