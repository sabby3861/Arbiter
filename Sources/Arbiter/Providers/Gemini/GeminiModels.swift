// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Available Google Gemini models.
///
/// IDs and prices verified 2 September 2026 against
/// https://ai.google.dev/gemini-api/docs/models and
/// https://ai.google.dev/gemini-api/docs/pricing.
///
/// Token limits are not on either of those pages. They are published per model
/// under https://ai.google.dev/gemini-api/docs/models/<id>, and were read there
/// on 3 September 2026 — see ``contextWindow``.
public enum GeminiModel: String, Sendable, CaseIterable {
    case flash38 = "gemini-3.8-flash"
    case flash37 = "gemini-3.7-flash"
    case flash36 = "gemini-3.6-flash"
    case flash35 = "gemini-3.5-flash"
    case flashLite35 = "gemini-3.5-flash-lite"
    case flashLite31 = "gemini-3.1-flash-lite"
    case pro31Preview = "gemini-3.1-pro-preview"
    case flash25 = "gemini-2.5-flash"
    case flashLite25 = "gemini-2.5-flash-lite"
    case pro25 = "gemini-2.5-pro"

    /// The model with this API ID, or `nil` for one Arbiter does not know.
    ///
    /// A caller may name a preview or a proxy's own alias; per-model rules are
    /// applied only when the model is recognised.
    public static func named(_ id: String) -> GeminiModel? {
        GeminiModel(rawValue: id)
    }

    public var displayName: String {
        switch self {
        case .flash38: "Gemini 3.8 Flash"
        case .flash37: "Gemini 3.7 Flash"
        case .flash36: "Gemini 3.6 Flash"
        case .flash35: "Gemini 3.5 Flash"
        case .flashLite35: "Gemini 3.5 Flash-Lite"
        case .flashLite31: "Gemini 3.1 Flash-Lite"
        case .pro31Preview: "Gemini 3.1 Pro (Preview)"
        case .flash25: "Gemini 2.5 Flash"
        case .flashLite25: "Gemini 2.5 Flash-Lite"
        case .pro25: "Gemini 2.5 Pro"
        }
    }

    /// Input token limit.
    ///
    /// Flat across the catalogue: the per-model pages publish 1,048,576 for
    /// every model spot-checked on 3 September 2026 —
    /// `gemini-3.5-flash`, `gemini-2.5-pro` and `gemini-2.5-flash-lite`, chosen
    /// to span both families and all three sizes. The models index publishes no
    /// limits at all, so this is the figure the per-model pages give rather than
    /// a family-wide guarantee Google states anywhere; a model that departs from
    /// it would be filtered against the wrong window until this is corrected.
    public var contextWindow: Int { 1_048_576 }

    /// Output token limit. Same source and same caveat as ``contextWindow``:
    /// 65,536 on each of the three pages checked.
    public var maxOutputTokens: Int { 65_536 }

    /// Price per million input tokens, in USD, on the paid Standard tier.
    ///
    /// Two caveats the flat number cannot carry:
    ///
    /// * `pro31Preview` and `pro25` bill prompts over 200K tokens at a higher
    ///   rate (`longContextInputThreshold`); the figure here is the ≤200K rate.
    ///   Threshold pricing belongs to the roadmap's unified-caching item, which
    ///   already owns the same problem for OpenAI.
    /// * The 3.6, 3.7 and 3.8 Flash rate is promotional through 31 December 2026
    ///   and doubles on 1 January 2027 ($1.50 in / $7.50 out). Gemini 3.5 Flash
    ///   is *not* on that promotion — its $1.50 / $9.00 is the standard rate and
    ///   does not change on that date. Re-verified 3 September 2026 against
    ///   https://ai.google.dev/gemini-api/docs/pricing
    public var costPerMillionInput: Double {
        switch self {
        case .flash38, .flash37, .flash36: 0.75
        case .flash35: 1.50
        case .flashLite35: 0.30
        case .flashLite31: 0.25
        case .pro31Preview: 2.00
        case .flash25: 0.30
        case .flashLite25: 0.10
        case .pro25: 1.25
        }
    }

    /// Price per million output tokens, in USD, on the paid Standard tier.
    ///
    /// Google bills thinking tokens as output, which is why
    /// ``GeminiMapper`` folds `thoughtsTokenCount` into `TokenUsage.outputTokens`.
    /// See ``costPerMillionInput`` for the tiering and promotional caveats.
    public var costPerMillionOutput: Double {
        switch self {
        case .flash38, .flash37, .flash36: 3.75
        case .flash35: 9.00
        case .flashLite35: 2.50
        case .flashLite31: 1.50
        case .pro31Preview: 12.00
        case .flash25: 2.50
        case .flashLite25: 0.40
        case .pro25: 10.00
        }
    }

    /// The prompt size above which this model bills at a higher rate, if it has one.
    ///
    /// Nothing prices against this yet — ``costPerMillionInput`` reports the
    /// lower tier — but recording it keeps the fact next to the rate it
    /// qualifies.
    public var longContextInputThreshold: Int? {
        switch self {
        case .pro31Preview, .pro25: 200_000
        default: nil
        }
    }

    /// How this model wants its reasoning configured.
    ///
    /// Gemini 3 takes a `thinkingLevel`; the 2.5 series takes a numeric
    /// `thinkingBudget`. Sending the wrong one is an API error, so
    /// ``GeminiMapper`` rejects the mismatch locally.
    /// Verified 2 September 2026 against
    /// https://ai.google.dev/gemini-api/docs/generate-content/thinking.
    public var thinkingSupport: GeminiThinkingSupport {
        switch self {
        case .flash38, .flash37, .pro31Preview:
            .levels([.low, .medium, .high])
        case .flash36, .flash35, .flashLite35, .flashLite31:
            .levels([.minimal, .low, .medium, .high])
        case .pro25:
            // Thinking cannot be turned off on 2.5 Pro.
            .budget(range: 128...32_768, canDisable: false)
        case .flash25:
            .budget(range: 0...24_576, canDisable: true)
        case .flashLite25:
            .budget(range: 512...24_576, canDisable: true)
        }
    }
}

/// Which thinking control a model accepts.
public enum GeminiThinkingSupport: Sendable, Equatable {
    /// Gemini 3: a `thinkingLevel`, restricted to these levels.
    case levels(Set<GeminiThinkingLevel>)
    /// Gemini 2.5: a numeric `thinkingBudget` within this range.
    ///
    /// `-1` always means dynamic thinking. `0` disables thinking, but only
    /// where `canDisable` is true; on 2.5 Pro it is rejected.
    case budget(range: ClosedRange<Int>, canDisable: Bool)
}
