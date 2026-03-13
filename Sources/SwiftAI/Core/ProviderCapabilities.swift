// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Describes what an AI provider can do
public struct ProviderCapabilities: Sendable, Equatable {
    public let supportedTasks: Set<AITask>
    public let maxContextTokens: Int
    public let supportsStreaming: Bool
    public let supportsToolCalling: Bool
    public let supportsImageInput: Bool
    public let costPerMillionInputTokens: Double?
    public let costPerMillionOutputTokens: Double?
    public let estimatedLatency: LatencyTier
    public let privacyLevel: PrivacyLevel

    public init(
        supportedTasks: Set<AITask>,
        maxContextTokens: Int,
        supportsStreaming: Bool,
        supportsToolCalling: Bool,
        supportsImageInput: Bool,
        costPerMillionInputTokens: Double?,
        costPerMillionOutputTokens: Double?,
        estimatedLatency: LatencyTier,
        privacyLevel: PrivacyLevel
    ) {
        self.supportedTasks = supportedTasks
        self.maxContextTokens = maxContextTokens
        self.supportsStreaming = supportsStreaming
        self.supportsToolCalling = supportsToolCalling
        self.supportsImageInput = supportsImageInput
        self.costPerMillionInputTokens = costPerMillionInputTokens
        self.costPerMillionOutputTokens = costPerMillionOutputTokens
        self.estimatedLatency = estimatedLatency
        self.privacyLevel = privacyLevel
    }
}

/// Types of tasks an AI provider can perform
public enum AITask: String, Sendable, Hashable {
    case chat
    case completion
    case embedding
    case imageGeneration
    case imageUnderstanding
    case codeGeneration
    case summarization
    case translation
    case structuredOutput
}

/// Expected response time classification
public enum LatencyTier: String, Sendable, Hashable, Comparable {
    case instant
    case fast
    case moderate
    case slow

    private var sortOrder: Int {
        switch self {
        case .instant: 0
        case .fast: 1
        case .moderate: 2
        case .slow: 3
        }
    }

    public static func < (lhs: LatencyTier, rhs: LatencyTier) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// How private the data processing is
public enum PrivacyLevel: String, Sendable, Hashable, Comparable {
    case onDevice
    case privateCloud
    case thirdPartyCloud

    private var sortOrder: Int {
        switch self {
        case .onDevice: 0
        case .privateCloud: 1
        case .thirdPartyCloud: 2
        }
    }

    public static func < (lhs: PrivacyLevel, rhs: PrivacyLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
