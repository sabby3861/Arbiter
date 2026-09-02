// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("AppleFoundationProvider")
struct AppleFoundationProviderTests {

    @Test func providerHasCorrectId() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        #expect(provider.id == .appleFoundation)
    }

    @Test func providerCapabilitiesAreOnDevice() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        #expect(provider.capabilities.privacyLevel == .onDevice)
        #expect(provider.capabilities.costPerMillionInputTokens == nil)
        #expect(provider.capabilities.costPerMillionOutputTokens == nil)
        #expect(provider.capabilities.supportsStreaming)
    }

    @Test func providerSupportsChatAndSummarization() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        let tasks = provider.capabilities.supportedTasks
        #expect(tasks.contains(.chat))
        #expect(tasks.contains(.summarization))
        #expect(tasks.contains(.translation))
        #expect(tasks.contains(.structuredOutput))
    }

    @Test func providerDoesNotSupportToolCalling() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        #expect(!provider.capabilities.supportsToolCalling)
    }

    @Test func stubProviderReportsUnavailable() async {
        #if !canImport(FoundationModels)
        let provider = AppleFoundationProvider()
        let available = await provider.isAvailable
        #expect(!available)
        #endif
    }

    @Test func stubProviderThrowsOnGenerate() async {
        #if !canImport(FoundationModels)
        let provider = AppleFoundationProvider()
        let request = AIRequest.chat("Hello")

        await #expect(throws: ArbiterError.self) {
            try await provider.generate(request)
        }
        #endif
    }

    @Test func stubProviderThrowsOnStream() async throws {
        #if !canImport(FoundationModels)
        let provider = AppleFoundationProvider()
        let request = AIRequest.chat("Hello")
        let stream = provider.stream(request)

        await #expect(throws: ArbiterError.self) {
            for try await _ in stream {}
        }
        #endif
    }

    @Test func providerTierIsSystem() {
        #expect(ProviderID.appleFoundation.tier == .system)
    }

    @Test func providerDisplayNameIsCorrect() {
        #expect(ProviderID.appleFoundation.displayName == "Apple Foundation Models")
    }

    @Test func providerHasFastLatency() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        #expect(provider.capabilities.estimatedLatency == .fast)
    }

    @Test func providerDoesNotSupportImageInput() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        #expect(!provider.capabilities.supportsImageInput)
    }

    @Test func providerContextWindowIs4K() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        #expect(provider.capabilities.maxContextTokens == 4_096)
    }

    @Test func providerDoesNotSupportCodeGeneration() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        #expect(!provider.capabilities.supportedTasks.contains(.codeGeneration))
    }

    @Test func providerDoesNotSupportEmbedding() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        #expect(!provider.capabilities.supportedTasks.contains(.embedding))
    }
}

@Suite("AvailabilityChecker")
struct AvailabilityCheckerTests {

    @Test func unavailableReasonReturnsString() async {
        let reason = await AvailabilityChecker.unavailableReason()
        #expect(!reason.isEmpty)
    }

    @Test func availabilityCheckReturnsBoolean() async {
        let available = await AvailabilityChecker.isAppleFoundationAvailable()
        // On machines without FoundationModels, this should be false
        #if !canImport(FoundationModels)
        #expect(!available)
        #endif
        _ = available // Silence unused warning when FoundationModels IS available
    }
}

#if canImport(FoundationModels)

/// Behavioural coverage for the provider itself.
///
/// Guarded on the SDK and OS because it touches `AppleFoundationProvider`, but *not* on
/// Apple Intelligence: both the session and the availability probe are injected, so these
/// run on any macOS 26 machine and in CI.
@Suite("AppleFoundationProvider behaviour")
struct AppleFoundationProviderBehaviourTests {

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func makeProvider(
        scripts: [[MockFMSession.Step]],
        available: Bool = true,
        contextLimit: Int = 4_096,
        store: AppleFMSessionStore = AppleFMSessionStore()
    ) -> (AppleFoundationProvider, MockFMSessionFactory) {
        let factory = MockFMSessionFactory(scripts: scripts)
        let provider = AppleFoundationProvider(
            store: store,
            contextLimit: contextLimit,
            availabilityCheck: { available },
            sessionFactory: factory.factory
        )
        return (provider, factory)
    }

