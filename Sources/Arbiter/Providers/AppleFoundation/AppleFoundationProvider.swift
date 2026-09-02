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
    private let localeSupport: @Sendable (Locale, AppleFMOptions) -> Bool
    /// Captured once so error reporting and tests agree on one number.
    private let contextLimit: Int

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .summarization, .translation, .structuredOutput],
            // The model's own reported window, read once at init, rather than a literal that
            // goes stale the first time Apple ships a bigger one.
            maxContextTokens: contextLimit,
            supportsStreaming: true,
            // False despite tools working, because this flag is a *routing* signal and the
            // router cannot see what makes them work. Executors arrive in
            // ``AppleFMOptions/tools``, which lives in `providerOptions` — invisible to
            // `CapabilityMatcher` — so a `true` here steers every tool request on-device,
            // where an unbound tool throws `invalidRequest` and stops the fallback chain
            // instead of falling through to a provider that can serve it. Tool calling is
            // fully available today through explicit routing with bindings supplied; the
            // flag flips when the runtime's tool-execution loop can bind them itself.
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

    /// Whether the model was trained on this locale's language.
    ///
    /// Reports the stock model: a per-request answer would need that request's
    /// ``AppleFMOptions``, and an adapter can shift what is supported. Enforcement for a
    /// specific configuration is `AppleFMOptions.enforceLocale`.
    public func supportsLocale(_ locale: Locale = .current) -> Bool {
        localeSupport(locale, AppleFMOptions())
    }

    /// The languages the on-device model supports.
    public var supportedLanguages: Set<Locale.Language> {
        FoundationModelsAvailabilityBridge.supportedLanguages
    }

    public init() {
        self.init(
            store: AppleFMSessionStore(),
            contextLimit: FMBridge.contextSize,
            availabilityCheck: { await AvailabilityChecker.isAppleFoundationAvailable() },
            localeSupport: { locale, options in
                FoundationModelsAvailabilityBridge.supportsLocale(locale, options: options)
            },
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
        localeSupport: @escaping @Sendable (Locale, AppleFMOptions) -> Bool = { _, _ in true },
        sessionFactory: @escaping FMSessionFactory
    ) {
        self.store = store
        self.contextLimit = contextLimit
        self.availabilityCheck = availabilityCheck
        self.localeSupport = localeSupport
        self.sessionFactory = sessionFactory
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        try Task.checkCancellation()
        try await ensureAvailable()

        let options = try Self.resolvedOptions(for: request)
        try checkLocale(options)
        let built = try FMTranscriptBuilder.build(from: request, toolNames: Self.toolNames(of: options))
        let settings = FMGenerationSettings(
            request: request, options: options, schema: try Self.schemaTree(for: request)
        )

        let result = try await withOverflowRecovery(built: built, options: options) { transcript, prompt in
            let session = try await self.session(for: transcript, options: options)
            guard !session.isResponding else { throw ArbiterError.busy(.appleFoundation) }
            return try await session.respond(to: prompt, settings: settings)
        }

        return AIResponse(
            id: "apple-fm-\(UUID().uuidString)",
            content: result.text,
            model: "apple-foundation",
            provider: .appleFoundation,
            // A record of what ran, not a request to run anything: the session already
            // called these tools and read their output, which is why the turn is complete.
            toolCalls: result.toolCalls.map(Self.toolCall(from:)),
            // Measured, or absent. Apple publishes no usage on its responses, so this is
            // counted from the transcript when the OS can and left `nil` when it cannot —
            // never estimated. See ``AppleFMOptions/reportTokenUsage``.
            usage: result.usage,
            finishReason: .complete
        )
    }

    /// Generates a value of a Swift `@Generable` type through Apple's native decoding.
    ///
    /// Constrains generation to the type's own compile-time schema, which is stricter than
    /// routing a JSON Schema string through ``ResponseFormat/structured(schema:)`` and needs
    /// no decoding step of Arbiter's own.
    ///
    /// Exists only when the `FoundationModels` framework is linked — `Generable` is its
    /// type, and no stand-in would be honest — so this is the one part of the provider's
    /// surface that varies by build configuration.
    ///
    /// - Throws: `ArbiterError.providerUnavailable` when the provider is running against an
    ///   injected test session, which has no on-device model to generate against.
    public func generate<Content: Generable>(
        _ request: AIRequest,
        as type: Content.Type
    ) async throws -> Content {
        try Task.checkCancellation()
        try await ensureAvailable()

        let options = try Self.resolvedOptions(for: request)
        try checkLocale(options)
        let built = try FMTranscriptBuilder.build(from: request, toolNames: Self.toolNames(of: options))
        let settings = FMGenerationSettings(request: request, options: options)

        return try await withOverflowRecovery(built: built, options: options) { transcript, prompt in
            let session = try await self.generableSession(for: transcript, options: options)
            guard !session.isResponding else { throw ArbiterError.busy(.appleFoundation) }
            return try await session.respond(to: prompt, generating: type, settings: settings)
        }
    }

    /// Streams partially generated values of a `@Generable` type as the model fills them in.
    ///
    /// - Note: `Content.PartiallyGenerated` must be `Sendable` to cross the stream. The
    ///   `@Generable` macro's generated type is; the protocol itself does not require it,
    ///   so the constraint is spelled out rather than assumed.
    public func streamGenerate<Content: Generable>(
        _ request: AIRequest,
        as type: Content.Type
    ) -> AsyncThrowingStream<Content.PartiallyGenerated, any Error>
    where Content.PartiallyGenerated: Sendable {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    try await ensureAvailable()

                    let options = try Self.resolvedOptions(for: request)
                    try checkLocale(options)
                    let built = try FMTranscriptBuilder.build(
                        from: request, toolNames: Self.toolNames(of: options)
                    )
                    let settings = FMGenerationSettings(request: request, options: options)
                    let session = try await generableSession(
                        for: await running(built.transcript, options: options), options: options
                    )
                    guard !session.isResponding else { throw ArbiterError.busy(.appleFoundation) }

                    for try await partial in session.stream(
                        to: built.prompt, generating: type, settings: settings
                    ) {
                        try Task.checkCancellation()
                        continuation.yield(partial)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapped(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Builds a feedback attachment describing a conversation's cached session.
    ///
    /// `LanguageModelSession.logFeedbackAttachment` serialises the session, so this needs
    /// that exact session — which means the turn must have run under an
    /// ``AppleFMOptions/conversationID`` and still be cached.
    ///
    /// The returned `Data` is a serialised attachment for *you* to file, typically alongside
    /// a Feedback Assistant report. Arbiter neither sends nor stores it.
    ///
    /// - Important: what is cached is a session, not a response. Call this while the turn
    ///   you are reporting on is still the session's most recent, and be aware that the
    ///   framework will happily describe a session that has answered nothing (a turn that
    ///   threw leaves its session cached) and that a later turn changing the tool set, use
    ///   case, guardrails or adapter replaces the session under the same ID.
    ///
    /// - Parameters:
    ///   - id: the `conversationID` the response was generated under.
    ///   - sentiment: the reporter's overall rating, or `nil` to report issues only.
    ///   - issues: specific problems with the response.
    /// - Throws: `ArbiterError.invalidRequest` when no session is cached for `id` — either
    ///   the conversation never ran with an ID, or it has aged out of the cache.
    public func feedback(
        forConversation id: String,
        sentiment: AppleFMFeedbackSentiment?,
        issues: [AppleFMFeedbackIssue] = []
    ) async throws -> Data {
        guard let session = await store.cachedSession(for: id) else {
            throw ArbiterError.invalidRequest(
                reason: """
                No Apple Foundation Models session is cached for conversation '\(id)'. Feedback \
                describes the session that produced the response, so the turn must have run with \
                AppleFMOptions.conversationID set and must not yet have been evicted.
                """
            )
        }
        return session.feedbackAttachment(sentiment: sentiment, issues: issues)
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

    /// The options this request actually runs with, once its tools are resolved.
    ///
    /// `AIRequest.tools` declares what a request wants; ``AppleFMOptions/tools`` supplies
    /// the executors Apple needs to run them. A declared tool with no binding is rejected
    /// rather than dropped — following F3 and F4, a request the provider cannot honour as
    /// written fails locally instead of quietly running without the tool the caller was
    /// counting on. When a request declares tools, the session is built with exactly those;
    /// when it declares none, every binding is registered.
    ///
    /// Narrowing the bindings here rather than at each use keeps one description of the
    /// session: the same value feeds `sessionIdentity`, the factory and the transcript, so
    /// they cannot disagree about which tools this session has.
    static func resolvedOptions(for request: AIRequest) throws -> AppleFMOptions {
        var options = self.options(from: request)

        var bindings: [String: AppleFMToolBinding] = [:]
        for binding in options.tools {
            guard bindings.updateValue(binding, forKey: binding.definition.name) == nil else {
                throw ArbiterError.invalidRequest(
                    reason: """
                    AppleFMOptions.tools binds '\(binding.definition.name)' more than once. Tool \
                    names identify the tool to the model, so they must be unique.
                    """
                )
            }
        }

        let declared = request.tools?.map(\.name) ?? []
        guard !declared.isEmpty else { return options }
        guard Set(declared).count == declared.count else {
            throw ArbiterError.invalidRequest(
                reason: "AIRequest.tools declares the same tool name more than once."
            )
        }

        let unbound = declared.filter { bindings[$0] == nil }
        guard unbound.isEmpty else {
            throw ArbiterError.invalidRequest(
                reason: """
                Apple Foundation Models runs tools on-device and needs an executor for each: \
                \(unbound.joined(separator: ", ")) \(unbound.count == 1 ? "has" : "have") no binding \
                in AppleFMOptions.tools.
                """
            )
        }
        options.tools = declared.compactMap { bindings[$0] }
        return options
    }

    static func toolNames(of options: AppleFMOptions) -> [String] {
        options.tools.map(\.definition.name)
    }

    /// The response schema for this request, when it asked for one.
    ///
    /// Only `.structured` converts: `.json` carries no shape to constrain against, and is
    /// already served by the generic JSON prompting in `StructuredOutput`.
    static func schemaTree(for request: AIRequest) throws -> FMSchemaTree? {
        guard case .structured(let schema)? = request.responseFormat else { return nil }
        return try FMSchemaConverter.tree(fromSchemaString: schema, rootName: "Response")
    }

    /// Arguments come back as the JSON the model generated under the tool's own schema, so
    /// a decode failure would mean Apple emitted something its own constraint forbade.
    /// Reported as an empty argument set rather than losing the record that a call happened.
    static func toolCall(from call: FMToolCall) -> ToolCall {
        let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.argumentsJSON.utf8)))
            ?? .object([:])
        return ToolCall(id: call.id, name: call.toolName, arguments: arguments)
    }

    /// Rejects a request whose locale the model does not support, when asked to.
    func checkLocale(_ options: AppleFMOptions) throws {
        guard options.enforceLocale else { return }
        let locale = options.locale ?? .current
        guard localeSupport(locale, options) else {
            throw ArbiterError.unsupportedLanguage(.appleFoundation, locale: locale.identifier)
        }
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

    /// The same session, seen through the interface that can generate a `Generable` value.
    ///
    /// Only a session backed by a real `LanguageModelSession` conforms; an injected double
    /// speaks Arbiter's vocabulary and has no model behind it. That is reported as
    /// unavailability rather than as a bad request, because the request is fine — this
    /// build simply has nothing on-device to answer it.
    func generableSession(
        for transcript: FMTranscript,
        options: AppleFMOptions
    ) async throws -> any FMGenerableRunning {
        let session = try await session(for: transcript, options: options)
        guard let generable = session as? any FMGenerableRunning else {
            throw ArbiterError.providerUnavailable(
                .appleFoundation,
                reason: "Generating a Generable type needs a live on-device session."
            )
        }
        return generable
    }

    /// Translates a session error into an `ArbiterError`. Cancellation and errors that are
    /// already `ArbiterError`s (the transcript builder's rejections) pass through unchanged.
    func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        guard let sessionError = error as? FMSessionError else { return error }
        return FMErrorMapper.arbiterError(for: sessionError.kind, contextLimit: contextLimit)
    }

    /// The history this turn actually runs with.
    ///
    /// The builder always produces the request's *full* history, because that is what the
    /// request describes. If an earlier turn of this conversation already paid for a
    /// summarising retry, the store swaps its condensed form back in here — otherwise every
    /// later turn would replay the history that did not fit and overflow again.
    func running(_ transcript: FMTranscript, options: AppleFMOptions) async -> FMTranscript {
        await store.adopted(conversationID: options.conversationID, transcript: transcript)
    }

    /// Runs `body`, and on a context overflow optionally summarises the older history and
    /// retries exactly once. A second overflow throws: retrying again would loop.
    func withOverflowRecovery<Result>(
        built: FMTranscriptBuilder.Built,
        options: AppleFMOptions,
        body: @Sendable (FMTranscript, String) async throws -> Result
    ) async throws -> Result {
        let running = await running(built.transcript, options: options)
        do {
            return try await body(running, built.prompt)
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

            let condensed = try await condense(running, options: options)
            do {
                let result = try await body(condensed, built.prompt)
                // Adopted only now. A retry that never produced an answer — cancelled, or
                // blocked by a concurrent turn — is not grounds for rewriting the
                // conversation's history behind the caller's back.
                await adopt(original: built.transcript, condensed: condensed, options: options)
                return result
            } catch {
                throw mapped(error)
            }
        }
    }

    /// Makes a condensed transcript the conversation's history from here on.
    ///
    /// Keyed on what the *builder* produced this turn, not on what was run: the next turn's
    /// builder will produce that same history plus the turn just taken, so recognising it as
    /// a prefix is what lets the summary be reused instead of re-earned. A conversation with
    /// no ID has nowhere to record this, and pays for the summary again next turn.
    func adopt(original: FMTranscript, condensed: FMTranscript, options: AppleFMOptions) async {
        guard let conversationID = options.conversationID else { return }
        await store.recordCondensation(
            conversationID: conversationID, original: original, condensed: condensed
        )
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
        //
        // Tools are stripped from it, and this matters: their executors have real effects.
        // Condensing history is Arbiter's own housekeeping, not something the caller asked
        // the model to act on, so a summarising turn must not be able to book a table or
        // send a message on its way to producing a paragraph.
        var summaryOptions = options
        summaryOptions.tools = []
        let summariser = try sessionFactory(
            FMTranscript(entries: [.instructions(segments: [.text(Self.summaryInstruction)], toolNames: [])]),
            summaryOptions
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

        let options = try Self.resolvedOptions(for: request)
        try checkLocale(options)
        let built = try FMTranscriptBuilder.build(from: request, toolNames: Self.toolNames(of: options))
        let settings = FMGenerationSettings(
            request: request, options: options, schema: try Self.schemaTree(for: request)
        )

        // Accumulation lives here rather than in the attempt, so a failure part-way through
        // a stream is still visible to the retry guard below: text already delivered to the
        // consumer must never be re-delivered by a second attempt.
        var accumulated = ""
        var toolCalls: [FMToolCall] = []
        var usage: TokenUsage?
        var transcript = await running(built.transcript, options: options)
        var didRetry = false
        /// Held back until the retry actually completes — see `withOverflowRecovery`.
        var condensedPendingAdoption: FMTranscript?

        while true {
            do {
                let session = try await session(for: transcript, options: options)
                guard !session.isResponding else { throw ArbiterError.busy(.appleFoundation) }

                for try await snapshot in session.stream(to: built.prompt, settings: settings) {
                    try Task.checkCancellation()
                    if !snapshot.toolCalls.isEmpty { toolCalls = snapshot.toolCalls }
                    if let measured = snapshot.usage { usage = measured }
                    let delta = Self.delta(from: accumulated, to: snapshot.content)
                    accumulated = snapshot.content
                    // A snapshot that adds no text carries only metadata — the tool calls
                    // made this turn, the token counts they cost — and both are knowable
                    // only once the turn is over, so both ride on the final chunk. Emitting
                    // one here would show the consumer an empty delta for nothing.
                    guard !delta.isEmpty else { continue }
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
                // The abandoned attempt's calls and counts belong to a turn that produced
                // nothing; the retry reports its own.
                toolCalls = []
                usage = nil
                if let conversationID = options.conversationID {
                    // The cached session holds the transcript that just overflowed.
                    await store.discard(conversationID: conversationID)
                }
                transcript = try await condense(transcript, options: options)
                condensedPendingAdoption = transcript
            }
        }

        if let condensedPendingAdoption {
            await adopt(
                original: built.transcript, condensed: condensedPendingAdoption, options: options
            )
        }

        continuation.yield(AIStreamChunk(
            delta: "",
            accumulatedContent: accumulated,
            isComplete: true,
            usage: usage,
            finishReason: .complete,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls.map(Self.toolCall(from:)),
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
            // No model to ask, so the framework's own documented default stands in.
            maxContextTokens: 4_096,
            supportsStreaming: true,
            // Matches the linked build for the same reason it is false there: the router
            // cannot see the tool bindings that make on-device tool calling work, so
            // advertising it would route tool requests into a dead end.
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

    /// No model is linked, so no language is supported.
    public func supportsLocale(_ locale: Locale = .current) -> Bool { false }

    /// Empty for the same reason.
    public var supportedLanguages: Set<Locale.Language> { [] }

    public init() {
        logger.debug("Apple Foundation Models stub initialized — FoundationModels framework not linked")
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        throw ArbiterError.providerUnavailable(
            .appleFoundation,
            reason: "Apple Foundation Models requires iOS 26+ / macOS 26+ with Apple Intelligence enabled."
        )
    }

    /// Present so feedback-reporting code compiles everywhere; there is no session to
    /// describe without the framework, so it always throws.
    public func feedback(
        forConversation id: String,
        sentiment: AppleFMFeedbackSentiment?,
        issues: [AppleFMFeedbackIssue] = []
    ) async throws -> Data {
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
