// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import Arbiter

/// Covers the one piece of F7a that names FoundationModels types.
///
/// Guarded on the SDK and OS but not on Apple Intelligence: `Transcript` and
/// `GenerationError` are plain values with public initialisers, so none of this needs a
/// model to be installed or enabled.
@Suite("FMBridge")
struct FMBridgeTests {

    // MARK: - Error classification

    /// `FMErrorMapperTests` starts from an `FMErrorKind`; this is the step before it, where
    /// a mis-assigned case would otherwise go unnoticed.
    @Test func everyGenerationErrorCaseIsClassified() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "why")

        let expected: [(LanguageModelSession.GenerationError, FMErrorKind)] = [
            (.exceededContextWindowSize(context), .contextWindowExceeded("why")),
            (.assetsUnavailable(context), .assetsUnavailable("why")),
            (.guardrailViolation(context), .guardrailViolation("why")),
            (.unsupportedGuide(context), .unsupportedGuide("why")),
            (.unsupportedLanguageOrLocale(context), .unsupportedLanguage("why")),
            (.decodingFailure(context), .decodingFailure("why")),
            (.rateLimited(context), .rateLimited("why")),
            (.concurrentRequests(context), .concurrentRequests("why")),
            (
                .refusal(
                    LanguageModelSession.GenerationError.Refusal(transcriptEntries: []),
                    context
                ),
                .refusal("why")
            ),
        ]

        for (error, kind) in expected {
            #expect(FMBridge.errorKind(for: error) == kind)
        }
    }

    /// Cancellation must reach the caller as `CancellationError`, not as a provider failure.
    @Test func cancellationIsNotClassified() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        #expect(FMBridge.errorKind(for: CancellationError()) == nil)
    }

    @Test func unrecognisedErrorsBecomeUnknown() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        struct Surprise: Error {}
        guard case .unknown = FMBridge.errorKind(for: Surprise()) else {
            Issue.record("Expected unknown")
            return
        }
    }

    // MARK: - Transcript round trip

    /// Session reuse compares a live session's transcript against a freshly built one, so
    /// the two directions must agree on a fingerprint. If they ever stop agreeing, reuse
    /// silently never happens.
    @Test func transcriptRoundTripPreservesTheFingerprint() throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let original = FMTranscript(entries: [
            .instructions(segments: [.text("Be terse.")], toolNames: []),
            .prompt(segments: [.text("Capital of France?")]),
            .response(segments: [.text("Paris.")]),
        ])

        let roundTripped = FMBridge.transcript(from: try FMBridge.transcript(from: original))

        #expect(roundTripped == original)
        #expect(roundTripped.fingerprint == original.fingerprint)
    }

    /// Tool arguments cross the boundary as JSON through `GeneratedContent`, which is free
    /// to reformat them — so the reverse direction has to canonicalise, or every
    /// conversation containing a tool call would lose session reuse permanently.
    @Test func transcriptRoundTripPreservesTheFingerprintWithToolTurns() throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let original = FMTranscript(entries: [
            .prompt(segments: [.text("Weather and time in Tokyo?")]),
            .toolCalls([
                FMToolCall(
                    id: "c1",
                    toolName: "get_weather",
                    argumentsJSON: #"{"city":"Tokyo","units":"c"}"#
                ),
            ]),
            .toolOutput(id: "c1", toolName: "get_weather", segments: [.text("18C")]),
            .response(segments: [.text("18C in Tokyo.")]),
        ])

        let roundTripped = FMBridge.transcript(from: try FMBridge.transcript(from: original))

        #expect(roundTripped.fingerprint == original.fingerprint)
    }

    @Test func malformedToolArgumentsAreRejectedNotCrashed() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let transcript = FMTranscript(entries: [
            .toolCalls([FMToolCall(id: "c1", toolName: "t", argumentsJSON: "not json")]),
        ])

        #expect(throws: ArbiterError.self) {
            _ = try FMBridge.transcript(from: transcript)
        }
    }

    // MARK: - Generation options

    @Test func generationOptionsCarryEveryField() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let options = FMBridge.generationOptions(from: FMGenerationSettings(
            sampling: .greedy, temperature: 0.4, maximumResponseTokens: 128
        ))
        #expect(options.temperature == 0.4)
        #expect(options.maximumResponseTokens == 128)
        #expect(options.sampling == .greedy)
    }

    @Test func samplingModesMapAcross() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let top = FMBridge.generationOptions(from: FMGenerationSettings(sampling: .randomTop(k: 5, seed: 7)))
        #expect(top.sampling == .random(top: 5, seed: 7))

        let threshold = FMBridge.generationOptions(
            from: FMGenerationSettings(sampling: .randomThreshold(probability: 0.9, seed: 7))
        )
        #expect(threshold.sampling == .random(probabilityThreshold: 0.9, seed: 7))

        // No sampling requested means Apple's default, not an imposed one.
        #expect(FMBridge.generationOptions(from: FMGenerationSettings()).sampling == nil)
    }

    @Test func contextSizeIsReadFromTheModelNotHardcoded() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        // Compared against the framework rather than a literal, so this keeps holding if
        // Apple ever ships a different context size.
        #expect(FMBridge.contextSize == SystemLanguageModel.default.contextSize)
        #expect(FMBridge.contextSize > 0)
    }
}

#endif
