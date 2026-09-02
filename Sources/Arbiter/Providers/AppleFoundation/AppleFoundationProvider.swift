// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "AppleFoundationProvider")

#if canImport(FoundationModels)
import FoundationModels

/// On-device AI provider using Apple Foundation Models (Apple Intelligence).
///
/// Free, private, and fast for chat, summarization and classification. Requires Apple
/// Intelligence to be enabled on a supported device.
///
/// ```swift
/// let ai = Arbiter {
///     $0.system(AppleFoundationProvider())
/// }
/// ```
///
/// Conversation history reaches the model as a `Transcript`, so multi-turn chats keep
/// their context. Passing a `conversationID` in ``AppleFMOptions`` additionally reuses one
/// session across turns, so Apple's KV cache survives:
///
/// ```swift
/// let options = AppleFMOptions(conversationID: chat.id.uuidString)
/// let reply = try await ai.generate(prompt, options: .init(
///     providerOptions: [.appleFoundation: options]
/// ))
/// ```
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public struct AppleFoundationProvider: AIProvider, Sendable {
    public let id: ProviderID = .appleFoundation

    /// How many trailing transcript entries survive a summarising retry, before the split
    /// is moved back to the start of that turn.
    static let recentEntriesKeptOnOverflow = 4

    /// Response budget for the summarising call.
    static let summaryResponseTokens = 512

    private static let summaryInstruction = """
        You condense conversation history. Reply with a factual summary of the exchange \
        below in at most 150 words. Preserve names, numbers, decisions and open questions. \
        Do not add commentary.
        """

    private let store: AppleFMSessionStore
    private let sessionFactory: FMSessionFactory
    private let availabilityCheck: @Sendable () async -> Bool
    /// Captured once so error reporting and tests agree on one number.
    private let contextLimit: Int

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .summarization, .translation, .structuredOutput],
            // Roadmap F7-G replaces this literal with the model's reported `contextSize`,
            // alongside the rest of the token-accounting work.
            maxContextTokens: 4_096,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .fast,
            privacyLevel: .onDevice
        )
    }

    public var isAvailable: Bool {
        get async { await availabilityCheck() }
    }

    public init() {
        self.init(
            store: AppleFMSessionStore(),
            contextLimit: FMBridge.contextSize,
            availabilityCheck: { await AvailabilityChecker.isAppleFoundationAvailable() },
            sessionFactory: { transcript, options in
                try LiveFMSession(transcript: transcript, options: options)
            }
        )
    }

    /// Injection point for tests: doubles replace the real `LanguageModelSession` and the
    /// availability probe, so the provider's own logic — session reuse, overflow recovery,
    /// error mapping, stream shaping — runs on a machine without Apple Intelligence.
    /// Mirrors `AnthropicImageResolver`'s injected `load` closure.
    init(
        store: AppleFMSessionStore,
        contextLimit: Int,
        availabilityCheck: @escaping @Sendable () async -> Bool,
        sessionFactory: @escaping FMSessionFactory
    ) {
        self.store = store
        self.contextLimit = contextLimit
        self.availabilityCheck = availabilityCheck
        self.sessionFactory = sessionFactory
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        try Task.checkCancellation()
        try await ensureAvailable()

        let options = Self.options(from: request)
        let built = try FMTranscriptBuilder.build(from: request)
        let settings = FMGenerationSettings(request: request, options: options)

        let text = try await withOverflowRecovery(built: built, options: options) { transcript, prompt in
            let session = try await self.session(for: transcript, options: options)
            guard !session.isResponding else { throw ArbiterError.busy(.appleFoundation) }
            return try await session.respond(to: prompt, settings: settings).text
        }

        return AIResponse(
            id: "apple-fm-\(UUID().uuidString)",
            content: text,
            model: "apple-foundation",
            provider: .appleFoundation,
            finishReason: .complete
        )
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(for: request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
extension AppleFoundationProvider {
    /// The first `.prompt` at or after `notBefore`, so the retained window starts on a user
    /// turn. When no prompt follows that point the whole body is summarised rather than
    /// retaining a fragment that begins mid-turn.
    static func turnBoundary(in entries: [FMTranscriptEntry], notBefore: Int) -> Int {
        let start = max(0, notBefore)
        for index in start..<entries.count {
            if case .prompt = entries[index] { return index }
        }
        return entries.count
    }

    /// Caps what is handed to the summariser.
    ///
    /// The text being summarised is by definition most of a transcript that just overflowed,
    /// so passing it whole would usually overflow the summariser too and burn a generation
    /// for nothing. The tail is kept: it is the part the retained turns refer back to.
    static func boundedSummaryInput(_ text: String, contextLimit: Int) -> String {
        // Roughly four characters per token, leaving room for the instructions and reply.
        let budget = max(1_000, (contextLimit - summaryResponseTokens) * 4 * 3 / 4)
        guard text.count > budget else { return text }
        return "[earlier turns omitted]\n" + String(text.suffix(budget))
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private extension AppleFoundationProvider {
    static func options(from request: AIRequest) -> AppleFMOptions {
        request.providerOptions[.appleFoundation] as? AppleFMOptions ?? AppleFMOptions()
    }

    func ensureAvailable() async throws {
        guard await isAvailable else {
            let reason = await AvailabilityChecker.unavailableReason()
            throw ArbiterError.providerUnavailable(.appleFoundation, reason: reason)
        }
    }

    func session(for transcript: FMTranscript, options: AppleFMOptions) async throws -> any FMSessionRunning {
        let factory = sessionFactory
        return try await store.session(
            conversationID: options.conversationID,
            transcript: transcript,
            identity: options.sessionIdentity,
            make: { try factory(transcript, options) }
        )
    }

    /// Translates a session error into an `ArbiterError`. Cancellation and errors that are
    /// already `ArbiterError`s (the transcript builder's rejections) pass through unchanged.
    func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        guard let sessionError = error as? FMSessionError else { return error }
        return FMErrorMapper.arbiterError(for: sessionError.kind, contextLimit: contextLimit)
    }

    /// Runs `body`, and on a context overflow optionally summarises the older history and
    /// retries exactly once. A second overflow throws: retrying again would loop.
    func withOverflowRecovery(
        built: FMTranscriptBuilder.Built,
        options: AppleFMOptions,
        body: @Sendable (FMTranscript, String) async throws -> String
    ) async throws -> String {
        do {
            return try await body(built.transcript, built.prompt)
        } catch {
            let translated = mapped(error)
            guard options.contextOverflow == .summarizeAndRetry,
                  let arbiterError = translated as? ArbiterError,
                  case .contextWindowExceeded = arbiterError
            else {
                throw translated
            }

            logger.notice("Apple FM context overflow; summarising history and retrying once")
            if let conversationID = options.conversationID {
                // The cached session holds the transcript that just overflowed.
                await store.discard(conversationID: conversationID)
            }

            let condensed = try await condense(built.transcript, options: options)
            do {
                return try await body(condensed, built.prompt)
            } catch {
                throw mapped(error)
            }
        }
    }

    /// Replaces the older part of the transcript with a model-written summary, keeping the
    /// most recent turns verbatim.
    ///
    /// The split lands on a `.prompt` entry so the retained window is a whole turn: cutting
    /// mid-turn would leave tool outputs answering a call that is no longer in the
    /// transcript. Every entry either survives verbatim or is fed to the summariser — none
    /// is dropped on the floor.
    func condense(_ transcript: FMTranscript, options: AppleFMOptions) async throws -> FMTranscript {
        var body = transcript.entries
        var instructions: FMTranscriptEntry?
        if case .instructions = body.first {
            instructions = body.removeFirst()
        }

        guard body.count > Self.recentEntriesKeptOnOverflow else {
            // Nothing left to summarise — the latest turn alone does not fit.
            throw ArbiterError.contextWindowExceeded(.appleFoundation, limit: contextLimit)
        }

        let cut = Self.turnBoundary(in: body, notBefore: body.count - Self.recentEntriesKeptOnOverflow)
        let older = Array(body[..<cut])
        let recent = Array(body[cut...])

        let olderText = Self.plainText(of: older)
        guard !olderText.isEmpty else {
            throw ArbiterError.contextWindowExceeded(.appleFoundation, limit: contextLimit)
        }

        // A fresh, instruction-only session: summarising inside the overflowing session
        // would overflow again.
        let summariser = try sessionFactory(
            FMTranscript(entries: [.instructions(segments: [.text(Self.summaryInstruction)], toolNames: [])]),
            options
        )
        let summary: String
        do {
            summary = try await summariser.respond(
                to: Self.boundedSummaryInput(olderText, contextLimit: contextLimit),
                settings: FMGenerationSettings(maximumResponseTokens: Self.summaryResponseTokens)
            ).text
        } catch {
            throw mapped(error)
        }

        var entries: [FMTranscriptEntry] = []
        if let instructions { entries.append(instructions) }
        entries.append(.prompt(segments: [.text("Summary of our earlier conversation:\n\(summary)")]))
        entries.append(.response(segments: [.text("Understood.")]))
        entries.append(contentsOf: recent)
        return FMTranscript(entries: entries)
    }


    static func plainText(of entries: [FMTranscriptEntry]) -> String {
        var lines: [String] = []
        for entry in entries {
            switch entry {
            case .instructions:
                continue
            case .prompt(let segments):
                lines.append("User: \(text(of: segments))")
            case .response(let segments):
                lines.append("Assistant: \(text(of: segments))")
            case .toolCalls(let calls):
                lines.append("Assistant called: \(calls.map(\.toolName).joined(separator: ", "))")
            case .toolOutput(_, let toolName, let segments):
                lines.append("Tool \(toolName) returned: \(text(of: segments))")
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func text(of segments: [FMSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let value): value
            case .structured(_, let json): json
            }
        }.joined(separator: "\n")
    }

    /// The new text between two cumulative snapshots.
    ///
    /// Apple's `ResponseStream` yields snapshots rather than deltas, and a snapshot may in
    /// principle revise earlier text. When it does, the whole snapshot is reported as the
    /// delta; `accumulatedContent` on every chunk always carries the authoritative text.
    static func delta(from previous: String, to current: String) -> String {
        guard current.hasPrefix(previous) else { return current }
        return String(current.dropFirst(previous.count))
    }

    func performStream(
        for request: AIRequest,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        try await ensureAvailable()

        let options = Self.options(from: request)
        let built = try FMTranscriptBuilder.build(from: request)
        let settings = FMGenerationSettings(request: request, options: options)

        // Accumulation lives here rather than in the attempt, so a failure part-way through
        // a stream is still visible to the retry guard below: text already delivered to the
        // consumer must never be re-delivered by a second attempt.
        var accumulated = ""
        var transcript = built.transcript
        var didRetry = false

        while true {
            do {
                let session = try await session(for: transcript, options: options)
                guard !session.isResponding else { throw ArbiterError.busy(.appleFoundation) }

                for try await snapshot in session.stream(to: built.prompt, settings: settings) {
                    try Task.checkCancellation()
                    let delta = Self.delta(from: accumulated, to: snapshot.content)
                    accumulated = snapshot.content
                    continuation.yield(AIStreamChunk(
                        delta: delta,
                        accumulatedContent: accumulated,
                        isComplete: false,
                        provider: .appleFoundation
                    ))
                }
                break
            } catch {
                let translated = mapped(error)
                guard !didRetry,
                      accumulated.isEmpty,
                      options.contextOverflow == .summarizeAndRetry,
                      let arbiterError = translated as? ArbiterError,
                      case .contextWindowExceeded = arbiterError
                else {
                    throw translated
                }

                logger.notice("Apple FM context overflow while streaming; summarising and retrying once")
                didRetry = true
                if let conversationID = options.conversationID {
                    // The cached session holds the transcript that just overflowed.
                    await store.discard(conversationID: conversationID)
                }
                transcript = try await condense(transcript, options: options)
            }
        }

        continuation.yield(AIStreamChunk(
            delta: "",
            accumulatedContent: accumulated,
            isComplete: true,
            finishReason: .complete,
            provider: .appleFoundation
        ))
    }
}
#else

/// Stub Apple Foundation Models provider when the FoundationModels framework is absent.
///
/// Reports as unavailable so the router skips it gracefully.
/// Requires iOS 26+ / macOS 26+ with Apple Intelligence enabled.
public struct AppleFoundationProvider: AIProvider, Sendable {
    public let id: ProviderID = .appleFoundation

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .summarization, .translation, .structuredOutput],
            maxContextTokens: 4_096,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .fast,
            privacyLevel: .onDevice
        )
    }

    public var isAvailable: Bool {
        get async { false }
    }

    public init() {
        logger.debug("Apple Foundation Models stub initialized — FoundationModels framework not linked")
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        throw ArbiterError.providerUnavailable(
            .appleFoundation,
            reason: "Apple Foundation Models requires iOS 26+ / macOS 26+ with Apple Intelligence enabled."
        )
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ArbiterError.providerUnavailable(
                .appleFoundation,
                reason: "Apple Foundation Models requires iOS 26+ / macOS 26+ with Apple Intelligence enabled."
            ))
        }
    }
}

#endif
