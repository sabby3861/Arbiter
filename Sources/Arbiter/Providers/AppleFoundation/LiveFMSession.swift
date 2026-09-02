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
        session = LanguageModelSession(
            model: model,
            tools: [],  // Bound in F7b.
            transcript: try FMBridge.transcript(from: transcript)
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
            let response = try await session.respond(
                to: prompt,
                options: FMBridge.generationOptions(from: settings)
            )
            return FMRunResult(text: response.content)
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
                    let responseStream = session.streamResponse(
                        to: prompt,
                        options: FMBridge.generationOptions(from: settings)
                    )
                    for try await snapshot in responseStream {
                        try Task.checkCancellation()
                        continuation.yield(FMStreamSnapshot(content: snapshot.content))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.translated(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Cancellation passes through untouched; everything else becomes an `FMErrorKind`.
    private static func translated(_ error: any Error) -> any Error {
        guard let kind = FMBridge.errorKind(for: error) else { return error }
        return FMSessionError(kind: kind)
    }
}

#endif

/// Wraps an `FMErrorKind` so it can travel as an `Error` from a session to the provider,
/// which maps it to `ArbiterError` with the context limit attached.
struct FMSessionError: Error, Sendable, Equatable {
    let kind: FMErrorKind
}
