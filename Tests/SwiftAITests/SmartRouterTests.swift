// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("SmartRouter")
struct SmartRouterTests {
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

    func cloudProvider(id: ProviderID = .anthropic) -> MockProvider {
        MockProvider(id: id, capabilities: ProviderCapabilities(
            supportedTasks: [.chat], maxContextTokens: 200_000,
            supportsStreaming: true, supportsToolCalling: true, supportsImageInput: true,
            costPerMillionInputTokens: 3.0, costPerMillionOutputTokens: 15.0,
            estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
        ))
    }

    func localProvider() -> MockLocalProvider {
        MockLocalProvider()
    }

    // MARK: - Fixed strategy

    @Test func fixedRouteSelectsSpecificProvider() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .fixed(.openAI))
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), cloudProvider(id: .openAI)]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .openAI)
    }

    // MARK: - Priority strategy

    @Test func priorityRouteRespectsOrder() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .priority([.openAI, .anthropic]))
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), cloudProvider(id: .openAI)]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .openAI)
    }

    @Test func priorityRouteSkipsUnavailable() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .priority([.gemini, .anthropic]))
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [
            MockProvider(id: .gemini, available: false),
            cloudProvider(id: .anthropic),
        ]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .anthropic)
    }

    // MARK: - Smart strategy

    @Test func smartRouteSelectsBestProvider() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.isAvailable)
    }

    // MARK: - Offline routing

    @Test func offlineRemovesCloudProviders() async {
        let router = makeRouter(connectivity: Self.offlineState)
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .mlx)
    }

    @Test func offlineWithOnlyCloudReturnsUnavailable() async {
        let router = makeRouter(connectivity: Self.offlineState)
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(!decision.isAvailable)
    }

    // MARK: - Privacy routing

    @Test func privacyTagsForcesLocal() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("My health report").withTags([.health])
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .mlx)
    }

    @Test func privacyGuardForceLocalBlocksCloud() async {
        let guard_ = PrivacyGuard.localOnly
        let router = makeRouter(privacy: guard_)
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Anything")
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .mlx)
    }

    // MARK: - Budget constraints

    @Test func budgetExhaustedRemovesCloud() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: 0.001)
        #expect(decision.selectedProvider == .mlx)
    }

    // MARK: - Thermal constraints

    @Test func thermalPressurePrefersCloud() async {
        let router = makeRouter(device: Self.hotDevice)
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .anthropic)
    }

    // MARK: - Force flags

    @Test func forceLocalPolicy() async {
        let router = makeRouter()
        var policy = RoutingPolicy.smart
        policy.forceLocal = true
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .mlx)
    }

    @Test func forceCloudPolicy() async {
        let router = makeRouter()
        var policy = RoutingPolicy.smart
        policy.forceCloud = true
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .anthropic)
    }

    // MARK: - All unavailable

    @Test func allUnavailableReturnsZeroConfidence() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [
            MockProvider(id: .anthropic, available: false),
            MockProvider(id: .openAI, available: false),
        ]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(!decision.isAvailable)
    }

    // MARK: - Alternatives

    @Test func decisionIncludesAlternatives() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), cloudProvider(id: .openAI), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(!decision.alternativeProviders.isEmpty)
    }

    // MARK: - Strategy-specific weights

    @Test func costOptimizedPrefersFreeTier() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .costOptimized)
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        // Local provider is free, so cost-optimized should prefer it
        #expect(decision.selectedProvider == .mlx)
    }

    @Test func qualityFirstPrefersExpensiveProvider() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .qualityFirst)
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.selectedProvider == .anthropic)
    }

    @Test func latencyOptimizedPrefersFastProvider() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .latencyOptimized)
        let request = AIRequest.chat("Hello")

        let fast = MockProvider(
            id: .gemini,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat], maxContextTokens: 100_000,
                supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
                costPerMillionInputTokens: 1.0, costPerMillionOutputTokens: 5.0,
                estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
            )
        )
        let slow = MockProvider(
            id: .ollama,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat], maxContextTokens: 100_000,
                supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
                costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
                estimatedLatency: .slow, privacyLevel: .onDevice
            )
        )

        let decision = await router.route(request, policy: policy, providers: [slow, fast], budgetRemaining: nil)
        #expect(decision.selectedProvider == .gemini)
    }

    @Test func capabilityFilterBlocksProviderWithoutToolCalling() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .smart)

        let tool = ToolDefinition(name: "calc", description: "Calculate", inputSchema: .object([:]))
        let request = AIRequest.chat("Use the calculator").withTools([tool])

        let noTools = MockProvider(
            id: .ollama,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat], maxContextTokens: 100_000,
                supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
                costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
                estimatedLatency: .fast, privacyLevel: .onDevice
            )
        )
        let withTools = MockProvider(
            id: .anthropic,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat], maxContextTokens: 200_000,
                supportsStreaming: true, supportsToolCalling: true, supportsImageInput: false,
                costPerMillionInputTokens: 3.0, costPerMillionOutputTokens: 15.0,
                estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
            )
        )

        let decision = await router.route(request, policy: policy, providers: [noTools, withTools], budgetRemaining: nil)
        #expect(decision.selectedProvider == .anthropic)
    }

    @Test func smartRouteExcludesProviderWhenRequestExceedsContext() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart

        let longText = String(repeating: "word ", count: 50_000)
        let request = AIRequest.chat(longText)

        let smallContext = MockProvider(
            id: .ollama,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat], maxContextTokens: 4_096,
                supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
                costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
                estimatedLatency: .fast, privacyLevel: .onDevice
            )
        )
        let largeContext = MockProvider(
            id: .anthropic,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat], maxContextTokens: 200_000,
                supportsStreaming: true, supportsToolCalling: true, supportsImageInput: true,
                costPerMillionInputTokens: 3.0, costPerMillionOutputTokens: 15.0,
                estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
            )
        )

        let decision = await router.route(
            request, policy: policy,
            providers: [smallContext, largeContext],
            budgetRemaining: nil
        )
        #expect(decision.selectedProvider == .anthropic)
    }

    @Test func fixedRouteToNonExistentProviderFallsBack() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .fixed(.gemini))
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        // Gemini is not registered — should fall back to first available
        #expect(decision.selectedProvider != .gemini)
        #expect(decision.isAvailable)
    }
}
