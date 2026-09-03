// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "LiveFMSession")

#if canImport(FoundationModels)
import FoundationModels

/// `FMSessionRunning` backed by a real `LanguageModelSession`.
///
/// Errors are classified here and rethrown as `FMErrorKind` so that everything above this
/// file — including the provider's overflow recovery — deals in Arbiter's vocabulary and
/// stays testable with a double.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
final class LiveFMSession: FMSessionRunning, @unchecked Sendable {
    // @unchecked: the stored properties are `LanguageModelSession`, which Apple declares
    // `@unchecked Sendable` itself and which serialises its own generation state, and
    // `SystemLanguageModel`, which is `Sendable`. This type adds no mutable state of its own.
    private let session: LanguageModelSession
    /// Kept because `tokenCount(for:)` is declared on the *model*, not the session, and
    /// token accounting needs the same model this session was built against — a session
    /// running a custom adapter does not tokenise like the stock one.
    private let model: SystemLanguageModel

    init(transcript: FMTranscript, options: AppleFMOptions) throws {
        let model = try FMBridge.model(for: options)
        self.model = model
        let tools = try FMBoundTool.tools(for: options)
        session = LanguageModelSession(
            model: model,
            tools: tools,
            // The same tools go into the transcript's instructions entry, so the model is
            // told about exactly the executors it was given.
            transcript: try FMBridge.transcript(from: transcript, tools: tools)
        )

        if options.prewarm {
            let prefix = options.promptPrefixForPrewarm.map { Prompt($0) }
            session.prewarm(promptPrefix: prefix)
        }
    }

    var isResponding: Bool { session.isResponding }

    var transcriptFingerprint: String {
        FMBridge.transcript(from: session.transcript).fingerprint
    }

    func respond(to prompt: String, settings: FMGenerationSettings) async throws -> FMRunResult {
        do {
            let options = FMBridge.generationOptions(from: settings)
            // Everything this turn adds — the prompt entry the framework appends, any tool
            // round trips, the answer — lives past this mark.
            let mark = session.transcript.count
            guard let tree = settings.schema else {
                let response = try await session.respond(to: prompt, options: options)
                return FMRunResult(
                    text: response.content,
                    toolCalls: Self.toolCalls(in: response.transcriptEntries),
                    usage: await usage(after: mark, settings: settings)
                )
            }
            // Constrained decoding: the model can only emit content matching the schema the
            // converter produced, so the JSON handed back is structurally guaranteed rather
            // than merely requested. What it is guaranteed against is that converted schema,
            // which is the caller's minus the keywords Apple cannot express — see
            // `FMSchemaConverter` for exactly what is dropped.
            let response = try await session.respond(
                to: prompt,
                schema: try FMBridge.generationSchema(from: tree),
                includeSchemaInPrompt: settings.includeSchemaInPrompt,
                options: options
            )
            return FMRunResult(
                text: response.content.jsonString,
                toolCalls: Self.toolCalls(in: response.transcriptEntries),
                usage: await usage(after: mark, settings: settings)
            )
        } catch {
            throw Self.translated(error)
        }
    }

    func stream(
        to prompt: String,
        settings: FMGenerationSettings
    ) -> AsyncThrowingStream<FMStreamSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Everything the session appends during this turn — including the tool
                    // calls it makes on the way — lives past this mark.
                    let mark = session.transcript.count
                    let options = FMBridge.generationOptions(from: settings)
                    var latest = ""

                    if let tree = settings.schema {
                        let schema = try FMBridge.generationSchema(from: tree)
                        for try await snapshot in session.streamResponse(
                            to: prompt,
                            schema: schema,
                            includeSchemaInPrompt: settings.includeSchemaInPrompt,
                            options: options
                        ) {
                            try Task.checkCancellation()
                            // A partial structure serialises as partial JSON, which is what a
                            // caller streaming a structured answer expects to accumulate.
                            latest = snapshot.content.jsonString
                            continuation.yield(FMStreamSnapshot(content: latest))
                        }
                    } else {
                        for try await snapshot in session.streamResponse(to: prompt, options: options) {
                            try Task.checkCancellation()
                            latest = snapshot.content
                            continuation.yield(FMStreamSnapshot(content: latest))
                        }
                    }

