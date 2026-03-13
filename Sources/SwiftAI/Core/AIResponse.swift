// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// A complete response from an AI provider
public struct AIResponse: Sendable {
    public let id: String
    public let content: String
    public let role: Role
    public let model: String
    public let provider: ProviderID
    public let toolCalls: [ToolCall]
    public let usage: TokenUsage?
    public let finishReason: FinishReason?

    public init(
        id: String,
        content: String,
        role: Role = .assistant,
        model: String,
        provider: ProviderID,
        toolCalls: [ToolCall] = [],
        usage: TokenUsage? = nil,
        finishReason: FinishReason? = nil
    ) {
        self.id = id
        self.content = content
        self.role = role
        self.model = model
        self.provider = provider
        self.toolCalls = toolCalls
        self.usage = usage
        self.finishReason = finishReason
    }
}

/// Token usage statistics for a request
public struct TokenUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int

    public var totalTokens: Int { inputTokens + outputTokens }

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Why the model stopped generating
public enum FinishReason: String, Sendable, Equatable {
    case complete = "end_turn"
    case maxTokens = "max_tokens"
    case toolCall = "tool_use"
    case contentFilter = "content_filter"
    case error
}
