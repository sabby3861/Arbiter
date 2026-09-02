// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "AppleFoundationOptions")

/// Per-call generation settings, mirroring `GenerationOptions`.
struct FMGenerationSettings: Sendable, Equatable {
    var sampling: AppleFMSampling?
    var temperature: Double?
    var maximumResponseTokens: Int?
    /// Constrains decoding to a shape, from `ResponseFormat.structured(schema:)`.
    ///
    /// Carried per call rather than baked into the session, because it is: Apple takes the
    /// schema on `respond(to:schema:)`, so one session can answer a plain turn and a
    /// structured turn in the same conversation.
    var schema: FMSchemaTree?
    /// Whether the schema is also described in the prompt. Ignored without a schema.
    var includeSchemaInPrompt: Bool
    /// Whether to measure token counts for this call. Costs several `tokenCount(for:)`
    /// round trips over the transcript, so it is the caller's choice.
    var reportTokenUsage: Bool

    /// Derives settings from the portable request fields plus provider options.
    ///
    /// `AIRequest.topP` has no direct counterpart; Apple's nucleus sampling is the closest
    /// equivalent, so it is mapped rather than dropped — but an explicit `options.sampling`
    /// always wins, matching how the cloud providers treat provider options as the override.
    /// - Parameter schema: the converted response schema, if the request asked for one.
    ///   Passed in rather than derived here so this initialiser stays non-throwing —
    ///   conversion has its own failure modes, which belong to the caller that can report
    ///   them against the request.
    init(request: AIRequest, options: AppleFMOptions, schema: FMSchemaTree? = nil) {
        if let sampling = options.sampling {
            self.sampling = sampling
        } else if let topP = request.topP, (0...1).contains(topP) {
            self.sampling = .randomThreshold(probability: topP)
        } else {
            // `AIRequest.topP` is unvalidated, and Apple documents the probability threshold
            // as 0...1. An out-of-range value falls back to the model's own default rather
            // than being pushed into an API that may reject or trap on it.
            if let topP = request.topP {
                logger.notice("Ignoring out-of-range topP \(topP) for Apple Foundation Models")
            }
            self.sampling = nil
        }
        self.temperature = request.temperature
        self.maximumResponseTokens = request.maxTokens
        self.schema = schema
        self.includeSchemaInPrompt = options.includeSchemaInPrompt
        self.reportTokenUsage = options.reportTokenUsage
    }

    init(
        sampling: AppleFMSampling? = nil,
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil,
        schema: FMSchemaTree? = nil,
        includeSchemaInPrompt: Bool = true,
        reportTokenUsage: Bool = false
    ) {
        self.sampling = sampling
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.schema = schema
        self.includeSchemaInPrompt = includeSchemaInPrompt
        self.reportTokenUsage = reportTokenUsage
    }
}

/// The outcome of one non-streaming generation.
struct FMRunResult: Sendable, Equatable {
    /// The answer. JSON, when the call carried a schema.
    let text: String
    /// Tools the model called while producing this answer, read back from the entries the
    /// session appended. Retrospective by nature: the calls have already been executed and
    /// answered in-session, so this is a record, not a request for the caller to act on.
    let toolCalls: [FMToolCall]
    /// Measured token counts, when the call asked for them and the OS can supply them.
    /// `nil` is honest: Apple reports no usage of its own, so there is nothing to fall
    /// back on but an estimate, and an estimate presented as a measurement is worse than
    /// none. See ``AppleFMOptions/reportTokenUsage``.
    let usage: TokenUsage?

    init(text: String, toolCalls: [FMToolCall] = [], usage: TokenUsage? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.usage = usage
    }
}

/// One cumulative snapshot from a streaming generation.
struct FMStreamSnapshot: Sendable, Equatable {
    /// The full content so far, not a delta — Apple's `ResponseStream` yields snapshots.
    let content: String
    /// Tool calls known at this point in the turn. Populated on the last snapshot, once the
    /// session's transcript shows what ran.
    let toolCalls: [FMToolCall]
    /// Measured token counts. Like the tool calls, only knowable once the turn is over, so
    /// this rides on the final snapshot and is `nil` on every earlier one.
    let usage: TokenUsage?

    init(content: String, toolCalls: [FMToolCall] = [], usage: TokenUsage? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.usage = usage
    }
}

/// The seam between `AppleFoundationProvider` and `LanguageModelSession`.
///
/// Speaking only Arbiter's vocabulary lets the provider's own logic — overflow recovery,
/// error mapping, session reuse, stream chunk shaping — be exercised off-device with a
/// test double, which is otherwise impossible: `LanguageModelSession` is `final`, has no
/// public initialiser worth faking, and refuses to run without Apple Intelligence.
///
/// Modelled on `AnthropicImageResolver`'s injected `load` closure.
protocol FMSessionRunning: Sendable {
    /// True while a generation is in flight. Apple throws `concurrentRequests` if a second
    /// call starts on the same session.
    var isResponding: Bool { get }

    /// Digest of the history this session currently holds, in `FMTranscript.fingerprint`
    /// form, so the cache can tell whether a session already holds exactly the history a
    /// new request implies.
    var transcriptFingerprint: String { get }

    func respond(to prompt: String, settings: FMGenerationSettings) async throws -> FMRunResult

    func stream(
        to prompt: String,
        settings: FMGenerationSettings
    ) -> AsyncThrowingStream<FMStreamSnapshot, Error>

    /// Builds a feedback attachment describing this session's most recent response.
    ///
    /// Neither `async` nor `throws`, matching `LanguageModelSession.logFeedbackAttachment`:
    /// it serialises state the session already holds and performs no generation. The
    /// attachment is the caller's to send — Arbiter never transmits it.
    func feedbackAttachment(
        sentiment: AppleFMFeedbackSentiment?,
        issues: [AppleFMFeedbackIssue]
    ) -> Data
}

/// Builds a session over the given history. Throwing covers adapter loading, which
/// touches the filesystem.
typealias FMSessionFactory = @Sendable (FMTranscript, AppleFMOptions) throws -> any FMSessionRunning
