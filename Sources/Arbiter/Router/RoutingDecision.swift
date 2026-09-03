// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// The result of the Smart Router's provider selection.
public struct RoutingDecision: Sendable, Equatable {
    public let selectedProvider: ProviderID?
    public let reason: String
    public let alternativeProviders: [ProviderID]
    public let confidenceScore: Double
    public let factors: [RoutingFactor]
    public let analysis: RequestAnalysis?
    public let candidateScores: [CandidateScore]
    /// What the privacy assessment found, and whether it constrained routing.
    ///
    /// Categories only — the report never carries the matched values, so it is safe to
    /// log or display. `nil` when no ``PrivacyGuard`` is configured.
    public let privacyReport: PrivacyReport?

    public init(
        selectedProvider: ProviderID?,
        reason: String,
        alternativeProviders: [ProviderID] = [],
        confidenceScore: Double = 1.0,
        factors: [RoutingFactor] = [],
        analysis: RequestAnalysis? = nil,
        candidateScores: [CandidateScore] = [],
        privacyReport: PrivacyReport? = nil
    ) {
        self.selectedProvider = selectedProvider
        self.reason = reason
        self.alternativeProviders = alternativeProviders
        self.confidenceScore = confidenceScore
        self.factors = factors
        self.analysis = analysis
        self.candidateScores = candidateScores
        self.privacyReport = privacyReport
    }

    /// No providers could handle the request.
    static func unavailable(
        factors: [RoutingFactor],
        privacyReport: PrivacyReport? = nil
    ) -> RoutingDecision {
        let constrainedByPrivacy = privacyReport?.forcesOnDevice == true
        return RoutingDecision(
            selectedProvider: nil,
            reason: constrainedByPrivacy
                ? "No providers available that satisfy the privacy constraint"
                : "No providers available",
            confidenceScore: 0,
            factors: factors,
            privacyReport: privacyReport
        )
    }

    /// Whether routing found a viable provider.
    public var isAvailable: Bool { selectedProvider != nil && confidenceScore > 0 }
}

/// A factor that influenced the routing decision.
public enum RoutingFactor: Sendable, Equatable {
    case connectivity(available: Bool)
    case capability(task: AITask, providerCanHandle: Bool)
    case cost(estimatedCost: Double)
    case latency(estimated: LatencyTier)
    case privacy(level: PrivacyLevel, required: PrivacyLevel)
    case deviceCapability(canRunLocally: Bool, reason: String?)
    case thermal(state: String, recommendation: String)
    case budget(remaining: Double, estimatedCost: Double)
}

/// Events emitted during routing for observability.
public enum RoutingEvent: Sendable, Equatable {
    case decided(RoutingDecision)
    case fallback(from: ProviderID, to: ProviderID, reason: String)
    case allProvidersFailed
}

/// A recorded routing decision for the debug view
public struct RoutingDebugEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let requestSummary: String
    public let decision: RoutingDecision

    public init(timestamp: Date = Date(), requestSummary: String, decision: RoutingDecision) {
        self.timestamp = timestamp
        self.requestSummary = requestSummary
        self.decision = decision
    }
}

/// Score for a single candidate provider, sorted by score descending.
public struct CandidateScore: Sendable, Equatable {
    public let provider: ProviderID
    public let score: Double
    public let reasoning: [String]
    public let isSelected: Bool

    public init(provider: ProviderID, score: Double, reasoning: [String], isSelected: Bool) {
        self.provider = provider
        self.score = score
        self.reasoning = reasoning
        self.isSelected = isSelected
    }
}
