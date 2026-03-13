// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("Three-Tier Routing")
struct ThreeTierRoutingTests {
    static let onlineState: @Sendable () async -> ConnectivityState = { .wifi }
    static let offlineState: @Sendable () async -> ConnectivityState = { .offline }
    static let normalDevice: @Sendable () -> DeviceCapabilities = {
        DeviceCapabilities(memoryGB: 16, thermalLevel: .nominal, processorCount: 8)
    }
    static let hotDevice: @Sendable () -> DeviceCapabilities = {
        DeviceCapabilities(memoryGB: 16, thermalLevel: .serious, processorCount: 8)
    }

    func makeRouter(
        connectivity: (@Sendable () async -> ConnectivityState)? = nil,
        device: (@Sendable () -> DeviceCapabilities)? = nil,
        privacy: PrivacyGuard? = nil
    ) -> SmartRouter {
        SmartRouter(
            privacyGuard: privacy,
            connectivityCheck: connectivity ?? Self.onlineState,
            deviceAssessment: device ?? Self.normalDevice
        )
    }

    func cloudProvider() -> MockProvider {
        MockProvider(id: .anthropic, capabilities: ProviderCapabilities(
            supportedTasks: [.chat, .completion, .codeGeneration, .summarization, .translation],
            maxContextTokens: 200_000,
            supportsStreaming: true, supportsToolCalling: true, supportsImageInput: true,
            costPerMillionInputTokens: 3.0, costPerMillionOutputTokens: 15.0,
            estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
        ))
    }

    func mlxProvider() -> MockLocalProvider {
        MockLocalProvider()
    }

    func appleFoundationMock() -> MockProvider {
        MockProvider(id: .appleFoundation, available: true, capabilities: ProviderCapabilities(
            supportedTasks: [.chat, .summarization, .translation, .structuredOutput],
            maxContextTokens: 4_096,
            supportsStreaming: true, supportsToolCalling: true, supportsImageInput: false,
            costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
            estimatedLatency: .fast, privacyLevel: .onDevice
        ))
    }

    @Test func threeTierCostOptimizedPrefersFreeTier() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .costOptimized)
        let request = AIRequest.chat("Classify this as positive or negative")
        let providers: [any AIProvider] = [cloudProvider(), mlxProvider(), appleFoundationMock()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        let selectedTier = decision.selectedProvider?.tier
        #expect(selectedTier == .onDevice || selectedTier == .system)
    }

    @Test func threeTierQualityFirstPrefersCloud() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .qualityFirst)
        let request = AIRequest.chat("Write a complex analysis")
        let providers: [any AIProvider] = [cloudProvider(), mlxProvider(), appleFoundationMock()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .anthropic)
    }

    @Test func threeTierPrivacyFirstPrefersOnDevice() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .privacyFirst)
        let request = AIRequest.chat("Summarize this private document")
        let providers: [any AIProvider] = [cloudProvider(), mlxProvider(), appleFoundationMock()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        let selectedTier = decision.selectedProvider?.tier
        #expect(selectedTier == .onDevice || selectedTier == .system)
    }

    @Test func offlineFallsBackToLocalProviders() async {
        let router = makeRouter(connectivity: Self.offlineState)
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), mlxProvider(), appleFoundationMock()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.isAvailable)
        #expect(decision.selectedProvider?.tier != .cloud)
    }

    @Test func privacyTagsBlockCloudInThreeTier() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("My health data").withTags([.health])
        let providers: [any AIProvider] = [cloudProvider(), mlxProvider(), appleFoundationMock()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider?.tier != .cloud)
    }

    @Test func budgetExhaustedFallsToFreeProviders() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), mlxProvider(), appleFoundationMock()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: 0.001)
        let selectedTier = decision.selectedProvider?.tier
        #expect(selectedTier == .onDevice || selectedTier == .system)
    }

    @Test func thermalPressurePrefersCloudOverLocal() async {
        let router = makeRouter(device: Self.hotDevice)
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), mlxProvider(), appleFoundationMock()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .anthropic)
    }

    @Test func gracefulDegradationWhenMLXUnavailable() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let unavailableMLX = MockProvider(id: .mlx, available: false, capabilities: ProviderCapabilities(
            supportedTasks: [.chat], maxContextTokens: 4_096,
            supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
            costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
            estimatedLatency: .moderate, privacyLevel: .onDevice
        ))
        let providers: [any AIProvider] = [cloudProvider(), unavailableMLX, appleFoundationMock()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.isAvailable)
        #expect(decision.selectedProvider != .mlx)
    }

    @Test func gracefulDegradationWhenAllLocalUnavailable() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let unavailableMLX = MockProvider(id: .mlx, available: false, capabilities: ProviderCapabilities(
            supportedTasks: [.chat], maxContextTokens: 4_096,
            supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
            costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
            estimatedLatency: .moderate, privacyLevel: .onDevice
        ))
        let unavailableFM = MockProvider(id: .appleFoundation, available: false, capabilities: ProviderCapabilities(
            supportedTasks: [.chat], maxContextTokens: 4_096,
            supportsStreaming: true, supportsToolCalling: true, supportsImageInput: false,
            costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
            estimatedLatency: .fast, privacyLevel: .onDevice
        ))
        let providers: [any AIProvider] = [cloudProvider(), unavailableMLX, unavailableFM]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.isAvailable)
        #expect(decision.selectedProvider == .anthropic)
    }

    @Test func allThreeProvidersAppearInAlternatives() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), mlxProvider(), appleFoundationMock()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        let allProviderIds = Set(decision.alternativeProviders + [decision.selectedProvider].compactMap { $0 })
        #expect(allProviderIds.count == 3)
    }
}