    private var conversation: AIRequest {
        AIRequest(
            messages: [
                .user("What is the capital of France?"),
                .assistant("Paris."),
                .user("And Japan?"),
            ],
            systemPrompt: "Be terse."
        )
    }

    // MARK: - History

    /// The headline fix: history used to be dropped entirely.
    @Test func historyReachesTheSessionAndOnlyTheLatestTurnIsPrompted() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("Tokyo.")]])

        let response = try await provider.generate(conversation)

        #expect(response.content == "Tokyo.")
        #expect(response.provider == .appleFoundation)
        #expect(response.finishReason == .complete)

        let session = try #require(factory.sessions.first)
        #expect(session.prompts == ["And Japan?"])
        #expect(session.transcript.entries == [
            .instructions(segments: [.text("Be terse.")], toolNames: []),
            .prompt(segments: [.text("What is the capital of France?")]),
            .response(segments: [.text("Paris.")]),
        ])
    }

    @Test func generationOptionsReachTheSession() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("ok")]])
        let request = AIRequest.chat("Hi").withTemperature(0.2).withMaxTokens(64)

        _ = try await provider.generate(request)

        let settings = try #require(factory.sessions.first?.settings.first)
        #expect(settings.temperature == 0.2)
        #expect(settings.maximumResponseTokens == 64)
    }

    @Test func providerOptionsSelectTheSamplingMode() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("ok")]])
        let request = AIRequest.chat("Hi")
            .withProviderOptions(AppleFMOptions(sampling: .greedy), for: .appleFoundation)

        _ = try await provider.generate(request)

        #expect(factory.sessions.first?.settings.first?.sampling == .greedy)
    }

    @Test func conversationIDReusesOneSessionAcrossTurns() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("Paris."), .text("Tokyo.")]])
        let options = AppleFMOptions(conversationID: "chat-1")

        // A real second turn: the caller appends the reply and asks again. The cached
        // session has meanwhile grown by exactly those two entries, so its fingerprint
        // matches the history this request implies and the session is reused.
        _ = try await provider.generate(
            AIRequest(messages: [.user("Capital of France?")])
                .withProviderOptions(options, for: .appleFoundation)
        )
        _ = try await provider.generate(
            AIRequest(messages: [
                .user("Capital of France?"),
                .assistant("Paris."),
                .user("And Japan?"),
            ]).withProviderOptions(options, for: .appleFoundation)
        )

        #expect(factory.sessionCount == 1)
        #expect(factory.sessions.first?.prompts == ["Capital of France?", "And Japan?"])
    }

    @Test func aDivergentHistoryRebuildsTheSessionRatherThanReusingIt() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("Paris.")], [.text("Tokyo.")]])
        let options = AppleFMOptions(conversationID: "chat-1")

        _ = try await provider.generate(
            AIRequest(messages: [.user("Capital of France?")])
                .withProviderOptions(options, for: .appleFoundation)
        )
        // The caller edited the history rather than extending it, so the cached session
        // holds the wrong conversation and must not be reused.
        _ = try await provider.generate(
            AIRequest(messages: [
                .user("Capital of Spain?"),
                .assistant("Madrid."),
                .user("And Japan?"),
            ]).withProviderOptions(options, for: .appleFoundation)
        )

        #expect(factory.sessionCount == 2)
    }

    // MARK: - Errors

    @Test func contextOverflowMapsToContextWindowExceededNotProviderUnavailable() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(
            scripts: [[.failure(.contextWindowExceeded("too long"))]], contextLimit: 4_096
        )

        do {
            _ = try await provider.generate(conversation)
            Issue.record("Expected the call to throw")
        } catch let error as ArbiterError {
            guard case .contextWindowExceeded(let id, let limit) = error else {
                Issue.record("Expected contextWindowExceeded, got \(error)")
                return
            }
            #expect(id == .appleFoundation)
            #expect(limit == 4_096)
        }
    }

    @Test func refusalSurfacesAsRefusedNotProviderUnavailable() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(scripts: [[.failure(.refusal("I will not"))]])

        do {
            _ = try await provider.generate(conversation)
            Issue.record("Expected the call to throw")
        } catch let error as ArbiterError {
            guard case .refused(_, let explanation) = error else {
                Issue.record("Expected refused, got \(error)")
                return
            }
            #expect(explanation == "I will not")
        }
    }

    @Test func aSessionAlreadyRespondingReportsBusy() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("Paris."), .text("Tokyo.")]])
        let options = AppleFMOptions(conversationID: "chat-1")

        _ = try await provider.generate(
            AIRequest(messages: [.user("Capital of France?")])
                .withProviderOptions(options, for: .appleFoundation)
        )

        // The next turn reuses this session, which is now mid-generation.
        factory.sessions.first?.setResponding(true)

        do {
            _ = try await provider.generate(
                AIRequest(messages: [
                    .user("Capital of France?"),
                    .assistant("Paris."),
                    .user("And Japan?"),
                ]).withProviderOptions(options, for: .appleFoundation)
            )
            Issue.record("Expected the call to throw")
        } catch let error as ArbiterError {
            guard case .busy(let provider) = error else {
                Issue.record("Expected busy, got \(error)")
                return
            }
            #expect(provider == .appleFoundation)
        }
    }

    @Test func unavailableProviderStillReportsProviderUnavailable() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(scripts: [[.text("ok")]], available: false)

        await #expect(throws: ArbiterError.self) {
            try await provider.generate(AIRequest.chat("Hi"))
        }
    }

    @Test func aMalformedRequestIsRejectedBeforeASessionIsBuilt() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("ok")]])

        await #expect(throws: ArbiterError.self) {
            try await provider.generate(AIRequest(messages: [.assistant("orphan")]))
        }
        #expect(factory.sessionCount == 0)
    }

    // MARK: - Overflow recovery

    @Test func overflowRecoverySummarisesAndRetriesExactlyOnce() async throws {
        // Session 1 overflows, session 2 summarises, session 3 answers the retry.
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [
            [.failure(.contextWindowExceeded("too long"))],
            [.text("Earlier: they discussed capitals.")],
            [.text("Tokyo.")],
        ])

        let request = AIRequest(
            messages: [
                .user("one"), .assistant("two"), .user("three"), .assistant("four"),
                .user("five"), .assistant("six"), .user("seven"), .assistant("eight"),
                .user("nine"), .assistant("ten"), .user("And Japan?"),
            ],
            systemPrompt: "Be terse."
        ).withProviderOptions(
            AppleFMOptions(contextOverflow: .summarizeAndRetry), for: .appleFoundation
        )

        let response = try await provider.generate(request)

        #expect(response.content == "Tokyo.")
        #expect(factory.sessionCount == 3)

        // The middle session is handed the turns being dropped, and only those.
        let summariser = try #require(factory.sessions.dropFirst().first)
        let summarised = try #require(summariser.prompts.first)
        #expect(summarised.contains("one"))
        #expect(!summarised.contains("And Japan?"))

        // The retry replays a shorter transcript that keeps the system prompt, carries the
        // summary, drops the oldest turns and retains the most recent ones verbatim.
        let original = try #require(factory.sessions.first)
        let retried = try #require(factory.sessions.last)
        #expect(retried.transcript.entries.count < original.transcript.entries.count)
        #expect(retried.transcript.entries.first == .instructions(segments: [.text("Be terse.")], toolNames: []))

        let replayed = Self.plainText(retried.transcript)
        #expect(replayed.contains("Earlier: they discussed capitals."))
        #expect(replayed.contains("nine"))
        #expect(!replayed.contains("three"))

        // The unchanged question is still what gets asked.
        #expect(retried.prompts == ["And Japan?"])
    }

    @Test func overflowRecoveryDoesNotLoopWhenTheRetryAlsoOverflows() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [
            [.failure(.contextWindowExceeded("too long"))],
            [.text("summary")],
            [.failure(.contextWindowExceeded("still too long"))],
        ])

        let request = AIRequest(
            messages: [
                .user("one"), .assistant("two"), .user("three"), .assistant("four"),
                .user("five"), .assistant("six"), .user("seven"),
            ]
        ).withProviderOptions(
            AppleFMOptions(contextOverflow: .summarizeAndRetry), for: .appleFoundation
        )

        await #expect(throws: ArbiterError.self) {
            try await provider.generate(request)
        }
        // Three sessions and no more: the second overflow throws rather than retrying again.
        #expect(factory.sessionCount == 3)
    }

    @Test func overflowRecoveryIsOptInAndOffByDefault() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [
            [.failure(.contextWindowExceeded("too long"))],
            [.text("summary")],
        ])

        await #expect(throws: ArbiterError.self) {
            try await provider.generate(conversation)
        }
        #expect(factory.sessionCount == 1)
    }

    /// Cutting the retained window mid-turn used to leave tool outputs answering a call
    /// that was no longer anywhere in the transcript.
    @Test func overflowRecoveryNeverRetainsToolOutputsWithoutTheirCall() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [
            [.failure(.contextWindowExceeded("too long"))],
            [.text("summary")],
            [.text("done")],
        ])

        let calls = (1...4).map {
            ToolCall(id: "c\($0)", name: "t\($0)", arguments: .object([:]))
        }
        let request = AIRequest(messages: [
            .user("q1"), .assistant("a1"), .user("q2"),
            Message(role: .assistant, content: .toolCalls(calls)),
            Message(role: .tool, content: .toolResults(calls.map {
                ToolResult(toolCallId: $0.id, content: "ok")
            })),
            .user("final"),
        ]).withProviderOptions(
            AppleFMOptions(contextOverflow: .summarizeAndRetry), for: .appleFoundation
        )

        _ = try await provider.generate(request)

        let retried = try #require(factory.sessions.last)
        let retainedOutputs = retried.transcript.entries.contains {
            if case .toolOutput = $0 { return true }
            return false
        }
        let retainedCalls = retried.transcript.entries.contains {
            if case .toolCalls = $0 { return true }
            return false
        }
        #expect(retainedCalls || !retainedOutputs)
    }

    /// Every entry must either survive verbatim or reach the summariser; the earlier split
    /// could drop entries into neither.
    @Test func overflowRecoveryLosesNoEntryBetweenSummaryAndRetainedWindow() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [
            [.failure(.contextWindowExceeded("too long"))],
            [.text("summary")],
            [.text("done")],
        ])

        let request = AIRequest(messages: [
            .user("q1"), .assistant("a1"), .user("q2"), .assistant("a2"),
            .user("q3"), .assistant("a3"), .user("q4"), .assistant("a4"),
            .user("final"),
        ]).withProviderOptions(
            AppleFMOptions(contextOverflow: .summarizeAndRetry), for: .appleFoundation
        )

        _ = try await provider.generate(request)

        let summarised = try #require(factory.sessions.dropFirst().first?.prompts.first)
        let replayed = Self.plainText(try #require(factory.sessions.last).transcript)

        // Nothing from the original history falls between the two.
        for token in ["q1", "a1", "q2", "a2", "q3", "a3", "q4", "a4"] {
            #expect(summarised.contains(token) || replayed.contains(token))
        }
    }

    @Test func theSummariserInputIsBoundedByTheContextWindow() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let huge = String(repeating: "word ", count: 100_000)
        let bounded = AppleFoundationProvider.boundedSummaryInput(huge, contextLimit: 4_096)
        // Summarising a transcript that just overflowed would otherwise overflow the
        // summariser too and burn a generation for nothing.
        #expect(bounded.count < huge.count)
        #expect(bounded.hasPrefix("[earlier turns omitted]"))

        let small = "short history"
        #expect(AppleFoundationProvider.boundedSummaryInput(small, contextLimit: 4_096) == small)
    }

    @Test func theRetainedWindowStartsOnAUserTurn() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let entries: [FMTranscriptEntry] = [
            .prompt(segments: [.text("q1")]),
            .response(segments: [.text("a1")]),
            .prompt(segments: [.text("q2")]),
            .response(segments: [.text("a2")]),
        ]
        // Asked to cut at index 1 (a response), the boundary moves forward to the prompt.
        #expect(AppleFoundationProvider.turnBoundary(in: entries, notBefore: 1) == 2)
        // No prompt after the requested point: summarise everything rather than keep a
        // fragment that begins mid-turn.
        #expect(AppleFoundationProvider.turnBoundary(in: entries, notBefore: 3) == entries.count)
    }

    // MARK: - Streaming

    @Test func streamYieldsDeltasAndEndsComplete() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(
            scripts: [[.chunks(["To", "Tok", "Tokyo."])]]
        )

        var chunks: [AIStreamChunk] = []
        for try await chunk in provider.stream(conversation) {
            chunks.append(chunk)
        }

        #expect(chunks.map(\.delta) == ["To", "k", "yo.", ""])
        #expect(chunks.last?.isComplete == true)
        #expect(chunks.last?.accumulatedContent == "Tokyo.")
        #expect(chunks.last?.finishReason == .complete)
        // Every non-final chunk is incomplete: the contract is one terminating chunk.
        #expect(chunks.dropLast().allSatisfy { !$0.isComplete })
    }

    @Test func streamReportsTheWholeSnapshotWhenTheModelRevisesEarlierText() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(
            scripts: [[.chunks(["Tokio", "Tokyo"])]]
        )

        var chunks: [AIStreamChunk] = []
        for try await chunk in provider.stream(conversation) {
            chunks.append(chunk)
        }

        // A revision is not a suffix, so the delta is the full snapshot and
        // accumulatedContent stays authoritative.
        #expect(chunks.map(\.delta) == ["Tokio", "Tokyo", ""])
        #expect(chunks.last?.accumulatedContent == "Tokyo")
    }

    @Test func streamErrorsAreMappedNotFlattened() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(
            scripts: [[.failure(.guardrailViolation("unsafe"))]]
        )

        do {
            for try await _ in provider.stream(conversation) {}
            Issue.record("Expected the stream to throw")
        } catch let error as ArbiterError {
            guard case .contentFiltered = error else {
                Issue.record("Expected contentFiltered, got \(error)")
                return
            }
        }
    }

    @Test func streamRecoversFromOverflowBeforeAnyTextIsEmitted() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [
            [.failure(.contextWindowExceeded("too long"))],
            [.text("summary")],
            [.chunks(["Tok", "Tokyo."])],
        ])

        let request = AIRequest(
            messages: [
                .user("one"), .assistant("two"), .user("three"), .assistant("four"),
                .user("five"), .assistant("six"), .user("And Japan?"),
            ]
        ).withProviderOptions(
            AppleFMOptions(contextOverflow: .summarizeAndRetry), for: .appleFoundation
        )

        var chunks: [AIStreamChunk] = []
        for try await chunk in provider.stream(request) {
            chunks.append(chunk)
        }

        #expect(chunks.last?.accumulatedContent == "Tokyo.")
        #expect(chunks.last?.isComplete == true)
        #expect(factory.sessionCount == 3)
    }

    /// Overflow recovery restarts the response, so it is only safe before any text has
    /// reached the consumer — otherwise the retry would replay content they already saw.
    @Test func streamDoesNotRetryOnceTextHasBeenEmitted() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [
            [.chunksThenFailure(["Tok"], .contextWindowExceeded("too long"))],
            [.text("summary")],
            [.chunks(["Tokyo."])],
        ])

        let request = AIRequest(
            messages: [
                .user("one"), .assistant("two"), .user("three"), .assistant("four"),
                .user("five"), .assistant("six"), .user("And Japan?"),
            ]
        ).withProviderOptions(
            AppleFMOptions(contextOverflow: .summarizeAndRetry), for: .appleFoundation
        )

        var deltas: [String] = []
        do {
            for try await chunk in provider.stream(request) {
                deltas.append(chunk.delta)
            }
            Issue.record("Expected the stream to throw")
        } catch let error as ArbiterError {
            guard case .contextWindowExceeded = error else {
                Issue.record("Expected contextWindowExceeded, got \(error)")
                return
            }
        }

        #expect(deltas == ["Tok"])
        // No summariser, no second attempt: exactly the one session that emitted text.
        #expect(factory.sessionCount == 1)
    }

    private static func plainText(_ transcript: FMTranscript) -> String {
        transcript.entries.map { entry in
            switch entry {
            case .instructions(let segments, _), .prompt(let segments), .response(let segments):
                segments.map { if case .text(let value) = $0 { value } else { "" } }.joined()
            case .toolCalls(let calls):
                calls.map(\.toolName).joined()
            case .toolOutput(_, _, let segments):
                segments.map { if case .text(let value) = $0 { value } else { "" } }.joined()
            }
        }.joined(separator: "\n")
    }
}

#endif
