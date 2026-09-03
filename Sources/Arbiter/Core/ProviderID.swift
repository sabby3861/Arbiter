// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Identifies which AI provider is being used
public enum ProviderID: String, Sendable, Hashable, Codable {
    case anthropic
    case openAI
    case gemini
    case ollama
    case mlx
    case appleFoundation
    // TODO: Apple's Private Cloud Compute tier would be a case here. It is deliberately
    // absent until there is an implementation behind it: this enum is public and closed,
    // and a case with no provider would churn every exhaustive switch downstream while
    // offering callers a tier that cannot serve a request. The API it needs ships with the
    // OS 27 SDK, and the roadmap tracks adding the tier alongside it.

    /// Human-readable name for display purposes
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .gemini: "Google Gemini"
        case .ollama: "Ollama"
        case .mlx: "MLX"
        case .appleFoundation: "Apple Foundation Models"
        }
    }

    /// Where this provider runs
    public var tier: ProviderTier {
        switch self {
        case .anthropic, .openAI, .gemini: .cloud
        case .ollama: .localServer
        case .mlx: .onDevice
        case .appleFoundation: .system
        }
    }
}

/// Classification of where a provider executes
public enum ProviderTier: String, Sendable, Hashable {
    case cloud
    case localServer
    case onDevice
    case system
}
