// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Scores how well a provider matches a given request.
struct CapabilityMatcher: Sendable {
    static func score(
        providerID: ProviderID,
        capabilities: ProviderCapabilities,
        for request: AIRequest,
        weights: ScoringWeights
    ) -> ProviderScore {
        var reasoning: [String] = []
        let capScore = scoreCapability(capabilities, request: request, reasoning: &reasoning)

        // Required capability missing — disqualify this provider entirely
        if capScore == 0 {
            return ProviderScore(
                providerID: providerID, baseScore: 0, adjustedScore: 0, reasoning: reasoning
            )
        }

        let qualityScore = scoreQuality(capabilities)
        let latencyScore = scoreLatency(capabilities)
        let privacyScore = scorePrivacy(capabilities)
        let costScore = scoreCost(capabilities)

        let totalWeight = weights.capability + weights.quality + weights.latency
            + weights.privacy + weights.cost

        let weighted = (capScore * weights.capability
            + qualityScore * weights.quality
            + latencyScore * weights.latency
            + privacyScore * weights.privacy
            + costScore * weights.cost)

        let normalized = totalWeight > 0 ? (weighted / totalWeight) : 0

        return ProviderScore(
            providerID: providerID,
            baseScore: normalized,
            adjustedScore: normalized,
            reasoning: reasoning
        )
    }
}

private extension CapabilityMatcher {
    static func scoreCapability(
        _ caps: ProviderCapabilities,
        request: AIRequest,
        reasoning: inout [String]
    ) -> Double {
        var score = 10.0
        if let tools = request.tools, !tools.isEmpty {
            if caps.supportsToolCalling {
                score += 5
                reasoning.append("supports tool calling")
            } else {
                reasoning.append("lacks required tool calling")
                return 0
            }
        }
        if request.messages.contains(where: { $0.content.isImage }) {
            if caps.supportsImageInput {
                score += 5
            } else {
                reasoning.append("lacks required image input")
                return 0
            }
        }
        return score
    }

    static func scoreQuality(_ caps: ProviderCapabilities) -> Double {
        let costProxy = (caps.costPerMillionOutputTokens ?? 0)
        switch costProxy {
        case 30...: return 20
        case 10..<30: return 16
        case 4..<10: return 12
        case 0.1..<4: return 8
        default: return 4
        }
    }

    static func scoreLatency(_ caps: ProviderCapabilities) -> Double {
        switch caps.estimatedLatency {
        case .instant: return 20
        case .fast: return 16
        case .moderate: return 10
        case .slow: return 5
        }
    }

    static func scorePrivacy(_ caps: ProviderCapabilities) -> Double {
        switch caps.privacyLevel {
        case .onDevice: return 20
        case .privateCloud: return 14
        case .thirdPartyCloud: return 5
        }
    }

    static func scoreCost(_ caps: ProviderCapabilities) -> Double {
        let totalCost = (caps.costPerMillionInputTokens ?? 0) + (caps.costPerMillionOutputTokens ?? 0)
        if totalCost == 0 { return 20 }
        switch totalCost {
        case ..<2: return 18
        case 2..<10: return 14
        case 10..<30: return 8
        default: return 3
        }
    }
}

/// Weighted scoring factors for different routing strategies.
struct ScoringWeights: Sendable {
    var capability: Double
    var quality: Double
    var latency: Double
    var privacy: Double
    var cost: Double

    static let balanced = ScoringWeights(capability: 1.0, quality: 1.0, latency: 1.0, privacy: 1.0, cost: 1.0)
    static let costOptimized = ScoringWeights(capability: 1.0, quality: 0.5, latency: 0.5, privacy: 0.5, cost: 3.0)
    static let privacyFirst = ScoringWeights(capability: 1.0, quality: 0.5, latency: 0.5, privacy: 3.0, cost: 0.5)
    static let qualityFirst = ScoringWeights(capability: 1.0, quality: 3.0, latency: 0.5, privacy: 0.5, cost: 0.5)
    static let latencyOptimized = ScoringWeights(capability: 1.0, quality: 0.5, latency: 3.0, privacy: 0.5, cost: 0.5)
}

/// A provider with its routing score.
struct ProviderScore: Sendable {
    let providerID: ProviderID
    let baseScore: Double
    var adjustedScore: Double
    var reasoning: [String]
}
