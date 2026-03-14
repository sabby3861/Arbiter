// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "SmartRouter")

/// Intelligent multi-tier routing engine — the core innovation of SwiftAI.
///
/// Routes requests to the best available provider based on connectivity,
/// device state, privacy requirements, cost, and capability matching.
public actor SmartRouter {
    private let connectivityCheck: @Sendable () async -> ConnectivityState
    private let deviceAssessment: @Sendable () -> DeviceCapabilities
    private let privacyGuard: PrivacyGuard?
    private var _recentDecisions: [RoutingDebugEntry] = []
    private let maxHistorySize = 100

    public init(
        privacyGuard: PrivacyGuard? = nil,
        connectivityCheck: (@Sendable () async -> ConnectivityState)? = nil,
        deviceAssessment: (@Sendable () -> DeviceCapabilities)? = nil
    ) {
        self.privacyGuard = privacyGuard
        self.connectivityCheck = connectivityCheck ?? ConnectivityMonitor.checkConnectivity
        self.deviceAssessment = deviceAssessment ?? DeviceAssessor.assess
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

        let weights = scoringWeights(for: policy.strategy)
        var scores = available.map { provider in
            CapabilityMatcher.score(
                providerID: provider.id, capabilities: provider.capabilities,
                for: request, weights: weights
            )
        }

        applyEnvironmentAdjustments(&scores, device: device, budgetRemaining: budgetRemaining, factors: &factors)
        scores.sort { $0.adjustedScore > $1.adjustedScore }

        return buildDecision(from: scores, factors: factors)
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

    func buildDecision(from scores: [ProviderScore], factors: [RoutingFactor]) -> RoutingDecision {
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
            factors: factors
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
