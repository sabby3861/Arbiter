// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Provider-specific settings for Apple Foundation Models.
///
/// Attach with `request.withProviderOptions(AppleFMOptions(...), for: .appleFoundation)`
/// or via `RequestOptions.providerOptions`, exactly like `AnthropicOptions` and
/// `OpenAIOptions`.
///
/// ```swift
/// let options = AppleFMOptions(sampling: .greedy, conversationID: chat.id.uuidString)
/// let reply = try await ai.generate(prompt, options: .init(
///     providerOptions: [.appleFoundation: options]
/// ))
/// ```
///
/// Deliberately free of `FoundationModels` symbols so it compiles on every platform and
/// can be stored in `AIRequest.providerOptions`, which requires `Sendable`.
public struct AppleFMOptions: Sendable {
    /// Token sampling strategy. When `nil`, `AIRequest.topP` is honoured as a
    /// probability threshold; when set, this wins.
    public var sampling: AppleFMSampling?

    /// Which system model to load. `.contentTagging` is a specialised tagging model.
    public var useCase: AppleFMUseCase

    /// Guardrail strictness. `.permissiveContentTransformations` is the supported way to
    /// run rewriting/transformation workloads without spurious guardrail violations.
    public var guardrails: AppleFMGuardrails

    /// A custom LoRA adapter to load, identified by name or file URL.
    ///
    /// Named indirectly on purpose: `SystemLanguageModel.Adapter` is not `Sendable`, so it
    /// cannot be stored in `AIRequest.providerOptions`. The real adapter is built inside
    /// the provider.
    public var adapter: AppleFMAdapterSource?

    /// Warm the model when a session is created, cutting first-token latency.
    public var prewarm: Bool

    /// Optional prompt prefix to prewarm with, when the opening text is already known.
    public var promptPrefixForPrewarm: String?

    /// Reuse one session — and Apple's KV cache — across the turns of a conversation.
    ///
    /// When `nil`, every call builds a fresh session from the request's history, which is
    /// correct but slower.
    public var conversationID: String?

    /// What to do when the transcript no longer fits the context window.
    public var contextOverflow: AppleFMContextOverflow

    public init(
        sampling: AppleFMSampling? = nil,
        useCase: AppleFMUseCase = .general,
        guardrails: AppleFMGuardrails = .default,
        adapter: AppleFMAdapterSource? = nil,
        prewarm: Bool = false,
        promptPrefixForPrewarm: String? = nil,
        conversationID: String? = nil,
        contextOverflow: AppleFMContextOverflow = .fail
    ) {
        self.sampling = sampling
        self.useCase = useCase
        self.guardrails = guardrails
        self.adapter = adapter
        self.prewarm = prewarm
        self.promptPrefixForPrewarm = promptPrefixForPrewarm
        self.conversationID = conversationID
        self.contextOverflow = contextOverflow
    }

    /// Identity of the *session* these options would create.
    ///
    /// `LanguageModelSession` fixes its model and tools at construction, so a cached
    /// session may only be reused when these fields are unchanged — otherwise a second
    /// turn would silently run against the previous configuration. Sampling, prewarming
    /// and the overflow strategy are excluded: they are per-call, not baked into the session.
    var sessionIdentity: String {
        var parts = ["useCase:\(useCase.rawValue)", "guardrails:\(guardrails.rawValue)"]
        switch adapter {
        case .none: parts.append("adapter:none")
        case .name(let name): parts.append("adapter:name:\(name)")
        case .fileURL(let url): parts.append("adapter:url:\(url.absoluteString)")
        }
        // F7b appends the sorted tool names here, for the same reason.
        return parts.joined(separator: "|")
    }
}

extension AppleFMOptions: CustomStringConvertible {
    /// Hand-written so `ResponseCache`'s `String(describing:)` key stays stable and
    /// meaningful. From F7b these options carry executor closures, whose synthesised
    /// description would otherwise vary between runs and poison the cache key.
    public var description: String {
        var parts = [sessionIdentity]
        parts.append("sampling:\(sampling.map(String.init(describing:)) ?? "default")")
        parts.append("prewarm:\(prewarm)")
        parts.append("overflow:\(contextOverflow.rawValue)")
        if let conversationID { parts.append("conversation:\(conversationID)") }
        return "AppleFMOptions(\(parts.joined(separator: ", ")))"
    }
}

/// Mirror of `GenerationOptions.SamplingMode`.
public enum AppleFMSampling: Sendable, Equatable {
    /// Always pick the most likely token. Deterministic for a given prompt.
    case greedy
    /// Sample from the `k` most likely tokens.
    case randomTop(k: Int, seed: UInt64? = nil)
    /// Nucleus sampling: sample from the smallest set of tokens above the threshold.
    case randomThreshold(probability: Double, seed: UInt64? = nil)
}

/// Mirror of `SystemLanguageModel.UseCase`.
public enum AppleFMUseCase: String, Sendable, Equatable {
    case general
    case contentTagging
}

/// Mirror of `SystemLanguageModel.Guardrails`.
public enum AppleFMGuardrails: String, Sendable, Equatable {
    case `default`
    case permissiveContentTransformations
}

/// How to locate a custom adapter, standing in for the non-`Sendable`
/// `SystemLanguageModel.Adapter`.
public enum AppleFMAdapterSource: Sendable, Equatable {
    case name(String)
    case fileURL(URL)
}

/// What to do when the transcript exceeds the model's context window.
public enum AppleFMContextOverflow: String, Sendable, Equatable {
    /// Throw `ArbiterError.contextWindowExceeded`. The default: silent lossy behaviour
    /// is worse than a clear error the caller can act on.
    case fail
    /// Summarise the older half of the transcript with the same model and retry once.
    case summarizeAndRetry
}
