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
    private let taskClassifier: (any TaskClassifier)?
    let performanceTracker: ProviderPerformanceTracker
    private let healthMonitor: ProviderHealthMonitor?

    public init(
        privacyGuard: PrivacyGuard? = nil,
        connectivityCheck: (@Sendable () async -> ConnectivityState)? = nil,
        deviceAssessment: (@Sendable () -> DeviceCapabilities)? = nil,
        healthMonitor: ProviderHealthMonitor? = nil,
        taskClassifier: (any TaskClassifier)? = nil,
        performanceTracker: ProviderPerformanceTracker? = nil
    ) {
        self.privacyGuard = privacyGuard
        self.taskClassifier = taskClassifier
        self.connectivityCheck = connectivityCheck ?? ConnectivityMonitor.checkConnectivity
        self.deviceAssessment = deviceAssessment ?? DeviceAssessor.assess
        self.healthMonitor = healthMonitor
        // Defaults to the store-backed tracker, so routing keeps learning across launches.
        self.performanceTracker = performanceTracker ?? ProviderPerformanceTracker()
    }

    /// Route a request to the best available provider.
    public func route(
        _ request: AIRequest,
        policy: RoutingPolicy,
        providers: [any AIProvider],
        budgetRemaining: Double?
    ) async -> RoutingDecision {
        // Assessed once per route, before any strategy runs: every strategy needs the
        // same verdict, and running the detector per candidate would repeat the work.
        let privacy = await privacyGuard?.assess(request)

        let decision: RoutingDecision

        if case .fixed(let id) = policy.strategy {
            decision = fixedRoute(id, providers: providers, privacy: privacy)
        } else if case .priority(let order) = policy.strategy {
            decision = await priorityRoute(
                order, request: request, policy: policy, providers: providers, privacy: privacy
            )
        } else {
            decision = await smartRoute(
                request, policy: policy, providers: providers,
                budgetRemaining: budgetRemaining, privacy: privacy
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

    /// Fixed routing names the provider outright, so the privacy assessment is attached to
    /// the decision for observability but does not filter candidates — the caller has
    /// already chosen where the request goes.
    func fixedRoute(
        _ id: ProviderID,
        providers: [any AIProvider],
        privacy: PrivacyReport?
    ) -> RoutingDecision {
        let alternatives = providers.filter { $0.id != id }.map(\.id)
        guard providers.contains(where: { $0.id == id }) else {
            logger.warning("Fixed route provider \(id.rawValue) not found in registered providers")
            guard let fallback = alternatives.first else {
                return .unavailable(factors: [], privacyReport: privacy)
            }
            return RoutingDecision(
                selectedProvider: fallback,
                reason: "Fixed provider \(id.displayName) not registered — fell back to \(fallback.displayName)",
                alternativeProviders: Array(alternatives.dropFirst()),
                factors: [],
                privacyReport: privacy
            )
        }
        return RoutingDecision(
            selectedProvider: id,
            reason: "Fixed routing to \(id.displayName)",
            alternativeProviders: alternatives,
            factors: [],
            privacyReport: privacy
        )
    }

    func priorityRoute(
        _ order: [ProviderID],
        request: AIRequest,
        policy: RoutingPolicy,
        providers: [any AIProvider],
        privacy: PrivacyReport?
    ) async -> RoutingDecision {
        var factors: [RoutingFactor] = []
        let connectivity = await connectivityCheck()
        factors.append(.connectivity(available: connectivity.isConnected))

        let filtered = filterByConstraints(
            providers, policy: policy, request: request,
            connectivity: connectivity, privacy: privacy, factors: &factors
        )
        let available = await filterAvailable(filtered)
        let availableIDs = Set(available.map(\.id))

        let ordered = order.isEmpty
            ? available.map(\.id)
            : order.filter { availableIDs.contains($0) }

        guard let first = ordered.first else {
            return .unavailable(factors: factors, privacyReport: privacy)
        }

        return RoutingDecision(
            selectedProvider: first,
            reason: "Priority routing — first available",
            alternativeProviders: Array(ordered.dropFirst()),
            factors: factors,
            privacyReport: privacy
        )
    }

    func smartRoute(
        _ request: AIRequest,
        policy: RoutingPolicy,
        providers: [any AIProvider],
        budgetRemaining: Double?,
        privacy: PrivacyReport?
    ) async -> RoutingDecision {
        var factors: [RoutingFactor] = []

        let connectivity = await connectivityCheck()
        let device = deviceAssessment()
        factors.append(.connectivity(available: connectivity.isConnected))

        let filtered = filterByConstraints(
            providers, policy: policy, request: request,
            connectivity: connectivity, privacy: privacy, factors: &factors
        )

        let available = await filterAvailable(filtered)
        guard !available.isEmpty else {
            logger.warning("No providers available after filtering")
            return .unavailable(factors: factors, privacyReport: privacy)
        }

        // Run request analysis for intelligent routing
        let analysis = await analyser.analyse(
            request, providers: available, classifier: taskClassifier
        )

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

        let excluded = applyEnvironmentAdjustments(
            &scores, device: device, budgetRemaining: budgetRemaining, factors: &factors
        )

        if case .smart = policy.strategy, !device.isThermallyConstrained {
            applyComplexityAdjustments(&scores, analysis: analysis)
            applyTaskAdjustments(&scores, analysis: analysis, providers: available)
        }
        await applyPerformanceAdjustments(&scores, analysis: analysis)
        await applyHealthAdjustments(&scores)
        enforceExclusions(&scores, excluded: excluded)
        scores.sort { $0.adjustedScore > $1.adjustedScore }

        return buildDecision(
            from: scores, factors: factors, analysis: analysis, privacy: privacy
        )
    }

    func filterByConstraints(
        _ providers: [any AIProvider],
        policy: RoutingPolicy,
        request: AIRequest,
        connectivity: ConnectivityState,
        privacy: PrivacyReport?,
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

        let forceLocal = privacy?.forcesOnDevice ?? false
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

    /// Applies device and budget state to the scores, and reports which providers the
    /// environment has *excluded* rather than merely penalised — see `enforceExclusions`.
    ///
    /// Thermal pressure is a penalty: a hot device can still serve a local model, just
    /// worse than a cloud one. An exhausted budget is not a penalty — the request cannot
    /// be paid for at all — so those providers are reported as excluded.
    func applyEnvironmentAdjustments(
        _ scores: inout [ProviderScore],
        device: DeviceCapabilities,
        budgetRemaining: Double?,
        factors: inout [RoutingFactor]
    ) -> Set<ProviderID> {
        var excluded: Set<ProviderID> = []

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
                scores[i].reasoning.append("budget exhausted — cloud excluded")
                excluded.insert(scores[i].providerID)
            }
            factors.append(.budget(remaining: budget, estimatedCost: 0))
        }

        return excluded
    }

    /// Re-applies the environment's exclusions after every additive pass has run.
    ///
    /// Without this the zeroing in `applyEnvironmentAdjustments` is only a starting
    /// value that the passes below it can spend back: `applyComplexityAdjustments` adds
    /// +15 to exactly the cloud tier an exhausted budget just zeroed whenever the prompt
    /// reads as complex, which is more than either provider's base score in a typical
    /// two-provider setup and so puts it back at the top of the decision.
    ///
    /// What that cost depends on the limit action. Under `.block` — the default —
    /// `SpendingGuard` refuses the call, so the damage is a published decision naming a
    /// provider the runtime will not use. Under `.fallbackToCheaper` it does not refuse
    /// at all: `reserveBudget` returns `nil` and the request goes out, unreserved and
    /// unbilled. Either way the router's own "budget exhausted removes cloud" rule was
    /// false in the decision it published, which is where callers read it.
    ///
    /// Scope: only the budget exclusion is enrolled. The context-window zeroing above is
    /// rescuable by the same passes and is the same bug class, but it is a separate
    /// change with its own behaviour consequences and is not made here. The zeroing
    /// `CapabilityMatcher` applies for a missing capability stays rescuable *by design*
    /// — that rescue is documented and pinned by tests.
    func enforceExclusions(_ scores: inout [ProviderScore], excluded: Set<ProviderID>) {
        guard !excluded.isEmpty else { return }
        for i in scores.indices where excluded.contains(scores[i].providerID) {
            scores[i].adjustedScore = 0
        }
    }

    func buildDecision(
        from scores: [ProviderScore],
        factors: [RoutingFactor],
        analysis: RequestAnalysis? = nil,
        privacy: PrivacyReport? = nil
    ) -> RoutingDecision {
        guard let best = scores.first, best.adjustedScore > 0 else {
            return .unavailable(factors: factors, privacyReport: privacy)
        }

        let alternatives = scores.dropFirst()
            .filter { $0.adjustedScore > 0 }
            .map(\.providerID)

        let reason = best.reasoning.isEmpty
            ? "\(best.providerID.displayName) selected (score: \(Int(best.adjustedScore)))"
            : best.reasoning.joined(separator: "; ")

        let candidates = scores.map { s in
            CandidateScore(
                provider: s.providerID,
                score: s.adjustedScore,
                reasoning: s.reasoning,
                isSelected: s.providerID == best.providerID
            )
        }

        return RoutingDecision(
            selectedProvider: best.providerID,
            reason: reason,
            alternativeProviders: alternatives,
            confidenceScore: min(best.adjustedScore / 20.0, 1.0),
            factors: factors,
            analysis: analysis,
            candidateScores: candidates,
            privacyReport: privacy
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
