// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// `FMSessionRunning` backed by a real `LanguageModelSession`.
///
/// Errors are classified here and rethrown as `FMErrorKind` so that everything above this
/// file — including the provider's overflow recovery — deals in Arbiter's vocabulary and
/// stays testable with a double.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
final class LiveFMSession: FMSessionRunning, @unchecked Sendable {
    // @unchecked: the only stored property is `LanguageModelSession`, which Apple declares
    // `@unchecked Sendable` itself and which serialises its own generation state. This type
    // adds no mutable state of its own.
    private let session: LanguageModelSession

    init(transcript: FMTranscript, options: AppleFMOptions) throws {
        let model = try FMBridge.model(for: options)
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
            guard let tree = settings.schema else {
                let response = try await session.respond(to: prompt, options: options)
                return FMRunResult(
                    text: response.content,
                    toolCalls: Self.toolCalls(in: response.transcriptEntries)
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
                toolCalls: Self.toolCalls(in: response.transcriptEntries)
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

                    // Tool calls are only knowable once the turn is over: a snapshot carries
                    // content, never the calls behind it. Yielded as one final snapshot with
                    // unchanged content, so it adds a record without adding text.
                    let calls = Self.toolCalls(in: session.transcript.dropFirst(mark))
                    if !calls.isEmpty {
                        continuation.yield(FMStreamSnapshot(content: latest, toolCalls: calls))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.translated(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
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
