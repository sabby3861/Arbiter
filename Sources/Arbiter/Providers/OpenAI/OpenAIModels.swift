// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Available OpenAI models.
///
/// IDs, context windows, output caps and prices verified 2026-09-01, and
/// re-checked 2026-09-03, against
/// https://developers.openai.com/api/docs/models and
/// https://developers.openai.com/api/docs/pricing
///
/// Two entries are not fully checkable against those two pages, and say so at
/// their own case: `gpt-4-turbo`, whose rates the pricing page publishes under
/// the dated snapshot `gpt-4-turbo-2024-04-09`, and `o1-mini`, which neither
/// page lists at all.
///
/// Note that the enum is a convenience, not a gate: `AIRequest.model` is a
/// free-form string, so a preview model or an OpenAI-compatible host's own
/// alias can always be named directly. Per-model rules are applied only when
/// the ID is one this catalogue recognises.
public enum OpenAIModel: String, Sendable, CaseIterable {
    /// GPT‑5.6 Sol — flagship for complex professional work.
    case gpt56Sol = "gpt-5.6-sol"
    /// GPT‑5.6 Terra — balances intelligence and cost.
    case gpt56Terra = "gpt-5.6-terra"
    /// GPT‑5.6 Luna — cost-sensitive, high-volume workloads.
    case gpt56Luna = "gpt-5.6-luna"
    /// GPT‑5 — previous-generation reasoning flagship.
    case gpt5 = "gpt-5"
    /// GPT‑5 mini — cheaper, lower-latency GPT‑5.
    case gpt5Mini = "gpt-5-mini"
    /// GPT‑5 nano — fastest and cheapest GPT‑5.
    case gpt5Nano = "gpt-5-nano"
    /// GPT‑4.1 — strongest non-reasoning model, ~1M context.
    case gpt41 = "gpt-4.1"
    /// GPT‑4.1 mini — smaller, faster GPT‑4.1.
    case gpt41Mini = "gpt-4.1-mini"
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    /// o3 — reasoning model for complex tasks.
    case o3 = "o3"
    /// o4‑mini — fast, cost-efficient reasoning.
    case o4Mini = "o4-mini"
    case o3Mini = "o3-mini"
    case o1 = "o1"
    /// GPT‑4 Turbo. The pricing page carries the rates under the dated
    /// snapshot `gpt-4-turbo-2024-04-09` ($10 / $30) rather than under this
    /// alias, and the models page no longer lists either form.
    case gpt4Turbo = "gpt-4-turbo"
    /// o1‑mini — superseded by `o3-mini`. Kept so stored conversations
    /// resolve. Neither the models page nor the pricing page lists this ID any
    /// more, so its rates below are `o3-mini`'s, carried over from when the
    /// documentation named that model as its replacement at the same price;
    /// they cannot be re-verified against the current pages.
    @available(*, deprecated, message: "Superseded by .o3Mini at the same price")
    case o1Mini = "o1-mini"

    /// The models Arbiter suggests by default.
    ///
    /// Hand-written because a deprecated case cannot take part in the
    /// synthesised conformance; superseded IDs are deliberately absent.
    public static var allCases: [OpenAIModel] {
        [.gpt56Sol, .gpt56Terra, .gpt56Luna,
         .gpt5, .gpt5Mini, .gpt5Nano,
         .gpt41, .gpt41Mini,
         .gpt4o, .gpt4oMini,
         .o3, .o4Mini, .o3Mini, .o1, .gpt4Turbo]
    }

    /// Look up a model by its API ID.
    ///
    /// Resolves superseded IDs too, which `allCases` omits, so a stored
    /// conversation naming one still gets that model's real limits.
    static func named(_ id: String?) -> OpenAIModel? {
        guard let id else { return nil }
        return OpenAIModel(rawValue: id)
    }

    public var displayName: String {
        switch self {
        case .gpt56Sol: "GPT-5.6 Sol"
        case .gpt56Terra: "GPT-5.6 Terra"
        case .gpt56Luna: "GPT-5.6 Luna"
        case .gpt5: "GPT-5"
        case .gpt5Mini: "GPT-5 Mini"
        case .gpt5Nano: "GPT-5 Nano"
        case .gpt41: "GPT-4.1"
        case .gpt41Mini: "GPT-4.1 Mini"
        case .gpt4o: "GPT-4o"
        case .gpt4oMini: "GPT-4o Mini"
        case .o3: "o3"
        case .o4Mini: "o4 Mini"
        case .o3Mini: "o3 Mini"
        case .o1: "o1"
        case .gpt4Turbo: "GPT-4 Turbo"
        case .o1Mini: "o1 Mini"
        }
    }

    /// Maximum input context window in tokens.
    public var contextWindow: Int {
        switch self {
        case .gpt56Sol, .gpt56Terra, .gpt56Luna: 1_050_000
        case .gpt5, .gpt5Mini, .gpt5Nano: 400_000
        case .gpt41, .gpt41Mini: 1_047_576
        case .gpt4o, .gpt4oMini, .gpt4Turbo, .o1Mini: 128_000
        case .o3, .o4Mini, .o3Mini, .o1: 200_000
        }
    }

