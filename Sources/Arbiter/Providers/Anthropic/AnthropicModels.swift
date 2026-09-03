// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Available Anthropic Claude models.
///
/// Two groups: the current lineup Anthropic recommends, and the models it
/// still lists as Active while marking them *legacy* — callable, but superseded.
/// Both are enumerated so a caller pinning a legacy model gets its real window,
/// output cap and price rather than the default model's.
///
/// IDs, context windows, output caps, prices and thinking modes verified
/// 2026-09-03 against
/// https://platform.claude.com/docs/en/about-claude/models/overview,
/// https://platform.claude.com/docs/en/about-claude/pricing,
/// https://platform.claude.com/docs/en/about-claude/model-deprecations,
/// https://platform.claude.com/docs/en/build-with-claude/context-windows and
/// each legacy model's own page under https://platform.claude.com/docs/en/models/
///
/// The enum is a convenience, not a gate: `AIRequest.model` is a free-form
/// string, so a model Anthropic ships that is not listed here — a Mythos model
/// under limited availability, say — can still be named directly, and
/// ``named(_:)`` simply returns `nil` for it. Per-model rules apply only to IDs
/// this catalogue recognises.
///
/// Current-generation IDs carry no date suffix — they are pinned snapshots in
/// their own right, so appending a date produces a model that does not exist.
///
/// Long-context pricing: models from the 4.6 generation on bill the full 1M
/// token window at the standard per-token rate, so there is no separate
/// over-200K tier to encode (pricing page, "Long context pricing").
public enum AnthropicModel: String, Sendable, CaseIterable {
    /// Claude Sonnet 5 — best combination of speed and intelligence.
    case claudeSonnet5 = "claude-sonnet-5"
    /// Claude Opus 5 — complex agentic coding and enterprise work.
    case claudeOpus5 = "claude-opus-5"
    /// Claude Fable 5.1 — demanding reasoning and long-horizon agentic work.
    case claudeFable51 = "claude-fable-5-1"
    /// Claude Haiku 4.5 — fastest model with near-frontier intelligence.
    case claudeHaiku45 = "claude-haiku-4-5-20251001"

    // Legacy: still Active on the deprecations page and callable, but the
    // documentation recommends migrating off each of them.

    /// Claude Fable 5 — legacy Fable; superseded by Claude Fable 5.1.
    case claudeFable5 = "claude-fable-5"
    /// Claude Opus 4.8 — legacy Opus; superseded by Claude Opus 5.
    case claudeOpus48 = "claude-opus-4-8"
    /// Claude Opus 4.7 — legacy Opus; superseded by Claude Opus 5.
    case claudeOpus47 = "claude-opus-4-7"
    /// Claude Opus 4.6 — legacy Opus; superseded by Claude Opus 5.
    case claudeOpus46 = "claude-opus-4-6"
    /// Claude Opus 4.5 — legacy Opus; superseded by Claude Opus 5.
    case claudeOpus45 = "claude-opus-4-5-20251101"
    /// Claude Sonnet 4.6 — legacy Sonnet; superseded by Claude Sonnet 5.
    case claudeSonnet46 = "claude-sonnet-4-6"
    /// Claude Sonnet 4.5 — legacy Sonnet; superseded by Claude Sonnet 5.
    case claudeSonnet45 = "claude-sonnet-4-5-20250929"

    /// Claude Sonnet 4 — retired on the first-party API on 2026-06-15; kept so
    /// stored conversations and partner-platform deployments still resolve.
    /// Requests to it fail on the Claude API.
    @available(*, deprecated, message: "Claude Sonnet 4 was retired on 2026-06-15; use .claudeSonnet5")
    case claudeSonnet4 = "claude-sonnet-4-20250514"

    /// The models that can currently be called — the current lineup first,
    /// then the legacy models Anthropic still lists as Active.
    ///
    /// Hand-written because a deprecated case cannot take part in the
    /// synthesised conformance; the retired `.claudeSonnet4` is deliberately
    /// absent, since a request naming it fails.
    public static var allCases: [AnthropicModel] {
        [.claudeSonnet5, .claudeOpus5, .claudeFable51, .claudeHaiku45,
         .claudeFable5, .claudeOpus48, .claudeOpus47, .claudeOpus46,
         .claudeOpus45, .claudeSonnet46, .claudeSonnet45]
    }

    /// Whether this model is outside the lineup Anthropic currently recommends.
    ///
    /// True for the legacy-but-Active models, which are callable and have a
    /// recommended successor, and for the retired `.claudeSonnet4`, which is not
    /// callable at all — `allCases` is what separates those two.
    public var isLegacy: Bool {
        switch self {
        case .claudeSonnet5, .claudeOpus5, .claudeFable51, .claudeHaiku45: false
        case .claudeFable5, .claudeOpus48, .claudeOpus47, .claudeOpus46,
             .claudeOpus45, .claudeSonnet46, .claudeSonnet45: true
        case .claudeSonnet4: true
        }
    }

