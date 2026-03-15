// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "SmartRouter")

/// Intelligent multi-tier routing engine — the core innovation of Arbiter.
///
/// Routes requests to the best available provider based on connectivity,
/// device state, privacy requirements, cost, and capability matching.
public actor SmartRouter {
    private let connectivityCheck: @Sendable () async -> ConnectivityState
    private let deviceAssessment: @Sendable () -> DeviceCapabilities
    private let privacyGuard: PrivacyGuard?
    private var _recentDecisions: [RoutingDebugEntry] = []
    private let maxHistorySize = 100
    private let analyser = RequestAnalyser()
    let performanceTracker = ProviderPerformanceTracker()
    private let healthMonitor: ProviderHealthMonitor?

    public init(
        privacyGuard: PrivacyGuard? = nil,
        connectivityCheck: (@Sendable () async -> ConnectivityState)? = nil,
        deviceAssessment: (@Sendable () -> DeviceCapabilities)? = nil,
        healthMonitor: ProviderHealthMonitor? = nil
    ) {
        self.privacyGuard = privacyGuard
        self.connectivityCheck = connectivityCheck ?? ConnectivityMonitor.checkConnectivity
        self.deviceAssessment = deviceAssessment ?? DeviceAssessor.assess
        self.healthMonitor = healthMonitor
    }

    /// Route a request to the best available provider.
    public func route(
        _ request: AIRequest,
        policy: RoutingPolicy,
        providers: [any AIProvider],
        budgetRemaining: Double?
    ) async -> RoutingDecision {
        let decision: RoutingDecision

        if case .fixed(let id) = policy.strategy {
            decision = fixedRoute(id, providers: providers)
        } else if case .priority(let order) = policy.strategy {
            decision = await priorityRoute(
                order, request: request, policy: policy, providers: providers
            )
        } else {
            decision = await smartRoute(
                request, policy: policy, providers: providers,
                budgetRemaining: budgetRemaining
            )
        }

        recordDecision(request: request, decision: decision)
        return decision
    }

    /// Recent routing decisions for debug views
    public var recentDecisions: [RoutingDebugEntry] { _recentDecisions }
}

private extension SmartRouter {
    func recordDecision(request: AIRequest, decision: RoutingDecision) {
        let firstMessageText = request.messages.first?.content.text ?? "[non-text]"
        let summary = String(firstMessageText.prefix(80))
        let entry = RoutingDebugEntry(
            requestSummary: summary,
            decision: decision
        )
        _recentDecisions.append(entry)
        if _recentDecisions.count > maxHistorySize {
            _recentDecisions.removeFirst(_recentDecisions.count - maxHistorySize)
        }
    }

    func fixedRoute(_ id: ProviderID, providers: [any AIProvider]) -> RoutingDecision {
        let alternatives = providers.filter { $0.id != id }.map(\.id)
        guard providers.contains(where: { $0.id == id }) else {
            logger.warning("Fixed route provider \(id.rawValue) not found in registered providers")
            guard let fallback = alternatives.first else {
                return .unavailable(factors: [])
            }
            return RoutingDecision(
                selectedProvider: fallback,
                reason: "Fixed provider \(id.displayName) not registered — fell back to \(fallback.displayName)",
                alternativeProviders: Array(alternatives.dropFirst()),
                factors: []
            )
        }
        return RoutingDecision(
            selectedProvider: id,
            reason: "Fixed routing to \(id.displayName)",
            alternativeProviders: alternatives,
            factors: []
        )
    }

    func priorityRoute(
        _ order: [ProviderID],
        request: AIRequest,
        policy: RoutingPolicy,
        providers: [any AIProvider]
    ) async -> RoutingDecision {
        var factors: [RoutingFactor] = []
        let connectivity = await connectivityCheck()
        factors.append(.connectivity(available: connectivity.isConnected))

        let filtered = filterByConstraints(
            providers, policy: policy, request: request,
            connectivity: connectivity, factors: &factors
        )
        let available = await filterAvailable(filtered)
        let availableIDs = Set(available.map(\.id))

        let ordered = order.isEmpty
            ? available.map(\.id)
            : order.filter { availableIDs.contains($0) }

        guard let first = ordered.first else {
            return .unavailable(factors: factors)
        }

        return RoutingDecision(
            selectedProvider: first,
            reason: "Priority routing — first available",
            alternativeProviders: Array(ordered.dropFirst()),
            factors: factors
        )
    }

