// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Available OpenAI models
public enum OpenAIModel: String, Sendable, CaseIterable {
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    case gpt4Turbo = "gpt-4-turbo"
    case o1 = "o1"
    case o1Mini = "o1-mini"
    case o3Mini = "o3-mini"

    public var displayName: String {
        switch self {
        case .gpt4o: "GPT-4o"
        case .gpt4oMini: "GPT-4o Mini"
        case .gpt4Turbo: "GPT-4 Turbo"
        case .o1: "o1"
        case .o1Mini: "o1 Mini"
        case .o3Mini: "o3 Mini"
        }
    }

    public var contextWindow: Int {
        switch self {
        case .gpt4o, .gpt4oMini: 128_000
        case .gpt4Turbo: 128_000
        case .o1, .o1Mini, .o3Mini: 200_000
        }
    }

    public var costPerMillionInput: Double {
        switch self {
        case .gpt4o: 2.50
        case .gpt4oMini: 0.15
        case .gpt4Turbo: 10.0
        case .o1: 15.0
        case .o1Mini: 1.10
        case .o3Mini: 1.10
        }
    }

    public var costPerMillionOutput: Double {
        switch self {
        case .gpt4o: 10.0
        case .gpt4oMini: 0.60
        case .gpt4Turbo: 30.0
        case .o1: 60.0
        case .o1Mini: 4.40
        case .o3Mini: 4.40
        }
    }

    public var supportsStreaming: Bool {
        switch self {
        case .o1, .o1Mini, .o3Mini: false
        default: true
        }
    }
}
