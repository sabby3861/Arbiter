// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// A complete response from an AI provider
public struct AIResponse: Sendable, Equatable {
    public let id: String
    public let content: String
    public let role: Role
    public let model: String
    public let provider: ProviderID
    public let toolCalls: [ToolCall]
    public let usage: TokenUsage?
    public let finishReason: FinishReason?
    /// Model reasoning that the provider returns separately from the answer
    /// (Anthropic thinking blocks). `nil` when the provider returned none.
    ///
    /// This is the readable text only. It is not enough to replay the turn:
    /// Anthropic requires a thinking block's opaque `signature` back unchanged
    /// on the next request of a tool-use conversation, and that signature is
    /// not preserved here.
    public let reasoning: String?
    /// Sources the model cited, when the request enabled citations.
    public let citations: [Citation]

    public init(
        id: String,
        content: String,
        role: Role = .assistant,
        model: String,
        provider: ProviderID,
        toolCalls: [ToolCall] = [],
        usage: TokenUsage? = nil,
        finishReason: FinishReason? = nil,
        reasoning: String? = nil,
        citations: [Citation] = []
    ) {
        self.id = id
        self.content = content
        self.role = role
        self.model = model
        self.provider = provider
        self.toolCalls = toolCalls
        self.usage = usage
        self.finishReason = finishReason
        self.reasoning = reasoning
        self.citations = citations
    }
}

/// A source the model cited for part of its answer.
///
/// Provider-agnostic: Anthropic document citations populate `documentIndex`
/// and the character/page range; web-grounded providers populate `url`.
public struct Citation: Sendable, Equatable, Codable {
    /// The quoted span from the source.
    public let citedText: String?
    /// Title of the cited document, when the provider supplies one.
    public let title: String?
    /// Index of the cited document within the request's document blocks.
    public let documentIndex: Int?
    /// Start of the cited range (character index, or 1-indexed page number).
    public let startIndex: Int?
    /// End of the cited range, exclusive for characters, inclusive for pages.
    public let endIndex: Int?
    /// Source URL, for providers that cite the web rather than attached documents.
    public let url: URL?

    public init(
        citedText: String? = nil,
        title: String? = nil,
        documentIndex: Int? = nil,
        startIndex: Int? = nil,
        endIndex: Int? = nil,
        url: URL? = nil
    ) {
        self.citedText = citedText
        self.title = title
        self.documentIndex = documentIndex
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.url = url
    }
}

/// Token usage statistics for a request
public struct TokenUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    /// Tokens written to the provider's prompt cache on this request, when reported.
    ///
    /// Providers bill cache writes and reads at different rates from base input
    /// tokens and report them separately, so these are *not* folded into
    /// `inputTokens` or `totalTokens`.
    public let cacheCreationInputTokens: Int?
    /// Tokens served from the provider's prompt cache on this request, when reported.
    public let cacheReadInputTokens: Int?

    /// What a five-minute cache write costs relative to a base input token.
    public static let cacheWriteRateMultiplier = 1.25
    /// What a cache read costs relative to a base input token.
    public static let cacheReadRateMultiplier = 0.1

    public var totalTokens: Int { inputTokens + outputTokens }

    /// Every input token billed for this request, cached ones included.
    ///
    /// `totalTokens` counts only what the provider reported as fresh input, so
    /// this is the figure to use when reasoning about context size or spend.
    public var billedInputTokens: Int {
        inputTokens + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
    }

    /// Cost in USD for this usage at the given per-million rates.
    ///
    /// Cached tokens are billed on top of `inputTokens`, not inside it — at a
    /// premium to write and a discount to read — so they are priced separately.
    public func cost(inputPerMillion: Double?, outputPerMillion: Double?) -> Double {
        let inputRate = (inputPerMillion ?? 0) / 1_000_000
        let outputRate = (outputPerMillion ?? 0) / 1_000_000
        return inputRate * Double(inputTokens)
            + outputRate * Double(outputTokens)
            + inputRate * Self.cacheWriteRateMultiplier * Double(cacheCreationInputTokens ?? 0)
            + inputRate * Self.cacheReadRateMultiplier * Double(cacheReadInputTokens ?? 0)
    }

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}

/// Why the model stopped generating
public enum FinishReason: String, Sendable, Equatable {
    case complete = "end_turn"
    case maxTokens = "max_tokens"
    case toolCall = "tool_use"
    case contentFilter = "content_filter"
    /// The model hit one of the caller's configured stop sequences.
    case stopSequence = "stop_sequence"
    /// The model declined to answer (Anthropic `refusal`).
    case refusal
    /// A long-running server-side turn was paused (Anthropic `pause_turn`).
    /// Continuing it requires sending the turn's content blocks back unchanged,
    /// which the unified response type cannot yet express.
    case pauseTurn = "pause_turn"
    case error
}
