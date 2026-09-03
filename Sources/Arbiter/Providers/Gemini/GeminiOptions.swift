// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Gemini-specific request settings.
///
/// Attach with `AIRequest.withProviderOptions(_:for:)` or
/// `RequestOptions.providerOptions[.gemini]`; every other provider ignores it.
///
/// ```swift
/// let request = AIRequest.chat("What shipped at I/O this year?")
///     .withProviderOptions(
///         GeminiOptions(thinking: .level(.low), googleSearch: true),
///         for: .gemini
///     )
/// ```
public struct GeminiOptions: Sendable, Equatable {
    /// How much the model should reason before answering. Which control a
    /// model accepts differs per model — see `GeminiModel.thinkingSupport`.
    public var thinking: GeminiThinking?
    /// Whether to return thought summaries.
    ///
    /// Summaries arrive as parts flagged `thought`, and land in
    /// `AIResponse.reasoning` / `AIResponse.thinking` rather than in `content`.
    public var includeThoughts: Bool?
    /// Whether to offer the model Google Search grounding.
    ///
    /// Sources the model used come back in `AIResponse.citations`. Search
    /// grounding is billed per request on top of tokens.
    public var googleSearch: Bool
    /// Per-category blocking thresholds, overriding the API defaults.
    public var safetySettings: [GeminiSafetySetting]
    /// The name of an existing cached content to prepend, in the API's own
    /// `cachedContents/{id}` form.
    public var cachedContent: String?

    public init(
        thinking: GeminiThinking? = nil,
        includeThoughts: Bool? = nil,
        googleSearch: Bool = false,
        safetySettings: [GeminiSafetySetting] = [],
        cachedContent: String? = nil
    ) {
        self.thinking = thinking
        self.includeThoughts = includeThoughts
        self.googleSearch = googleSearch
        self.safetySettings = safetySettings
        self.cachedContent = cachedContent
    }

    /// Ask a Gemini 3 model for a given depth of reasoning.
    public static func thinking(
        level: GeminiThinkingLevel,
        includeThoughts: Bool = false
    ) -> GeminiOptions {
        GeminiOptions(thinking: .level(level), includeThoughts: includeThoughts)
    }

    /// Ask a Gemini 2.5 model for a fixed thinking budget in tokens.
    ///
    /// `GeminiThinking.dynamicBudget` lets the model choose; `0` turns thinking
    /// off on the models that allow it.
    public static func thinking(
        budgetTokens: Int,
        includeThoughts: Bool = false
    ) -> GeminiOptions {
        GeminiOptions(thinking: .budget(tokens: budgetTokens), includeThoughts: includeThoughts)
    }

    /// Let the model ground its answer in Google Search.
    public static func grounded() -> GeminiOptions {
        GeminiOptions(googleSearch: true)
    }
}

/// How the model allocates reasoning before answering.
///
/// Gemini 3 models take a level; the 2.5 series takes a token budget. The two
/// cannot be combined, and a model rejects the control it does not use — so
/// `GeminiMapper` fails the request locally rather than sending a guaranteed
/// HTTP 400.
public enum GeminiThinking: Sendable, Equatable {
    /// Sent as `thinkingConfig.thinkingLevel` (Gemini 3 and later).
    case level(GeminiThinkingLevel)
    /// Sent as `thinkingConfig.thinkingBudget` (Gemini 2.5).
    case budget(tokens: Int)

    /// The budget value that hands the model the choice.
    public static let dynamicBudget = GeminiThinking.budget(tokens: -1)
}

/// Reasoning depth for models that take `thinkingLevel`.
public enum GeminiThinkingLevel: String, Sendable, Equatable, CaseIterable {
    case minimal
    case low
    case medium
    case high
}

/// A per-category blocking threshold.
public struct GeminiSafetySetting: Sendable, Equatable {
    public let category: GeminiHarmCategory
    public let threshold: GeminiHarmBlockThreshold

    public init(category: GeminiHarmCategory, threshold: GeminiHarmBlockThreshold) {
        self.category = category
        self.threshold = threshold
    }
}

/// The harm categories the Gemini models support.
public enum GeminiHarmCategory: String, Sendable, Equatable, CaseIterable {
    case harassment = "HARM_CATEGORY_HARASSMENT"
    case hateSpeech = "HARM_CATEGORY_HATE_SPEECH"
    case sexuallyExplicit = "HARM_CATEGORY_SEXUALLY_EXPLICIT"
    case dangerousContent = "HARM_CATEGORY_DANGEROUS_CONTENT"
    case jailbreak = "HARM_CATEGORY_JAILBREAK"
}

/// How much harm probability to allow before blocking.
public enum GeminiHarmBlockThreshold: String, Sendable, Equatable, CaseIterable {
    case blockLowAndAbove = "BLOCK_LOW_AND_ABOVE"
    case blockMediumAndAbove = "BLOCK_MEDIUM_AND_ABOVE"
    case blockOnlyHigh = "BLOCK_ONLY_HIGH"
    case blockNone = "BLOCK_NONE"
    /// Turn the filter off entirely.
    case off = "OFF"
}