    /// Maximum tokens the model will generate in one response.
    public var maxOutputTokens: Int {
        switch self {
        case .gpt56Sol, .gpt56Terra, .gpt56Luna: 128_000
        case .gpt5, .gpt5Mini, .gpt5Nano: 128_000
        case .gpt41, .gpt41Mini: 32_768
        case .gpt4o, .gpt4oMini: 16_384
        case .o3, .o4Mini, .o3Mini, .o1: 100_000
        case .o1Mini: 65_536
        case .gpt4Turbo: 4_096
        }
    }

    public var costPerMillionInput: Double {
        switch self {
        case .gpt56Sol: 4.00
        case .gpt56Terra: 2.00
        case .gpt56Luna: 0.20
        case .gpt5: 1.25
        case .gpt5Mini: 0.25
        case .gpt5Nano: 0.05
        case .gpt41: 2.00
        case .gpt41Mini: 0.40
        case .gpt4o: 2.50
        case .gpt4oMini: 0.15
        case .o3: 2.00
        case .o4Mini: 1.10
        case .o3Mini, .o1Mini: 1.10
        case .o1: 15.00
        case .gpt4Turbo: 10.00
        }
    }

    public var costPerMillionOutput: Double {
        switch self {
        case .gpt56Sol: 20.00
        case .gpt56Terra: 12.00
        case .gpt56Luna: 1.20
        case .gpt5: 10.00
        case .gpt5Mini: 2.00
        case .gpt5Nano: 0.40
        case .gpt41: 8.00
        case .gpt41Mini: 1.60
        case .gpt4o: 10.00
        case .gpt4oMini: 0.60
        case .o3: 8.00
        case .o4Mini: 4.40
        case .o3Mini, .o1Mini: 4.40
        case .o1: 60.00
        case .gpt4Turbo: 30.00
        }
    }

    /// Price per million tokens read back from OpenAI's prompt cache.
    ///
    /// Published per model rather than as a fixed fraction of the input rate:
    /// the GPT‑5 and 5.6 families discount cached input to a tenth, while
    /// GPT‑4o only halves it. `nil` where no cached rate is published.
    public var costPerMillionCachedInput: Double? {
        switch self {
        case .gpt56Sol: 0.40
        case .gpt56Terra: 0.20
        case .gpt56Luna: 0.02
        case .gpt5: 0.125
        case .gpt5Mini: 0.025
        case .gpt5Nano: 0.005
        case .gpt41: 0.50
        case .gpt41Mini: 0.10
        case .gpt4o: 1.25
        case .gpt4oMini: 0.075
        case .o3: 0.50
        case .o4Mini: 0.275
        case .o3Mini, .o1Mini: 0.55
        case .o1: 7.50
        case .gpt4Turbo: nil
        }
    }

    /// Whether the model produces reasoning tokens before its answer.
    ///
    /// Reasoning models take `max_completion_tokens` rather than the
    /// deprecated `max_tokens`, and accept `reasoning_effort`.
    public var isReasoningModel: Bool {
        switch self {
        case .gpt56Sol, .gpt56Terra, .gpt56Luna,
             .gpt5, .gpt5Mini, .gpt5Nano,
             .o3, .o4Mini, .o3Mini, .o1, .o1Mini:
            true
        case .gpt41, .gpt41Mini, .gpt4o, .gpt4oMini, .gpt4Turbo:
            false
        }
    }

    /// The `reasoning_effort` values this model documents support for, or
    /// `nil` where the docs do not publish a list.
    ///
    /// `nil` means "send whatever the caller asked for": rejecting a value the
    /// docs never ruled out would block a model from being used correctly.
    public var supportedReasoningEfforts: Set<OpenAIReasoningEffort>? {
        switch self {
        case .gpt56Sol, .gpt56Terra, .gpt56Luna:
            [.off, .low, .medium, .high, .xhigh, .max]
        case .gpt5:
            [.minimal, .low, .medium, .high]
        default:
            nil
        }
    }

    /// Every model in the catalogue supports streaming, including the
    /// reasoning models, which did not when Arbiter first shipped.
    public var supportsStreaming: Bool { true }

    /// Whether the model reasons, judged from a raw ID rather than the enum.
    ///
    /// A caller may name a model this catalogue has never heard of — a preview
    /// ID, a dated snapshot such as `gpt-5-2025-08-07`, or a proxy's alias — and
    /// sending `max_tokens` or `temperature` to a reasoning model is an
    /// outright 400. Falls back to matching the family prefixes.
    ///
    /// `gpt-4o` deliberately does not match: the check is anchored at the start
    /// of the ID, so the `o` in `4o` is never read as the o-series.
    static func isReasoningModel(id: String) -> Bool {
        if let known = named(id) { return known.isReasoningModel }

        // The GPT-5 chat snapshots are the non-reasoning members of a family
        // whose prefix otherwise implies reasoning.
        if id.contains("-chat") { return false }

        let reasoningFamilies = ["gpt-5", "o1", "o3", "o4"]
        return reasoningFamilies.contains { family in
            guard id.hasPrefix(family) else { return false }
            // Guard against a future `gpt-50` or `o10` reading as this family:
            // the character after the family must end it or start a suffix.
            let next = id.dropFirst(family.count).first
            return next == nil || next == "-" || next == "." || next == "_"
        }
    }
}
