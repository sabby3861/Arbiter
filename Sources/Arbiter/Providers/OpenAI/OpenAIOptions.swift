// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// OpenAI-specific request settings.
///
/// Attach with `AIRequest.withProviderOptions(_:for:)`; every other provider
/// ignores it.
///
/// ```swift
/// let request = AIRequest.chat("Plan the migration.")
///     .withModel("gpt-5.6-sol")
///     .withProviderOptions(OpenAIOptions(reasoningEffort: .high), for: .openAI)
/// ```
public struct OpenAIOptions: Sendable, Equatable {
    /// Which HTTP API to send this request over.
    ///
    /// Defaults to Chat Completions, which is the endpoint OpenAI-compatible
    /// hosts (Groq, Together, Perplexity, Azure) implement.
    public var api: OpenAIAPI
    /// How much the model should reason before answering.
    ///
    /// Only reasoning models accept this — see `OpenAIModel.isReasoningModel`.
    /// Sending it to a model that does not is rejected as
    /// `ArbiterError.invalidRequest` before the request leaves the process.
    ///
    /// Unlike `temperature`, which is silently dropped for such models, this is
    /// an explicit request for a behaviour the model cannot provide: quietly
    /// ignoring it would return an answer that is not the one asked for.
    public var reasoningEffort: OpenAIReasoningEffort?
    /// The `name` sent with a strict JSON schema.
    ///
    /// OpenAI requires one and constrains it to letters, digits, underscores
    /// and dashes, up to 64 characters.
    public var structuredOutputName: String
    /// Whether structured output requests ask for schema-constrained decoding.
    ///
    /// On by default. Turn it off for OpenAI-compatible hosts that accept a
    /// `json_schema` response format but not strict mode, or for a schema that
    /// uses keywords strict mode rejects.
    public var strictStructuredOutputs: Bool
    /// Whether the Responses API stores the response for later retrieval.
    ///
    /// `nil` leaves the account default. Ignored on Chat Completions.
    public var store: Bool?

    /// The default `name` for a strict JSON schema.
    public static let defaultStructuredOutputName = "arbiter_output"

    public init(
        api: OpenAIAPI = .chatCompletions,
        reasoningEffort: OpenAIReasoningEffort? = nil,
        structuredOutputName: String = OpenAIOptions.defaultStructuredOutputName,
        strictStructuredOutputs: Bool = true,
        store: Bool? = nil
    ) {
        self.api = api
        self.reasoningEffort = reasoningEffort
        self.structuredOutputName = structuredOutputName
        self.strictStructuredOutputs = strictStructuredOutputs
        self.store = store
    }

    /// Ask a reasoning model for a given amount of thinking.
    public static func reasoning(_ effort: OpenAIReasoningEffort) -> OpenAIOptions {
        OpenAIOptions(reasoningEffort: effort)
    }

    /// Send the request over the Responses API instead of Chat Completions.
    public static func responsesAPI(
        reasoningEffort: OpenAIReasoningEffort? = nil
    ) -> OpenAIOptions {
        OpenAIOptions(api: .responses, reasoningEffort: reasoningEffort)
    }
}

/// Which OpenAI HTTP API carries the request.
public enum OpenAIAPI: Sendable, Equatable {
    /// `POST /v1/chat/completions` — the default, and the shape every
    /// OpenAI-compatible host implements.
    case chatCompletions
    /// `POST /v1/responses` — OpenAI's own current API.
    ///
    /// Streaming over this transport is not implemented: `stream(_:)` falls
    /// back to a single chunk carrying the complete response.
    case responses
}

/// How much a reasoning model thinks before answering.
///
/// Models accept different subsets — the GPT‑5.6 family takes the full range
/// while `gpt-5` takes `minimal`/`low`/`medium`/`high` — so a value a model
/// does not publish support for is rejected before the request is sent. See
/// `OpenAIModel.supportedReasoningEfforts`.
public enum OpenAIReasoningEffort: String, Sendable, Equatable, CaseIterable {
    /// Sent as `"none"`. Named `off` because `.none` on an optional would be
    /// read as "no value" rather than this case.
    case off = "none"
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
}
