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
    public let provider: ProviderID

    public init(
        delta: String,
        accumulatedContent: String,
        isComplete: Bool,
        usage: TokenUsage? = nil,
        finishReason: FinishReason? = nil,
        provider: ProviderID
    ) {
        self.delta = delta
        self.accumulatedContent = accumulatedContent
        self.isComplete = isComplete
        self.usage = usage
        self.finishReason = finishReason
        self.provider = provider
    }
}
