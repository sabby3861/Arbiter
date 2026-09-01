// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// A single chunk in a streaming AI response
public struct AIStreamChunk: Sendable, Equatable {
    public let delta: String
    public let accumulatedContent: String
    public let isComplete: Bool
    public let usage: TokenUsage?
    public let finishReason: FinishReason?
    /// Tool calls completed by this chunk.
    ///
    /// Providers stream tool arguments as text fragments, so a call only
    /// becomes available once its arguments are complete. A chunk that
    /// finishes one call carries that call; the final chunk carries every
    /// call made during the turn.
    public let toolCalls: [ToolCall]?
    public let provider: ProviderID

    public init(
        delta: String,
        accumulatedContent: String,
        isComplete: Bool,
        usage: TokenUsage? = nil,
        finishReason: FinishReason? = nil,
        toolCalls: [ToolCall]? = nil,
        provider: ProviderID
    ) {
        self.delta = delta
        self.accumulatedContent = accumulatedContent
        self.isComplete = isComplete
        self.usage = usage
        self.finishReason = finishReason
        self.toolCalls = toolCalls
        self.provider = provider
    }
}
