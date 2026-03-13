// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Available Google Gemini models
public enum GeminiModel: String, Sendable, CaseIterable {
    case flash25 = "gemini-2.5-flash"
    case pro25 = "gemini-2.5-pro"

    public var displayName: String {
        switch self {
        case .flash25: "Gemini 2.5 Flash"
        case .pro25: "Gemini 2.5 Pro"
        }
    }

    public var contextWindow: Int {
        switch self {
        case .flash25: 1_000_000
        case .pro25: 1_000_000
        }
    }

    public var costPerMillionInput: Double {
        switch self {
        case .flash25: 0.15
        case .pro25: 1.25
        }
    }

    public var costPerMillionOutput: Double {
        switch self {
        case .flash25: 0.60
        case .pro25: 10.0
        }
    }
}
