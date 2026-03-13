// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Available Anthropic Claude models
public enum AnthropicModel: String, Sendable, CaseIterable {
    case claude4Sonnet = "claude-sonnet-4-20250514"
    case claude45Haiku = "claude-haiku-4-5-20251001"
    case claude4Opus = "claude-opus-4-20250918"

    /// Human-readable model name
    public var displayName: String {
        switch self {
        case .claude4Sonnet: "Claude Sonnet 4"
        case .claude45Haiku: "Claude 4.5 Haiku"
        case .claude4Opus: "Claude Opus 4"
        }
    }

    /// Maximum input context window in tokens
    public var contextWindow: Int {
        switch self {
        case .claude4Sonnet: 200_000
        case .claude45Haiku: 200_000
        case .claude4Opus: 200_000
        }
    }

    /// Cost per million input tokens in USD
    public var costPerMillionInput: Double {
        switch self {
        case .claude4Sonnet: 3.0
        case .claude45Haiku: 0.80
        case .claude4Opus: 15.0
        }
    }

    /// Cost per million output tokens in USD
    public var costPerMillionOutput: Double {
        switch self {
        case .claude4Sonnet: 15.0
        case .claude45Haiku: 4.0
        case .claude4Opus: 75.0
        }
    }
}