    func smartRoute(
        _ request: AIRequest,
        policy: RoutingPolicy,
        providers: [any AIProvider],
        budgetRemaining: Double?
    ) async -> RoutingDecision {
        var factors: [RoutingFactor] = []

        let connectivity = await connectivityCheck()
        let device = deviceAssessment()
        factors.append(.connectivity(available: connectivity.isConnected))

        let filtered = filterByConstraints(
            providers, policy: policy, request: request,
            connectivity: connectivity, factors: &factors
        )

        let available = await filterAvailable(filtered)
        guard !available.isEmpty else {
            logger.warning("No providers available after filtering")
            return .unavailable(factors: factors)
        }

        // Run request analysis for intelligent routing
        let analysis = analyser.analyse(request, providers: available)

        let planner = TokenBudgetPlanner()
        let weights = scoringWeights(for: policy.strategy)
        var scores = available.map { provider in
            CapabilityMatcher.score(
                providerID: provider.id, capabilities: provider.capabilities,
                for: request, weights: weights
            )
        }

        for i in scores.indices {
            let provider = available.first { $0.id == scores[i].providerID }
            if let caps = provider?.capabilities {
                let check = planner.fits(request: request, provider: caps)
                if case .exceeds = check {
                    scores[i].adjustedScore = 0
                    scores[i].reasoning.append("request exceeds context window")
                }
            }
        }

        applyEnvironmentAdjustments(&scores, device: device, budgetRemaining: budgetRemaining, factors: &factors)

        if case .smart = policy.strategy, !device.isThermallyConstrained {
            applyComplexityAdjustments(&scores, analysis: analysis)
            applyTaskAdjustments(&scores, analysis: analysis, providers: available)
        }
        await applyPerformanceAdjustments(&scores, analysis: analysis)
        await applyHealthAdjustments(&scores)
        scores.sort { $0.adjustedScore > $1.adjustedScore }

        return buildDecision(from: scores, factors: factors, analysis: analysis)
    }

    func filterByConstraints(
        _ providers: [any AIProvider],
        policy: RoutingPolicy,
        request: AIRequest,
        connectivity: ConnectivityState,
        factors: inout [RoutingFactor]
    ) -> [any AIProvider] {
        var candidates = providers

        if !connectivity.isConnected {
            candidates = candidates.filter { $0.id.tier != .cloud }
            logger.debug("Offline — removed cloud providers")
        }

        if policy.forceLocal && policy.forceCloud {
            logger.warning("Conflicting policy: both forceLocal and forceCloud are true — forceLocal takes precedence")
        }

        if policy.forceLocal {
            candidates = candidates.filter { $0.id.tier != .cloud }
        } else if policy.forceCloud {
            candidates = candidates.filter { $0.id.tier == .cloud }
        }

        let forceLocal = privacyGuard?.shouldForceLocal(for: request) ?? false
        let hasPrivateTags = !request.tags.isDisjoint(with: policy.privacyTags)

        if forceLocal || hasPrivateTags {
            candidates = candidates.filter { $0.capabilities.privacyLevel != .thirdPartyCloud }
            factors.append(.privacy(level: .onDevice, required: .onDevice))
            logger.debug("Privacy constraint — removed cloud providers")
        }

        return candidates
    }

