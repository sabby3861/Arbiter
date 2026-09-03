// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

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

    /// Every router built here starts cold on purpose. The production tracker reads the
    /// shared `com.arbiter.performance` suite, so ten or more recorded requests for a
    /// provider — left behind by an earlier run of this suite, or by the developer's own
    /// app — move its score by as much as +15 or -20 and decide assertions that are
    /// about something else entirely. `.inMemory()` gives each router its own empty store.
    func makeRouter(
        connectivity: (@Sendable () async -> ConnectivityState)? = nil,
        device: (@Sendable () -> DeviceCapabilities)? = nil,
        privacy: PrivacyGuard? = nil,
        performanceTracker: ProviderPerformanceTracker? = nil
    ) -> SmartRouter {
        SmartRouter(
            privacyGuard: privacy,
            connectivityCheck: connectivity ?? Self.onlineState,
            deviceAssessment: device ?? Self.normalDevice,
            performanceTracker: performanceTracker ?? .inMemory()
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

    /// The zeroing an exhausted budget applies has to survive the passes that run after
    /// it. `applyComplexityAdjustments` adds +15 to the cloud tier on a complex prompt —
    /// larger than either provider's whole base score here — so before `enforceExclusions`
    /// a complex prompt put the zeroed cloud provider straight back at the top: 0 + 15
    /// against 14 for the free local one. `SpendingGuard` refused the call downstream, so
    /// nothing reached the provider — but the decision the router published named it, and
    /// "budget exhausted removes cloud" is a claim about the decision.
    ///
    /// Asserted on the decision itself rather than on the outcome of a run: the cloud
    /// candidate's own score, its absence from the selection, and its absence from the
    /// alternatives the fallback chain would walk.
    @Test func budgetExhaustionSurvivesTheComplexityBoostThatWouldUndoIt() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        // Classified `.complex`, which is what arms the +15 cloud boost.
        let request = AIRequest.chat(
            "Explain step by step why quantum entanglement violates classical intuition"
        )
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(
            request, policy: policy, providers: providers, budgetRemaining: 0.001
        )

        #expect(decision.analysis?.complexity == .complex || decision.analysis?.complexity == .expert)

        let cloudCandidate = decision.candidateScores.first { $0.provider == .anthropic }
        #expect(cloudCandidate?.score == 0)
        #expect(cloudCandidate?.isSelected == false)
        #expect(decision.selectedProvider == .mlx)
        #expect(!decision.alternativeProviders.contains(.anthropic))
    }

    /// The exclusion is a veto on the budget, not a blanket veto on cloud. Asserted on
    /// the score rather than the selection, so it pins the +15 the test above suppresses:
    /// with budget left the same prompt scores the cloud provider 11.39 + 15, and the
    /// local one is untouched at 14 in both tests. That difference is the whole fix —
    /// nothing else about the two routes differs.
    @Test func theSameComplexPromptWithBudgetLeftStillPrefersCloud() async {
        let router = makeRouter()
        let request = AIRequest.chat(
            "Explain step by step why quantum entanglement violates classical intuition"
        )
        let providers: [any AIProvider] = [cloudProvider(), localProvider()]

        let decision = await router.route(
            request, policy: .smart, providers: providers, budgetRemaining: 5.00
        )

        let cloudCandidate = decision.candidateScores.first { $0.provider == .anthropic }
        let localCandidate = decision.candidateScores.first { $0.provider == .mlx }
        #expect((cloudCandidate?.score ?? 0) > 20)
        #expect(cloudCandidate?.reasoning.contains { $0.contains("boosted cloud") } == true)
        #expect(localCandidate?.score == 14)
        #expect(decision.selectedProvider == .anthropic)
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

    @Test func smartRoutePopulatesCandidateScores() async {
        let router = makeRouter()
        let policy = RoutingPolicy.smart
        let request = AIRequest.chat("Hello")
        let providers: [any AIProvider] = [cloudProvider(), cloudProvider(id: .openAI), localProvider()]

        let decision = await router.route(request, policy: policy, providers: providers, budgetRemaining: nil)
        #expect(decision.candidateScores.count == providers.count)
        #expect(decision.candidateScores.filter(\.isSelected).count == 1)

        let selected = decision.candidateScores.first { $0.isSelected }
        #expect(selected?.provider == decision.selectedProvider)

        let sorted = decision.candidateScores.map(\.score)
        #expect(sorted == sorted.sorted(by: >))
    }

    @Test func costOptimizedDifferentiatesSimilarProviders() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .costOptimized)
        let request = AIRequest.chat("Classify: positive or negative")

        let expensive = MockProvider(
            id: .anthropic,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat], maxContextTokens: 200_000,
                supportsStreaming: true, supportsToolCalling: true, supportsImageInput: true,
                costPerMillionInputTokens: 3.0, costPerMillionOutputTokens: 15.0,
                estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
            )
        )
        let cheaper = MockProvider(
            id: .openAI,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat], maxContextTokens: 128_000,
                supportsStreaming: true, supportsToolCalling: true, supportsImageInput: true,
                costPerMillionInputTokens: 2.5, costPerMillionOutputTokens: 10.0,
                estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
            )
        )

        let decision = await router.route(
            request, policy: policy, providers: [expensive, cheaper], budgetRemaining: nil
        )
        #expect(decision.selectedProvider == .openAI)

        let scores = decision.candidateScores
        let openAIScore = scores.first { $0.provider == .openAI }?.score ?? 0
        let anthropicScore = scores.first { $0.provider == .anthropic }?.score ?? 0
        #expect(openAIScore > anthropicScore)
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

    // MARK: - Integration: Performance-driven routing

    @Test func routerPrefersProviderWithHigherSuccessRate() async {
        // The 30 outcomes below used to land in the real `com.arbiter.performance` suite
        // and stay there, biasing every later router in this process and on this machine.
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .smart)

        // Record 15 failures for OpenAI on code tasks
        for _ in 0..<15 {
            await router.performanceTracker.recordOutcome(
                provider: .openAI,
                task: .codeGeneration,
                latencySeconds: 5.0,
                succeeded: false,
                tokenCount: 0
            )
        }

        // Record 15 successes for Anthropic on code tasks
        for _ in 0..<15 {
            await router.performanceTracker.recordOutcome(
                provider: .anthropic,
                task: .codeGeneration,
                latencySeconds: 1.0,
                succeeded: true,
                tokenCount: 500
            )
        }

        // Both providers have identical base capabilities
        let openAI = MockProvider(
            id: .openAI,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat, .codeGeneration],
                maxContextTokens: 128_000,
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsImageInput: true,
                costPerMillionInputTokens: 2.5,
                costPerMillionOutputTokens: 10.0,
                estimatedLatency: .fast,
                privacyLevel: .thirdPartyCloud
            )
        )
        let anthropic = MockProvider(
            id: .anthropic,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat, .codeGeneration],
                maxContextTokens: 200_000,
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsImageInput: true,
                costPerMillionInputTokens: 3.0,
                costPerMillionOutputTokens: 15.0,
                estimatedLatency: .fast,
                privacyLevel: .thirdPartyCloud
            )
        )

        // Route a code generation request
        let request = AIRequest.chat("Write a Swift function that sorts an array")
        let decision = await router.route(
            request, policy: policy,
            providers: [openAI, anthropic],
            budgetRemaining: nil
        )

        // Anthropic should win despite higher cost — performance history
        // gives it +10 (95%+ success) and OpenAI gets -20 (<70% success)
        #expect(decision.selectedProvider == .anthropic)
    }

    @Test func routerWithNoHistoryDoesNotApplyPerformanceAdjustments() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .smart)

        // No performance data recorded — both providers scored equally
        // on base factors. The cheaper one should win or they tie.
        let provider1 = MockProvider(
            id: .openAI,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat],
                maxContextTokens: 128_000,
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsImageInput: false,
                costPerMillionInputTokens: 2.5,
                costPerMillionOutputTokens: 10.0,
                estimatedLatency: .fast,
                privacyLevel: .thirdPartyCloud
            )
        )
        let provider2 = MockProvider(
            id: .anthropic,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat],
                maxContextTokens: 200_000,
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsImageInput: false,
                costPerMillionInputTokens: 3.0,
                costPerMillionOutputTokens: 15.0,
                estimatedLatency: .fast,
                privacyLevel: .thirdPartyCloud
            )
        )

        let request = AIRequest.chat("Hello")
        let decision = await router.route(
            request, policy: policy,
            providers: [provider1, provider2],
            budgetRemaining: nil
        )

        // With no history, should route based on base factors only
        // (both are available, decision is deterministic)
        #expect(decision.isAvailable)
    }

    @Test func routerComplexityBoostsCloudForHardTasks() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .smart)

        let cloud = MockProvider(
            id: .anthropic,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat, .codeGeneration],
                maxContextTokens: 200_000,
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsImageInput: true,
                costPerMillionInputTokens: 3.0,
                costPerMillionOutputTokens: 15.0,
                estimatedLatency: .fast,
                privacyLevel: .thirdPartyCloud
            )
        )
        let local = MockLocalProvider()

        // Complex reasoning task — cloud should get +15 complexity boost
        let request = AIRequest.chat(
            "Explain step by step why quantum entanglement violates classical intuition"
        )
        let decision = await router.route(
            request, policy: policy,
            providers: [local, cloud],
            budgetRemaining: nil
        )

        #expect(decision.selectedProvider == .anthropic)
    }

    @Test func routerSimpleTaskBoostsOnDevice() async {
        let router = makeRouter()
        let policy = RoutingPolicy(strategy: .smart)

        let cloud = MockProvider(
            id: .anthropic,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat],
                maxContextTokens: 200_000,
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsImageInput: true,
                costPerMillionInputTokens: 3.0,
                costPerMillionOutputTokens: 15.0,
                estimatedLatency: .fast,
                privacyLevel: .thirdPartyCloud
            )
        )
        let local = MockLocalProvider()

        // Trivial classification — local should get +15 simplicity boost
        let request = AIRequest.chat("Is this positive or negative?")
        let decision = await router.route(
            request, policy: policy,
            providers: [cloud, local],
            budgetRemaining: nil
        )

        // Local provider should win for trivial tasks — free + private +
        // simplicity boost outweighs cloud quality
        #expect(decision.selectedProvider == .mlx)
    }
}
