// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Ollama-specific settings for one request.
///
/// Attach with `AIRequest.withProviderOptions(_:for:)` under `.ollama`; every
/// other provider ignores the entry.
///
/// ```swift
/// let request = AIRequest.chat("Explain quicksort")
///     .withProviderOptions(
///         OllamaOptions(keepAlive: .indefinite, think: .level(.high), numCtx: 8192),
///         for: .ollama
///     )
/// ```
///
/// Verified 3 September 2026 against
/// https://raw.githubusercontent.com/ollama/ollama/main/docs/api.md
/// and https://raw.githubusercontent.com/ollama/ollama/main/docs/faq.mdx.
public struct OllamaOptions: Sendable, Equatable {
    /// How long the server keeps the model resident after answering.
    ///
    /// `nil` leaves the server's own default (5 minutes, or `OLLAMA_KEEP_ALIVE`).
    public var keepAlive: OllamaKeepAlive?
    /// Whether a thinking model reasons before answering, and how hard.
    ///
    /// The reasoning comes back on `message.thinking` and lands in
    /// ``AIResponse/reasoning``, separate from the answer. Only thinking models
    /// honour it.
    public var think: OllamaThinking?
    /// Context window to load the model with, as `options.num_ctx`.
    ///
    /// Ollama loads models at a modest default context regardless of what the
    /// weights support, so a long conversation needs this raised explicitly.
    public var numCtx: Int?

    public init(
        keepAlive: OllamaKeepAlive? = nil,
        think: OllamaThinking? = nil,
        numCtx: Int? = nil
    ) {
        self.keepAlive = keepAlive
        self.think = think
        self.numCtx = numCtx
    }
}

/// How long a model stays loaded in memory after a request.
public enum OllamaKeepAlive: Sendable, Equatable {
    /// Stay resident for this many seconds.
    case seconds(Int)
    /// Stay resident until something else evicts the model, sent as `-1`.
    case indefinite
    /// Unload as soon as the response is generated, sent as `0`.
    case unloadImmediately

    /// The value as `keep_alive` takes it: a number of seconds, where any
    /// negative number means "keep loaded" and `0` means "unload now".
    var wireValue: Int {
        switch self {
        case .seconds(let seconds): seconds
        case .indefinite: -1
        case .unloadImmediately: 0
        }
    }
}

/// Whether — and how deeply — a thinking model reasons before answering.
public enum OllamaThinking: Sendable, Equatable {
    /// `think: true` / `think: false`, for models that take a plain switch.
    case enabled(Bool)
    /// `think: "low" | "medium" | "high" | "max"`, for models that take a level.
    case level(OllamaThinkingLevel)

    /// The value as `think` takes it: a boolean or a level string.
    var wireValue: Any {
        switch self {
        case .enabled(let flag): flag
        case .level(let level): level.rawValue
        }
    }
}

/// The reasoning levels Ollama documents for `think`.
public enum OllamaThinkingLevel: String, Sendable, Equatable, CaseIterable {
    case low
    case medium
    case high
    case max
}