    func filterAvailable(_ providers: [any AIProvider]) async -> [any AIProvider] {
        guard providers.count > 1 else {
            if let single = providers.first, await single.isAvailable {
                return [single]
            }
            return []
        }

        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await provider.isAvailable) }
            }
            var availability = [Int: Bool]()
            for await (index, isAvailable) in group {
                availability[index] = isAvailable
            }
            return providers.enumerated().compactMap { index, provider in
                availability[index] == true ? provider : nil
            }
        }
    }

    func applyComplexityAdjustments(_ scores: inout [ProviderScore], analysis: RequestAnalysis) {
        let boost: Double = 15
        for i in scores.indices {
            let tier = scores[i].providerID.tier
            switch analysis.complexity {
            case .trivial, .simple:
                if tier == .onDevice || tier == .system {
                    scores[i].adjustedScore += boost
                    scores[i].reasoning.append("simple task — boosted on-device")
                }
            case .moderate:
                break
            case .complex, .expert:
                if tier == .cloud {
                    scores[i].adjustedScore += boost
                    scores[i].reasoning.append("complex task — boosted cloud")
                }
            }
        }
    }

    func applyTaskAdjustments(
        _ scores: inout [ProviderScore],
        analysis: RequestAnalysis,
        providers: [any AIProvider]
    ) {
        for i in scores.indices {
            let providerID = scores[i].providerID

            if analysis.detectedTask == .codeGeneration && providerID == .anthropic {
                scores[i].adjustedScore += 10
                scores[i].reasoning.append("code task — Anthropic boost")
            }

            if analysis.detectedTask == .structuredOutput {
                if let provider = providers.first(where: { $0.id == providerID }),
                   provider.capabilities.supportedTasks.contains(.structuredOutput) {
                    scores[i].adjustedScore += 10
                    scores[i].reasoning.append("structured output — JSON mode boost")
                }
            }
        }
    }

    func applyPerformanceAdjustments(
        _ scores: inout [ProviderScore],
        analysis: RequestAnalysis
    ) async {
        for i in scores.indices {
            let adjustment = await performanceTracker.scoreAdjustment(
                for: scores[i].providerID,
                task: analysis.detectedTask
            )
            if adjustment != 0 {
                scores[i].adjustedScore += adjustment
                scores[i].reasoning.append("performance history: \(adjustment > 0 ? "+" : "")\(Int(adjustment))")
            }
        }
    }

    func applyHealthAdjustments(_ scores: inout [ProviderScore]) async {
        guard let monitor = healthMonitor else { return }
        for i in scores.indices {
            let adjustment = await monitor.scoreAdjustment(for: scores[i].providerID)
            if adjustment != 0 {
                scores[i].adjustedScore += adjustment
            }
        }
    }

    func applyEnvironmentAdjustments(
        _ scores: inout [ProviderScore],
        device: DeviceCapabilities,
        budgetRemaining: Double?,
        factors: inout [RoutingFactor]
    ) {
        if device.isThermallyConstrained {
            for i in scores.indices {
                let tier = scores[i].providerID.tier
                if tier == .onDevice || tier == .localServer || tier == .system {
                    scores[i].adjustedScore *= 0.5
                }
            }
            factors.append(.thermal(
                state: device.thermalLevel.rawValue,
                recommendation: "Prefer cloud due to thermal pressure"
            ))
        }

        if let budget = budgetRemaining, budget < 0.01 {
            for i in scores.indices where scores[i].providerID.tier == .cloud {
                scores[i].adjustedScore = 0
            }
            factors.append(.budget(remaining: budget, estimatedCost: 0))
        }
    }

    func buildDecision(
        from scores: [ProviderScore],
        factors: [RoutingFactor],
        analysis: RequestAnalysis? = nil
    ) -> RoutingDecision {
        guard let best = scores.first, best.adjustedScore > 0 else {
            return .unavailable(factors: factors)
        }

        let alternatives = scores.dropFirst()
            .filter { $0.adjustedScore > 0 }
            .map(\.providerID)

        let reason = best.reasoning.isEmpty
            ? "\(best.providerID.displayName) selected (score: \(Int(best.adjustedScore)))"
            : best.reasoning.joined(separator: "; ")

        return RoutingDecision(
            selectedProvider: best.providerID,
            reason: reason,
            alternativeProviders: alternatives,
            confidenceScore: min(best.adjustedScore / 20.0, 1.0),
            factors: factors,
            analysis: analysis
        )
    }

    func scoringWeights(for strategy: RoutingStrategy) -> ScoringWeights {
        switch strategy {
        case .smart: return .balanced
        case .costOptimized: return .costOptimized
        case .privacyFirst: return .privacyFirst
        case .qualityFirst: return .qualityFirst
        case .latencyOptimized: return .latencyOptimized
        case .fixed, .priority: return .balanced
        }
    }
}