                    // Tool calls and token counts are only knowable once the turn is over:
                    // a snapshot carries content, never the calls behind it or what they
                    // cost. Yielded as one final snapshot with unchanged content, so it adds
                    // a record without adding text.
                    let calls = Self.toolCalls(in: session.transcript.dropFirst(mark))
                    let measured = await usage(after: mark, settings: settings)
                    if !calls.isEmpty || measured != nil {
                        continuation.yield(FMStreamSnapshot(
                            content: latest, toolCalls: calls, usage: measured
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.translated(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func feedbackAttachment(
        sentiment: AppleFMFeedbackSentiment?,
        issues: [AppleFMFeedbackIssue]
    ) -> Data {
        session.logFeedbackAttachment(
            sentiment: sentiment.map(FMBridge.sentiment(from:)),
            issues: issues.map(FMBridge.issue(from:))
        )
    }

    /// Measures what this turn actually cost, in tokens.
    ///
    /// Apple's `Response` carries no usage, so the count is taken after the fact from the
    /// transcript. The split follows who produced each entry: what the model *generated*
    /// this turn — its answer and any tool calls it decided to make — is output; everything
    /// that was *fed* to it — the history it started from, the prompt, and the outputs the
    /// tools returned — is input.
    ///
    /// A response schema is never counted separately, and measurement on macOS 26.5 says
    /// that is right in both configurations. With `includeSchemaInPrompt` on, the framework
    /// renders the schema into the prompt entry it appends, so the transcript count already
    /// carries it — a `"Tokyo."` prompt costs 10 tokens bare and 94 against a 92-token
    /// schema. With it off, the schema never becomes text at all: it constrains sampling
    /// rather than being sent, the prompt entry still costs 10, and there is no input to
    /// attribute. (The entry's own `responseFormat` comes back `nil` either way, so it is
    /// not a place a count could hide.) Adding `tokenCount(for: schema)` on top would
    /// overstate the first case and invent the second.
    ///
    /// The two counts are taken separately, and each carries a small constant framing
    /// overhead, so `inputTokens + outputTokens` is a few tokens above what one count over
    /// the whole turn would report. Near enough for budgeting; not a byte-exact identity.
    ///
    /// Never throws: usage is reporting, and losing a completed answer because counting it
    /// failed would be absurd. A failure yields `nil`, which the router already handles.
    private func usage(after mark: Int, settings: FMGenerationSettings) async -> TokenUsage? {
        guard settings.reportTokenUsage else { return nil }
        guard #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) else {
            // `tokenCount(for:)` does not exist below 26.4 and there is nothing honest to
            // put in its place.
            return nil
        }

        var fed: [Transcript.Entry] = Array(session.transcript.prefix(mark))
        var generated: [Transcript.Entry] = []
        for entry in session.transcript.dropFirst(mark) {
            switch entry {
            case .response, .toolCalls: generated.append(entry)
            default: fed.append(entry)
            }
        }

        do {
            return TokenUsage(
                inputTokens: try await count(of: fed),
                outputTokens: try await count(of: generated)
            )
        } catch {
            logger.notice("Apple FM token counting failed; reporting no usage for this turn")
            return nil
        }
    }

    @available(iOS 26.4, macOS 26.4, visionOS 26.4, *)
    private func count(of entries: [Transcript.Entry]) async throws -> Int {
        // Short-circuited rather than asked: `tokenCount(for:)` charges 1 token for an
        // empty collection, which is framing, not content.
        entries.isEmpty ? 0 : try await model.tokenCount(for: entries)
    }

    /// Reads the tool calls out of the entries a turn appended.
    private static func toolCalls(in entries: some Sequence<Transcript.Entry>) -> [FMToolCall] {
        entries.flatMap { entry -> [FMToolCall] in
            guard case .toolCalls(let calls) = entry else { return [] }
            return calls.map {
                FMToolCall(id: $0.id, toolName: $0.toolName, argumentsJSON: $0.arguments.jsonString)
            }
        }
    }

    /// Cancellation passes through untouched, as does an `ArbiterError` this file raised
    /// itself (a schema Apple would not build); everything else becomes an `FMErrorKind`.
    private static func translated(_ error: any Error) -> any Error {
        if error is ArbiterError { return error }
        guard let kind = FMBridge.errorKind(for: error) else { return error }
        return FMSessionError(kind: kind)
    }
}

/// Generation against a Swift `@Generable` type.
///
/// Kept off ``FMSessionRunning`` deliberately: that protocol speaks only Arbiter's
/// vocabulary so it can be doubled off-device, and `Generable` is a `FoundationModels`
/// symbol. A provider reaches this by downcasting the session it already holds, so the
/// session cache and error mapping still apply, and a test double simply does not conform.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
protocol FMGenerableRunning: FMSessionRunning {
    func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        settings: FMGenerationSettings
    ) async throws -> Content

    /// - Note: `Generable.PartiallyGenerated` is only required to be
    ///   `ConvertibleFromGeneratedContent`, which does not imply `Sendable`, so streaming a
    ///   partial value out through an `AsyncThrowingStream` needs the conformance spelled
    ///   out. The `@Generable` macro provides it; a hand-rolled conformance may not.
    func stream<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        settings: FMGenerationSettings
    ) -> AsyncThrowingStream<Content.PartiallyGenerated, any Error>
    where Content.PartiallyGenerated: Sendable
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
extension LiveFMSession: FMGenerableRunning {
    func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        settings: FMGenerationSettings
    ) async throws -> Content {
        do {
            return try await session.respond(
                to: prompt,
                generating: type,
                includeSchemaInPrompt: settings.includeSchemaInPrompt,
                options: FMBridge.generationOptions(from: settings)
            ).content
        } catch {
            throw Self.translated(error)
        }
    }

    func stream<Content: Generable>(
        to prompt: String,
        generating type: Content.Type,
        settings: FMGenerationSettings
    ) -> AsyncThrowingStream<Content.PartiallyGenerated, any Error>
    where Content.PartiallyGenerated: Sendable {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in session.streamResponse(
                        to: prompt,
                        generating: type,
                        includeSchemaInPrompt: settings.includeSchemaInPrompt,
                        options: FMBridge.generationOptions(from: settings)
                    ) {
                        try Task.checkCancellation()
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.translated(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

#endif

/// Wraps an `FMErrorKind` so it can travel as an `Error` from a session to the provider,
/// which maps it to `ArbiterError` with the context limit attached.
struct FMSessionError: Error, Sendable, Equatable {
    let kind: FMErrorKind
}