    /// Human-readable model name
    public var displayName: String {
        switch self {
        case .claudeSonnet5: "Claude Sonnet 5"
        case .claudeOpus5: "Claude Opus 5"
        case .claudeFable51: "Claude Fable 5.1"
        case .claudeHaiku45: "Claude Haiku 4.5"
        case .claudeFable5: "Claude Fable 5"
        case .claudeOpus48: "Claude Opus 4.8"
        case .claudeOpus47: "Claude Opus 4.7"
        case .claudeOpus46: "Claude Opus 4.6"
        case .claudeOpus45: "Claude Opus 4.5"
        case .claudeSonnet46: "Claude Sonnet 4.6"
        case .claudeSonnet45: "Claude Sonnet 4.5"
        case .claudeSonnet4: "Claude Sonnet 4"
        }
    }

    /// Maximum input context window in tokens
    public var contextWindow: Int {
        switch self {
        case .claudeSonnet5, .claudeOpus5, .claudeFable51,
             .claudeFable5, .claudeOpus48, .claudeOpus47, .claudeOpus46,
             .claudeSonnet46: 1_000_000
        case .claudeHaiku45, .claudeOpus45, .claudeSonnet45, .claudeSonnet4: 200_000
        }
    }

    /// Maximum tokens the model can generate in one synchronous response.
    ///
    /// `nil` for a retired model whose limit the current documentation no
    /// longer publishes.
    public var maxOutputTokens: Int? {
        switch self {
        case .claudeSonnet5, .claudeOpus5, .claudeFable51,
             .claudeFable5, .claudeOpus48, .claudeOpus47, .claudeOpus46,
             .claudeSonnet46: 128_000
        case .claudeHaiku45, .claudeOpus45, .claudeSonnet45: 64_000
        case .claudeSonnet4: nil
        }
    }

    /// Cost per million input tokens in USD
    public var costPerMillionInput: Double {
        switch self {
        case .claudeSonnet5: 2.0
        case .claudeOpus5, .claudeOpus48, .claudeOpus47, .claudeOpus46, .claudeOpus45: 5.0
        case .claudeFable51, .claudeFable5: 10.0
        case .claudeHaiku45: 1.0
        case .claudeSonnet46, .claudeSonnet45, .claudeSonnet4: 3.0
        }
    }

    /// Cost per million output tokens in USD
    public var costPerMillionOutput: Double {
        switch self {
        case .claudeSonnet5: 10.0
        case .claudeOpus5, .claudeOpus48, .claudeOpus47, .claudeOpus46, .claudeOpus45: 25.0
        case .claudeFable51, .claudeFable5: 50.0
        case .claudeHaiku45: 5.0
        case .claudeSonnet46, .claudeSonnet45, .claudeSonnet4: 15.0
        }
    }

    /// How this model accepts a thinking configuration.
    public var thinkingSupport: ThinkingSupport {
        switch self {
        case .claudeFable51, .claudeFable5: .alwaysOnAdaptive
        case .claudeSonnet5, .claudeOpus5, .claudeOpus48, .claudeOpus47: .adaptive
        // The 4.6 generation is the crossover: adaptive is the documented mode,
        // and a `budget_tokens` request is deprecated there rather than refused.
        // Rejecting one locally would refuse a call the API still serves.
        case .claudeOpus46, .claudeSonnet46: .adaptiveOrExtended
        case .claudeHaiku45, .claudeOpus45, .claudeSonnet45, .claudeSonnet4: .extended
        }
    }

    /// Whether the model accepts non-default `temperature` / `top_p`.
    ///
    /// From Claude Opus 4.7 on, a non-default sampling parameter is a 400, so
    /// those values are dropped rather than sent (Opus 5 migration guide,
    /// "Sampling parameters removed").
    public var supportsSamplingControls: Bool {
        switch self {
        case .claudeSonnet5, .claudeOpus5, .claudeFable51,
             .claudeFable5, .claudeOpus48, .claudeOpus47: false
        case .claudeHaiku45, .claudeOpus46, .claudeOpus45,
             .claudeSonnet46, .claudeSonnet45, .claudeSonnet4: true
        }
    }

    /// Resolve a raw model identifier from a request, if it names a known model.
    static func named(_ rawValue: String?) -> AnthropicModel? {
        guard let rawValue else { return nil }
        return AnthropicModel(rawValue: rawValue)
    }
}

/// Which thinking configuration a model accepts.
public enum ThinkingSupport: Sendable, Equatable {
    /// Thinking is always on; only `.adaptive` may be sent.
    case alwaysOnAdaptive
    /// Adaptive thinking; a fixed `budget_tokens` is rejected.
    case adaptive
    /// Both forms are accepted. The 4.6 generation, where extended thinking is
    /// documented as deprecated in favour of adaptive but still served — so a
    /// caller's `budget_tokens` is passed through rather than refused.
    case adaptiveOrExtended
    /// Manual extended thinking driven by `budget_tokens`; `.adaptive` is
    /// not accepted.
    case extended
}
