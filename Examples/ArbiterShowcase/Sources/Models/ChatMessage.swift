// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    let role: Role
    var content: String
    var isLoading: Bool
    let provider: String?
    let latency: String?
    let tokens: String?
    let timestamp = Date()

    enum Role: Sendable { case user, assistant, error }

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(
            role: .user, content: text, isLoading: false,
            provider: nil, latency: nil, tokens: nil
        )
    }

    static func loading() -> ChatMessage {
        ChatMessage(
            role: .assistant, content: "", isLoading: true,
            provider: nil, latency: nil, tokens: nil
        )
    }

    static func assistant(
        _ text: String,
        provider: String?,
        latency: String?,
        tokens: String?
    ) -> ChatMessage {
        ChatMessage(
            role: .assistant, content: text, isLoading: false,
            provider: provider, latency: latency, tokens: tokens
        )
    }

    static func error(_ text: String) -> ChatMessage {
        ChatMessage(
            role: .error, content: text, isLoading: false,
            provider: nil, latency: nil, tokens: nil
        )
    }
}
