// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import CryptoKit
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

    /// Tools the on-device model may call, each with the closure that runs it.
    ///
    /// An executor is mandatory rather than optional: Apple invokes tools *inside*
    /// `respond()` and there is no API that hands a pending call back to the caller, so a
    /// bare ``ToolDefinition`` has nothing to execute. `AIRequest.tools` still declares
    /// which tools a request wants; every name it lists must appear here, or the request is
    /// rejected rather than run without the tool the caller expected.
    public var tools: [AppleFMToolBinding]

    /// Whether a structured-output schema is also described in the prompt.
    ///
    /// Decoding is constrained either way. Including the schema costs context but tends to
    /// improve field-level fidelity, which is why Apple defaults it on; turn it off for
    /// large schemas on a 4k window.
    public var includeSchemaInPrompt: Bool

    /// The locale to check against when ``enforceLocale`` is set. Defaults to `.current`.
    public var locale: Locale?

    /// Reject a request up front when the model does not support ``locale``.
    ///
    /// Off by default, and deliberately so: the check tests a *locale*, not the language
    /// the prompt is actually written in, so enabling it unconditionally would reject
    /// perfectly good English prompts from a device set to an unsupported region. The
    /// reactive path always works — the model raises `unsupportedLanguageOrLocale`, which
    /// maps to `ArbiterError.unsupportedLanguage` and lets the router fall back.
    public var enforceLocale: Bool

    public init(
        sampling: AppleFMSampling? = nil,
        useCase: AppleFMUseCase = .general,
        guardrails: AppleFMGuardrails = .default,
        adapter: AppleFMAdapterSource? = nil,
        prewarm: Bool = false,
        promptPrefixForPrewarm: String? = nil,
        conversationID: String? = nil,
        contextOverflow: AppleFMContextOverflow = .fail,
        tools: [AppleFMToolBinding] = [],
        includeSchemaInPrompt: Bool = true,
        locale: Locale? = nil,
        enforceLocale: Bool = false
    ) {
        self.sampling = sampling
        self.useCase = useCase
        self.guardrails = guardrails
        self.adapter = adapter
        self.prewarm = prewarm
        self.promptPrefixForPrewarm = promptPrefixForPrewarm
        self.conversationID = conversationID
        self.contextOverflow = contextOverflow
        self.tools = tools
        self.includeSchemaInPrompt = includeSchemaInPrompt
        self.locale = locale
        self.enforceLocale = enforceLocale
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
        // Tools are bound at `LanguageModelSession(tools:)` and cannot be changed after,
        // so a turn carrying a different tool set needs a different session. Sorted: the
        // order tools are listed in does not change what the session can do.
        //
        // The whole contract is folded in, not just the name: a second turn that keeps the
        // name but changes the description or the input schema is describing a different
        // tool to the model, and reusing the session would keep advertising the old one.
        parts.append("tools:\(tools.map { Self.digest(of: $0.definition) }.sorted().joined(separator: ","))")
        return parts.joined(separator: "|")
    }

    /// Stable across processes, unlike `String(describing:)` of a schema dictionary, whose
    /// key order varies per run — which would both defeat session reuse and poison
    /// `ResponseCache`'s key.
    private static func digest(of definition: ToolDefinition) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let schema = (try? encoder.encode(definition.inputSchema)).map { String(decoding: $0, as: UTF8.self) }
            ?? ""
        var hasher = SHA256()
        for field in [definition.name, definition.description, schema] {
            let bytes = Data(field.utf8)
            withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        // Prefixed with the name so a mismatch is readable in a log or a cache key.
        return "\(definition.name):\(hex.prefix(16))"
    }
}

extension AppleFMOptions: CustomStringConvertible {
    /// Hand-written so `ResponseCache`'s `String(describing:)` key stays stable and
    /// meaningful. A synthesised description would render a tool's `inputSchema` dictionary
    /// in per-process hash order, so the same request would key differently between runs and
    /// never hit the cache; the tool digests below are ordered and stable instead.
    public var description: String {
        var parts = [sessionIdentity]
        parts.append("sampling:\(sampling.map(String.init(describing:)) ?? "default")")
        parts.append("prewarm:\(prewarm)")
        parts.append("overflow:\(contextOverflow.rawValue)")
        parts.append("schemaInPrompt:\(includeSchemaInPrompt)")
        if enforceLocale { parts.append("locale:\((locale ?? .current).identifier)") }
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

/// A tool the on-device model may call, paired with the code that runs it.
///
/// Apple's `Tool.call(arguments:)` executes within the session's own generation loop: the
/// model calls the tool, reads its output and keeps generating, all inside one `respond()`.
/// Nothing is ever handed back to Arbiter mid-turn, so a definition alone is not enough —
/// hence the executor. `AppleFoundationProvider` therefore never reports
/// `FinishReason.toolCall`; a completed response's ``AIResponse/toolCalls`` records what
/// the model called on the way to its answer.
///
/// ```swift
/// let weather = AppleFMToolBinding(
///     definition: ToolDefinition(
///         name: "get_weather",
///         description: "Current conditions for a city",
///         inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]]
///     ),
///     execute: { arguments in
///         guard case .object(let fields) = arguments, case .string(let city)? = fields["city"]
///         else { return "Unknown city" }
///         return try await weatherService.summary(for: city)
///     }
/// )
/// ```
public struct AppleFMToolBinding: Sendable {
    public let definition: ToolDefinition
    /// Receives the model's arguments, decoded from the constrained generation, and returns
    /// the text the model reads back. Throwing surfaces as
    /// `ArbiterError.invalidRequest` naming the tool.
    ///
    /// - Important: a closure has no identity to compare, so it cannot take part in session
    ///   reuse. Within one ``AppleFMOptions/conversationID``, the executors registered on
    ///   the first turn stay registered: a later turn that swaps the closure while leaving
    ///   the tool's name, description and schema untouched reuses the session it already
    ///   has, and the earlier closure keeps running. Capture per-request state in the
    ///   arguments or use a fresh conversation ID.
    public let execute: @Sendable (JSONValue) async throws -> String

    public init(
        definition: ToolDefinition,
        execute: @escaping @Sendable (JSONValue) async throws -> String
    ) {
        self.definition = definition
        self.execute = execute
    }
}

/// What to do when the transcript exceeds the model's context window.
public enum AppleFMContextOverflow: String, Sendable, Equatable {
    /// Throw `ArbiterError.contextWindowExceeded`. The default: silent lossy behaviour
    /// is worse than a clear error the caller can act on.
    case fail
    /// Summarise the older half of the transcript with the same model and retry once.
    case summarizeAndRetry
}
