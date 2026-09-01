// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Anthropic-specific request settings.
///
/// Attach with `AIRequest.withProviderOptions(_:for:)` or
/// `RequestOptions.providerOptions[.anthropic]`; every other provider ignores it.
///
/// ```swift
/// let request = AIRequest.chat("Prove it.")
///     .withProviderOptions(AnthropicOptions(thinking: .adaptive), for: .anthropic)
/// ```
public struct AnthropicOptions: Sendable, Equatable {
    /// How the model should think before answering. Which values a model
    /// accepts differs per model — see `AnthropicModel.thinkingSupport`.
    public var thinking: AnthropicThinking?
    /// Whether the model should return its thinking text.
    ///
    /// Current models default to omitting it, so `AIResponse.reasoning` stays
    /// `nil` unless `.summarized` is requested here.
    public var thinkingDisplay: AnthropicThinkingDisplay?
    /// Prompt-cache breakpoint placement, or `nil` to leave caching off.
    public var promptCaching: AnthropicPromptCaching?

    public init(
        thinking: AnthropicThinking? = nil,
        thinkingDisplay: AnthropicThinkingDisplay? = nil,
        promptCaching: AnthropicPromptCaching? = nil
    ) {
        self.thinking = thinking
        self.thinkingDisplay = thinkingDisplay
        self.promptCaching = promptCaching
    }

    /// Let the model decide how much to think (current-generation models).
    ///
    /// - Parameter display: pass `.summarized` to receive the thinking text in
    ///   `AIResponse.reasoning`; current models omit it by default.
    public static func adaptiveThinking(
        display: AnthropicThinkingDisplay? = nil
    ) -> AnthropicOptions {
        AnthropicOptions(thinking: .adaptive, thinkingDisplay: display)
    }

    /// Ask for extended thinking with a fixed token budget.
    ///
    /// Only models whose `thinkingSupport` is `.extended` accept a budget;
    /// current-generation models take `.adaptive` instead.
    public static func extendedThinking(budgetTokens: Int) -> AnthropicOptions {
        AnthropicOptions(thinking: .extended(budgetTokens: budgetTokens))
    }

    /// Cache the stable prefix of the request across calls.
    public static func promptCaching(breakpoints: Int) -> AnthropicOptions {
        AnthropicOptions(promptCaching: AnthropicPromptCaching(breakpoints: breakpoints))
    }
}

/// Whether the model returns a readable summary of its thinking.
///
/// The reasoning is billed and used either way; this only controls whether the
/// text comes back. Current models default to `.omitted`.
public enum AnthropicThinkingDisplay: String, Sendable, Equatable {
    case summarized
    case omitted
}

/// How the model allocates thinking before answering.
///
/// Note that Arbiter cannot yet replay thinking blocks: `AIResponse.reasoning`
/// is text only, and the block's `signature` — which the API requires back
/// unchanged on the next turn — has nowhere to live in `MessageContent`. Use
/// thinking for single-turn requests; a multi-round tool conversation with
/// thinking enabled will be rejected by the API on its second request.
public enum AnthropicThinking: Sendable, Equatable {
    /// The model decides how much to think. Sent as `{"type": "adaptive"}`.
    case adaptive
    /// A fixed thinking budget. Sent as
    /// `{"type": "enabled", "budget_tokens": n}`.
    case extended(budgetTokens: Int)
}

/// Prompt-cache configuration.
///
/// Anthropic allows at most four cache breakpoints per request, so
/// `breakpoints` is clamped to `1...4`. Arbiter spends them in render order —
/// the tool list first, then the system prompt, then the most recent messages —
/// because a breakpoint caches everything before it.
public struct AnthropicPromptCaching: Sendable, Equatable {
    /// The maximum number of cache breakpoints allowed on one request.
    public static let maxBreakpoints = 4

    public let breakpoints: Int

    public init(breakpoints: Int = 1) {
        self.breakpoints = min(max(breakpoints, 1), Self.maxBreakpoints)
    }
}
