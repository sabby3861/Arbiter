// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Available Anthropic Claude models.
///
/// IDs, context windows, output caps and prices verified 2026-09-01 against
/// https://platform.claude.com/docs/en/about-claude/models/overview and
/// https://platform.claude.com/docs/en/about-claude/pricing
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
    /// Claude Sonnet 4 — retired on the first-party API on 2026-06-15; kept so
    /// stored conversations and partner-platform deployments still resolve.
    /// Requests to it fail on the Claude API.
    @available(*, deprecated, message: "Claude Sonnet 4 was retired on 2026-06-15; use .claudeSonnet5")
    case claudeSonnet4 = "claude-sonnet-4-20250514"

    /// The models that can currently be called.
    ///
    /// Hand-written because a deprecated case cannot take part in the
    /// synthesised conformance; the retired `.claudeSonnet4` is deliberately
    /// absent, since a request naming it fails.
    public static var allCases: [AnthropicModel] {
        [.claudeSonnet5, .claudeOpus5, .claudeFable51, .claudeHaiku45]
    }

    /// Human-readable model name
    public var displayName: String {
        switch self {
        case .claudeSonnet5: "Claude Sonnet 5"
        case .claudeOpus5: "Claude Opus 5"
        case .claudeFable51: "Claude Fable 5.1"
        case .claudeHaiku45: "Claude Haiku 4.5"
        case .claudeSonnet4: "Claude Sonnet 4"
        }
    }

    /// Maximum input context window in tokens
    public var contextWindow: Int {
        switch self {
        case .claudeSonnet5, .claudeOpus5, .claudeFable51: 1_000_000
        case .claudeHaiku45, .claudeSonnet4: 200_000
        }
    }

    /// Maximum tokens the model can generate in one synchronous response.
    ///
    /// `nil` for a retired model whose limit the current documentation no
    /// longer publishes.
    public var maxOutputTokens: Int? {
        switch self {
        case .claudeSonnet5, .claudeOpus5, .claudeFable51: 128_000
        case .claudeHaiku45: 64_000
        case .claudeSonnet4: nil
        }
    }

    /// Cost per million input tokens in USD
    public var costPerMillionInput: Double {
        switch self {
        case .claudeSonnet5: 2.0
        case .claudeOpus5: 5.0
        case .claudeFable51: 10.0
        case .claudeHaiku45: 1.0
        case .claudeSonnet4: 3.0
        }
    }

    /// Cost per million output tokens in USD
    public var costPerMillionOutput: Double {
        switch self {
        case .claudeSonnet5: 10.0
        case .claudeOpus5: 25.0
        case .claudeFable51: 50.0
        case .claudeHaiku45: 5.0
        case .claudeSonnet4: 15.0
        }
    }

    /// How this model accepts a thinking configuration.
    public var thinkingSupport: ThinkingSupport {
        switch self {
        case .claudeFable51: .alwaysOnAdaptive
        case .claudeSonnet5, .claudeOpus5: .adaptive
        case .claudeHaiku45, .claudeSonnet4: .extended
        }
    }

    /// Whether the model accepts non-default `temperature` / `top_p`.
    ///
    /// From Claude Opus 4.7 on, a non-default sampling parameter is a 400, so
    /// those values are dropped rather than sent (Opus 5 migration guide,
    /// "Sampling parameters removed").
    public var supportsSamplingControls: Bool {
        switch self {
        case .claudeSonnet5, .claudeOpus5, .claudeFable51: false
        case .claudeHaiku45, .claudeSonnet4: true
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
    /// Manual extended thinking driven by `budget_tokens`; `.adaptive` is
    /// not accepted.
    case extended
}
