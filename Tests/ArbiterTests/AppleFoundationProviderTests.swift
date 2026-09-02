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

    /// The capability flag is a routing signal, and it says no even though the machinery
    /// says yes: executors live in `providerOptions`, which `CapabilityMatcher` cannot see,
    /// so advertising tool support would route tool requests here and let an unbound tool
    /// end the fallback chain. Tool calling itself works — see
    /// `aSessionWithBoundToolsRunsOnDevice` and
    /// `boundToolsReachTheSessionAndAreNamedInTheTranscript`.
    @Test func providerDoesNotAdvertiseToolCallingToTheRouter() {
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

    /// Reported from `SystemLanguageModel.contextSize`, so this asserts the two agree
    /// rather than pinning a literal that goes stale the day Apple ships a bigger window.
    @Test func providerContextWindowIsTheModelsReportedSize() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        #expect(provider.capabilities.maxContextTokens > 0)
        // `FMBridge` is itself behind the framework, and this suite compiles either way.
        #if canImport(FoundationModels)
        #expect(provider.capabilities.maxContextTokens == FMBridge.contextSize)
        #endif
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
import FoundationModels

/// A small `@Generable` fixture for the native structured-generation path.
///
/// Inline rather than on disk, matching `ToolTurnFixture`: the package declares no test
/// resources.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct CityFact: Equatable {
    @Guide(description: "The city's name")
    var city: String
    @Guide(description: "Population in millions")
    var populationMillions: Int
}

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
        localeSupported: Bool = true,
        store: AppleFMSessionStore = AppleFMSessionStore()
    ) -> (AppleFoundationProvider, MockFMSessionFactory) {
        let factory = MockFMSessionFactory(scripts: scripts)
        let provider = AppleFoundationProvider(
            store: store,
            contextLimit: contextLimit,
            availabilityCheck: { available },
            localeSupport: { _, _ in localeSupported },
            sessionFactory: factory.factory
        )
        return (provider, factory)
    }

    private func binding(
        named name: String,
        schema: JSONValue = ["type": "object", "properties": ["city": ["type": "string"]]],
        execute: @escaping @Sendable (JSONValue) async throws -> String = { _ in "ok" }
    ) -> AppleFMToolBinding {
        AppleFMToolBinding(
            definition: ToolDefinition(name: name, description: "Test tool", inputSchema: schema),
            execute: execute
        )
    }

    private func definition(named name: String) -> ToolDefinition {
        ToolDefinition(name: name, description: "Test tool", inputSchema: ["type": "object"])
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
            AppleFMOptions(contextOverflow: .summarizeAndRetry, tools: [binding(named: "get_weather")]),
            for: .appleFoundation
        )

        let response = try await provider.generate(request)

        #expect(response.content == "Tokyo.")
        #expect(factory.sessionCount == 3)
        // The retry keeps the caller's tools; only the summariser goes without.
        #expect(factory.sessions.first?.options.tools.map(\.definition.name) == ["get_weather"])
        #expect(factory.sessions.last?.options.tools.map(\.definition.name) == ["get_weather"])

        // The middle session is handed the turns being dropped, and only those.
        let summariser = try #require(factory.sessions.dropFirst().first)
        let summarised = try #require(summariser.prompts.first)
        #expect(summarised.contains("one"))
        #expect(!summarised.contains("And Japan?"))
        // And it is given no tools: condensing history is Arbiter's housekeeping, so the
        // model must not be able to run a caller's executor on the way to a paragraph.
        #expect(summariser.options.tools.isEmpty)

        // The retry replays a shorter transcript that keeps the system prompt, carries the
        // summary, drops the oldest turns and retains the most recent ones verbatim.
        let original = try #require(factory.sessions.first)
        let retried = try #require(factory.sessions.last)
        #expect(retried.transcript.entries.count < original.transcript.entries.count)
        #expect(retried.transcript.entries.first
                == .instructions(segments: [.text("Be terse.")], toolNames: ["get_weather"]))

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

    // MARK: - Structured output

    @Test func aStructuredResponseFormatReachesTheSessionAsASchema() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text(#"{"city":"Tokyo"}"#)]])
        let request = AIRequest.chat("Where?").withResponseFormat(.structured(schema: """
        {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}
        """))

        let response = try await provider.generate(request)

        #expect(response.content == #"{"city":"Tokyo"}"#)
        let settings = try #require(factory.sessions.first?.settings.first)
        let schema = try #require(settings.schema)
        #expect(schema.root == .object(
            name: "Response",
            description: nil,
            properties: [FMSchemaNode.Property(
                name: "city", description: nil,
                schema: .string(constant: nil, pattern: nil), isOptional: false
            )]
        ))
        #expect(settings.includeSchemaInPrompt)
    }

    @Test func includeSchemaInPromptIsForwarded() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("{}")]])
        let request = AIRequest.chat("Where?")
            .withResponseFormat(.structured(schema: #"{"type": "object", "properties": {}}"#))
            .withProviderOptions(AppleFMOptions(includeSchemaInPrompt: false), for: .appleFoundation)

        _ = try await provider.generate(request)

        #expect(factory.sessions.first?.settings.first?.includeSchemaInPrompt == false)
    }

    /// Plain JSON carries no shape to constrain against; the generic prompting path already
    /// covers it, so imposing a schema here would invent one the caller never asked for.
    @Test func plainJSONFormatDoesNotProduceASchema() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("{}")]])

        _ = try await provider.generate(AIRequest.chat("Where?").withResponseFormat(.json))

        #expect(factory.sessions.first?.settings.first?.schema == nil)
    }

    /// A schema that cannot be converted is the caller's to fix, and fails before a session
    /// is built rather than surfacing as an opaque generation failure.
    @Test func anUnusableSchemaIsRejectedBeforeASessionIsBuilt() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("{}")]])
        let request = AIRequest.chat("Where?").withResponseFormat(.structured(schema: """
        {"type": "object", "properties": {"home": {"$ref": "#/$defs/Missing"}}}
        """))

        await #expect(throws: ArbiterError.self) {
            try await provider.generate(request)
        }
        #expect(factory.sessionCount == 0)
    }

    @Test func aStructuredStreamCarriesTheSchemaToo() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.chunks([#"{"city":"#, #"{"city":"Tokyo"}"#])]])
        let request = AIRequest.chat("Where?").withResponseFormat(.structured(schema: """
        {"type": "object", "properties": {"city": {"type": "string"}}}
        """))

        var chunks: [AIStreamChunk] = []
        for try await chunk in provider.stream(request) {
            chunks.append(chunk)
        }

        #expect(chunks.last?.accumulatedContent == #"{"city":"Tokyo"}"#)
        #expect(factory.sessions.first?.settings.first?.schema != nil)
    }

    // MARK: - Tools

    @Test func boundToolsReachTheSessionAndAreNamedInTheTranscript() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("18C")]])
        let request = AIRequest.chat("Weather?")
            .withTools([definition(named: "get_weather")])
            .withProviderOptions(AppleFMOptions(tools: [binding(named: "get_weather")]), for: .appleFoundation)

        _ = try await provider.generate(request)

        let session = try #require(factory.sessions.first)
        #expect(session.options.tools.map(\.definition.name) == ["get_weather"])
        // The instructions entry exists purely to carry the tool definitions here: without
        // one, the session would hold executors the model was never told about.
        #expect(session.transcript.entries.first
                == .instructions(segments: [], toolNames: ["get_weather"]))
    }

    /// Following F3 and F4: a request the provider cannot honour as written fails rather
    /// than running silently without the tool the caller was counting on.
    @Test func aDeclaredToolWithNoBindingIsRejected() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("ok")]])
        let request = AIRequest.chat("Weather?")
            .withTools([definition(named: "get_weather")])
            .withProviderOptions(AppleFMOptions(tools: [binding(named: "get_time")]), for: .appleFoundation)

        do {
            _ = try await provider.generate(request)
            Issue.record("Expected the call to throw")
        } catch let error as ArbiterError {
            guard case .invalidRequest(let reason) = error else {
                Issue.record("Expected invalidRequest, got \(error)")
                return
            }
            #expect(reason.contains("get_weather"))
            #expect(reason.contains("AppleFMOptions.tools"))
        }
        #expect(factory.sessionCount == 0)
    }

    /// Tool names identify the tool to the model, so two bindings cannot share one.
    @Test func duplicateToolBindingsAreRejected() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(scripts: [[.text("ok")]])
        let options = AppleFMOptions(tools: [binding(named: "get_weather"), binding(named: "get_weather")])

        await #expect(throws: ArbiterError.self) {
            try await provider.generate(
                AIRequest.chat("Weather?").withProviderOptions(options, for: .appleFoundation)
            )
        }
    }

    /// A request that names a subset gets a session with exactly that subset — the tool set
    /// is fixed at construction, so anything else would let the model call a tool this
    /// request deliberately withheld.
    @Test func onlyTheToolsARequestDeclaresAreRegistered() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("ok")]])
        let options = AppleFMOptions(tools: [binding(named: "get_weather"), binding(named: "get_time")])

        _ = try await provider.generate(
            AIRequest.chat("Weather?")
                .withTools([definition(named: "get_time")])
                .withProviderOptions(options, for: .appleFoundation)
        )

        #expect(factory.sessions.first?.options.tools.map(\.definition.name) == ["get_time"])
    }

    /// With nothing declared, the bindings are the tool set: they were supplied on purpose.
    @Test func bindingsAreRegisteredWhenTheRequestDeclaresNoTools() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("ok")]])
        let options = AppleFMOptions(tools: [binding(named: "get_weather")])

        _ = try await provider.generate(
            AIRequest.chat("Weather?").withProviderOptions(options, for: .appleFoundation)
        )

        #expect(factory.sessions.first?.options.tools.map(\.definition.name) == ["get_weather"])
    }

    /// The loop completes in-session, so what a caller sees is a finished answer plus a
    /// record of the calls behind it — never a `.toolCall` finish reason to act on.
    @Test func toolCallsAreReportedRetrospectivelyOnACompletedResponse() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let call = FMToolCall(
            id: "call-1", toolName: "get_weather", argumentsJSON: #"{"city":"Tokyo"}"#
        )
        let (provider, _) = makeProvider(scripts: [
            [.toolTurn(text: "18C in Tokyo.", calls: [call], outputs: ["18C"])],
        ])
        let request = AIRequest.chat("Weather in Tokyo?")
            .withProviderOptions(AppleFMOptions(tools: [binding(named: "get_weather")]), for: .appleFoundation)

        let response = try await provider.generate(request)

        #expect(response.finishReason == .complete)
        #expect(response.content == "18C in Tokyo.")
        #expect(response.toolCalls == [ToolCall(
            id: "call-1", name: "get_weather", arguments: ["city": "Tokyo"]
        )])
    }

    @Test func streamedToolCallsArriveOnTheFinalChunkWithoutAnEmptyDelta() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let call = FMToolCall(id: "call-1", toolName: "get_weather", argumentsJSON: "{}")
        let (provider, _) = makeProvider(scripts: [
            [.toolTurn(text: "18C.", calls: [call], outputs: ["18C"])],
        ])
        let request = AIRequest.chat("Weather?")
            .withProviderOptions(AppleFMOptions(tools: [binding(named: "get_weather")]), for: .appleFoundation)

        var chunks: [AIStreamChunk] = []
        for try await chunk in provider.stream(request) {
            chunks.append(chunk)
        }

        // The tool-call snapshot repeats the text, so it must not become a chunk of its own.
        #expect(chunks.map(\.delta) == ["18C.", ""])
        #expect(chunks.last?.isComplete == true)
        #expect(chunks.last?.toolCalls?.map(\.name) == ["get_weather"])
        #expect(chunks.dropLast().allSatisfy { $0.toolCalls == nil })
    }

    /// Generating a `@Generable` value needs the real on-device decoder; an injected double
    /// has no model behind it, and says so rather than pretending.
    @Test func generableGenerationReportsUnavailableAgainstAnInjectedSession() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(scripts: [[.text("{}")]])

        do {
            _ = try await provider.generate(AIRequest.chat("Where?"), as: CityFact.self)
            Issue.record("Expected the call to throw")
        } catch let error as ArbiterError {
            guard case .providerUnavailable = error else {
                Issue.record("Expected providerUnavailable, got \(error)")
                return
            }
        }
    }

    // MARK: - Locale

    /// Off by default: the check tests a locale, not the language the prompt is written in,
    /// so enforcing it unasked would reject valid requests from an unsupported region.
    @Test func anUnsupportedLocaleIsAllowedThroughUnlessEnforcementIsRequested() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(scripts: [[.text("ok")]], localeSupported: false)

        let response = try await provider.generate(AIRequest.chat("Bonjour"))

        #expect(response.content == "ok")
    }

    @Test func enforcingAnUnsupportedLocaleRejectsTheRequest() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("ok")]], localeSupported: false)
        let options = AppleFMOptions(locale: Locale(identifier: "cy_GB"), enforceLocale: true)

        do {
            _ = try await provider.generate(
                AIRequest.chat("Bore da").withProviderOptions(options, for: .appleFoundation)
            )
            Issue.record("Expected the call to throw")
        } catch let error as ArbiterError {
            guard case .unsupportedLanguage(let id, let locale) = error else {
                Issue.record("Expected unsupportedLanguage, got \(error)")
                return
            }
            #expect(id == .appleFoundation)
            #expect(locale == "cy_GB")
        }
        #expect(factory.sessionCount == 0)
    }

    @Test func enforcingASupportedLocalePassesThrough() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(scripts: [[.text("ok")]], localeSupported: true)
        let options = AppleFMOptions(locale: Locale(identifier: "en_GB"), enforceLocale: true)

        let response = try await provider.generate(
            AIRequest.chat("Hello").withProviderOptions(options, for: .appleFoundation)
        )

        #expect(response.content == "ok")
    }

    @Test func enforcementAppliesToStreamingToo() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(scripts: [[.text("ok")]], localeSupported: false)
        let options = AppleFMOptions(enforceLocale: true)

        await #expect(throws: ArbiterError.self) {
            for try await _ in provider.stream(
                AIRequest.chat("Hi").withProviderOptions(options, for: .appleFoundation)
            ) {}
        }
    }

    // MARK: - Token accounting

    @Test func measuredUsageReachesTheResponse() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let usage = TokenUsage(inputTokens: 120, outputTokens: 9)
        let (provider, factory) = makeProvider(scripts: [[.textWithUsage("Tokyo.", usage)]])

        let response = try await provider.generate(conversation)

        #expect(response.usage == usage)
        // Counting is on unless the caller turns it off.
        #expect(factory.sessions.first?.settings.first?.reportTokenUsage == true)
    }

    @Test func measuredUsageReachesTheFinalStreamChunk() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let usage = TokenUsage(inputTokens: 120, outputTokens: 9)
        let (provider, _) = makeProvider(scripts: [[.textWithUsage("Tokyo.", usage)]])

        var chunks: [AIStreamChunk] = []
        for try await chunk in provider.stream(conversation) {
            chunks.append(chunk)
        }

        let last = try #require(chunks.last)
        #expect(last.isComplete)
        #expect(last.usage == usage)
        // The counts ride on the completion chunk alone — a snapshot that only reports them
        // carries no new text and must not surface as an empty delta.
        #expect(chunks.dropLast().allSatisfy { $0.usage == nil })
        #expect(chunks.dropLast().allSatisfy { !$0.delta.isEmpty })
    }

    /// Nothing is fabricated when counting is off or unavailable: `nil` means "not
    /// measured", which the router's estimator already handles.
    @Test func usageIsAbsentRatherThanEstimatedWhenNotReported() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(
            scripts: [[.textWithUsage("Tokyo.", TokenUsage(inputTokens: 120, outputTokens: 9))]]
        )
        let request = conversation.withProviderOptions(
            AppleFMOptions(reportTokenUsage: false), for: .appleFoundation
        )

        let response = try await provider.generate(request)

        #expect(response.usage == nil)
        #expect(factory.sessions.first?.settings.first?.reportTokenUsage == false)
    }

    /// An abandoned attempt's counts belong to a turn that produced nothing.
    @Test func aRetriedStreamReportsOnlyTheRetrysUsage() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let retryUsage = TokenUsage(inputTokens: 40, outputTokens: 3)
        let (provider, _) = makeProvider(scripts: [
            [.failure(.contextWindowExceeded("too long"))],
            [.text("summary")],
            [.textWithUsage("Tokyo.", retryUsage)],
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

        #expect(chunks.last?.usage == retryUsage)
    }

    @Test func theReportedContextWindowIsTheModelsOwn() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(scripts: [[]], contextLimit: 65_536)
        #expect(provider.capabilities.maxContextTokens == 65_536)
    }

    // MARK: - Feedback

    @Test func feedbackIsBuiltBySessionThatProducedTheResponse() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, factory) = makeProvider(scripts: [[.text("Tokyo.")]])
        _ = try await provider.generate(conversation.withProviderOptions(
            AppleFMOptions(conversationID: "chat"), for: .appleFoundation
        ))

        let issues = [AppleFMFeedbackIssue(category: .tooVerbose, explanation: "Rambled.")]
        let attachment = try await provider.feedback(
            forConversation: "chat", sentiment: .negative, issues: issues
        )

        // The provider hands back exactly what the session produced, unwrapped.
        #expect(attachment == Data("mock-feedback".utf8))
        let filed = try #require(factory.sessions.first?.feedback.first)
        #expect(filed.sentiment == .negative)
        #expect(filed.issues == issues)
    }

    /// Feedback describes a specific session, so without one there is nothing to describe —
    /// reported as a bad request rather than an empty attachment.
    @Test func feedbackWithoutACachedSessionIsRejected() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let (provider, _) = makeProvider(scripts: [[.text("Tokyo.")]])
        // Ran without a conversation ID, so nothing was cached.
        _ = try await provider.generate(conversation)

        await #expect(throws: ArbiterError.self) {
            _ = try await provider.feedback(forConversation: "chat", sentiment: .positive)
        }
    }

    // MARK: - Overflow adoption

    /// The condensed history has to become the conversation's history, or every later turn
    /// replays the transcript that already did not fit and pays for a summary again.
    @Test func aCondensedHistoryIsAdoptedByTheFollowingTurn() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let store = AppleFMSessionStore()
        let (provider, factory) = makeProvider(
            scripts: [
                [.failure(.contextWindowExceeded("too long"))],
                [.text("Earlier: they discussed capitals.")],
                [.text("Tokyo."), .text("Berlin.")],
            ],
            store: store
        )
        let options = AppleFMOptions(
            conversationID: "chat", contextOverflow: .summarizeAndRetry
        )
        let history: [Message] = [
            .user("one"), .assistant("two"), .user("three"), .assistant("four"),
            .user("five"), .assistant("six"), .user("seven"), .assistant("eight"),
            .user("nine"), .assistant("ten"),
        ]

        let first = try await provider.generate(
            AIRequest(messages: history + [.user("And Japan?")], systemPrompt: "Be terse.")
                .withProviderOptions(options, for: .appleFoundation)
        )
        #expect(first.content == "Tokyo.")
        #expect(factory.sessionCount == 3)

        // Turn two carries the whole conversation again, including the answer just given.
        let second = try await provider.generate(
            AIRequest(
                messages: history + [.user("And Japan?"), .assistant("Tokyo."), .user("Germany?")],
                systemPrompt: "Be terse."
            ).withProviderOptions(options, for: .appleFoundation)
        )

        #expect(second.content == "Berlin.")
        // No fourth session and no second summariser: the condensed history was adopted, so
        // the turn fits — and it is the retry's own session, extended.
        #expect(factory.sessionCount == 3)
        let retried = try #require(factory.sessions.last)
        #expect(retried.callCount == 2)
        #expect(retried.prompts == ["And Japan?", "Germany?"])

        // Exactly one summarisation across both turns.
        let summariser = try #require(factory.sessions.dropFirst().first)
        #expect(summariser.callCount == 1)
    }

    /// Cancelling a turn, or losing it to a concurrent one, is not grounds for replacing
    /// the caller's history with a summary it never got an answer from.
    @Test func aRetryThatProducesNoAnswerIsNotAdopted() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let store = AppleFMSessionStore()
        let (provider, factory) = makeProvider(
            scripts: [
                [.failure(.contextWindowExceeded("too long"))],
                [.text("summary")],
                [.failure(.concurrentRequests("another turn holds the session"))],
            ],
            store: store
        )
        let request = AIRequest(
            messages: [
                .user("one"), .assistant("two"), .user("three"), .assistant("four"),
                .user("five"), .assistant("six"), .user("And Japan?"),
            ]
        ).withProviderOptions(
            AppleFMOptions(conversationID: "chat", contextOverflow: .summarizeAndRetry),
            for: .appleFoundation
        )

        await #expect(throws: ArbiterError.self) {
            try await provider.generate(request)
        }
        #expect(factory.sessionCount == 3)
        #expect(await store.condensation(for: "chat") == nil)
    }

    /// Adoption is keyed on a conversation, so a stateless caller gets the old behaviour:
    /// correct, but paying for the summary every turn.
    @Test func adoptionNeedsAConversationID() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let store = AppleFMSessionStore()
        let (provider, factory) = makeProvider(
            scripts: [
                [.failure(.contextWindowExceeded("too long"))],
                [.text("summary")],
                [.text("Tokyo.")],
                [.failure(.contextWindowExceeded("too long"))],
                [.text("summary")],
                [.text("Berlin.")],
            ],
            store: store
        )
        let options = AppleFMOptions(contextOverflow: .summarizeAndRetry)
        let history: [Message] = [
            .user("one"), .assistant("two"), .user("three"), .assistant("four"),
            .user("five"), .assistant("six"),
        ]

        _ = try await provider.generate(
            AIRequest(messages: history + [.user("And Japan?")])
                .withProviderOptions(options, for: .appleFoundation)
        )
        _ = try await provider.generate(
            AIRequest(messages: history + [.user("And Japan?"), .assistant("Tokyo."), .user("Germany?")])
                .withProviderOptions(options, for: .appleFoundation)
        )

        #expect(factory.sessionCount == 6)
    }

    /// A streamed overflow adopts its summary the same way a non-streamed one does.
    @Test func aStreamedCondensationIsAdoptedToo() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let store = AppleFMSessionStore()
        let (provider, factory) = makeProvider(
            scripts: [
                [.failure(.contextWindowExceeded("too long"))],
                [.text("Earlier: they discussed capitals.")],
                [.text("Tokyo."), .text("Berlin.")],
            ],
            store: store
        )
        let options = AppleFMOptions(
            conversationID: "chat", contextOverflow: .summarizeAndRetry
        )
        let history: [Message] = [
            .user("one"), .assistant("two"), .user("three"), .assistant("four"),
            .user("five"), .assistant("six"), .user("seven"), .assistant("eight"),
        ]

        for try await _ in provider.stream(
            AIRequest(messages: history + [.user("And Japan?")])
                .withProviderOptions(options, for: .appleFoundation)
        ) {}
        #expect(factory.sessionCount == 3)

        for try await _ in provider.stream(
            AIRequest(messages: history + [.user("And Japan?"), .assistant("Tokyo."), .user("Germany?")])
                .withProviderOptions(options, for: .appleFoundation)
        ) {}

        #expect(factory.sessionCount == 3)
        #expect(factory.sessions.dropFirst().first?.callCount == 1)
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

/// The real device path: a live `LanguageModelSession`, no doubles.
///
/// Skipped unless Apple Intelligence is actually available, so it is a no-op in CI and on
/// machines with the feature switched off — everything else in this file runs everywhere.
@Suite("AppleFoundationProvider on-device")
struct AppleFoundationProviderDeviceTests {

    @Test func generableTypesRoundTripThroughNativeDecoding() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        guard await provider.isAvailable else { return }

        // Generously capped: constrained decoding throws `decodingFailure` on a truncated
        // structure rather than returning partial JSON, so a tight cap would make this test
        // fail on a verbose sample rather than on a real defect.
        let fact = try await provider.generate(
            AIRequest.chat("Tokyo's population, to the nearest million.").withMaxTokens(512),
            as: CityFact.self
        )

        // What is under test is the round trip, not the model's grasp of demographics: a
        // required `String` property came back as one, and an `Int` as an `Int`.
        #expect(!fact.city.isEmpty)
    }

    @Test func generableTypesStreamAsPartialValues() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        guard await provider.isAvailable else { return }

        var snapshots = 0
        for try await _ in provider.streamGenerate(
            AIRequest.chat("Paris's population, to the nearest million.").withMaxTokens(512),
            as: CityFact.self
        ) {
            snapshots += 1
        }

        #expect(snapshots > 0)
    }

    /// The end-to-end claim behind `supportsToolCalling`: a transcript-built session with
    /// bound tools is one the framework accepts and can run. Whether the model chooses to
    /// call the tool is its own decision, so only the structural claim is asserted — plus
    /// the record, when a call did happen.
    @Test func aSessionWithBoundToolsRunsOnDevice() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        guard await provider.isAvailable else { return }

        let calls = CallCounter()
        let binding = AppleFMToolBinding(
            definition: ToolDefinition(
                name: "get_population",
                description: "The population of a city, in millions",
                inputSchema: [
                    "type": "object",
                    "properties": ["city": ["type": "string", "description": "City name"]],
                    "required": ["city"],
                ]
            ),
            execute: { arguments in
                await calls.record(arguments)
                return "14"
            }
        )

        let response = try await provider.generate(
            AIRequest.chat("Use the tool to get Tokyo's population, then state it.")
                .withMaxTokens(512)
                .withTools([binding.definition])
                .withProviderOptions(AppleFMOptions(tools: [binding]), for: .appleFoundation)
        )

        #expect(!response.content.isEmpty)
        // The loop completes in-session either way: there is never a call left for the
        // caller to run.
        #expect(response.finishReason == .complete)
        // Whether the model calls the tool is its own decision, so the assertion is the
        // invariant rather than the choice: what the response reports and what actually ran
        // are the same events. (In practice this prompt does call it.)
        let executed = await calls.count
        #expect(response.toolCalls.count == executed)
        if let call = response.toolCalls.first {
            #expect(call.name == "get_population")
            #expect(await calls.arguments.count == executed)
        }
    }

    /// The claim the mock cannot make: these numbers are *measured*, not plumbed.
    @Test func tokenUsageIsMeasuredAgainstTheRealTokeniser() async throws {
        guard #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) else { return }
        let provider = AppleFoundationProvider()
        guard await provider.isAvailable else { return }

        let response = try await provider.generate(
            AIRequest.chat("Name one primary colour.").withMaxTokens(64)
        )

        let usage = try #require(response.usage)
        #expect(usage.inputTokens > 0)
        #expect(usage.outputTokens > 0)
        // A turn the model accepted cannot have cost more than the window it fitted into.
        #expect(usage.totalTokens <= provider.capabilities.maxContextTokens)
    }

    /// Pins how a response schema is accounted for, which is not obvious and was measured
    /// rather than assumed: with `includeSchemaInPrompt` on, the framework renders the
    /// schema into the prompt entry, so a count over the transcript already carries it;
    /// with it off, the schema never becomes text — it only constrains sampling — so there
    /// is nothing to attribute. Either way, counting the schema separately on top would be
    /// wrong, which is what this guards.
    @Test func aStructuredTurnCountsItsSchemaExactlyOnce() async throws {
        guard #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) else { return }
        let provider = AppleFoundationProvider()
        guard await provider.isAvailable else { return }

        let schemaJSON = """
        {"type": "object",
         "properties": {"city": {"type": "string"},
                        "country": {"type": "string"},
                        "populationMillions": {"type": "integer",
                                               "minimum": 1, "maximum": 100}},
         "required": ["city", "country", "populationMillions"]}
        """
        let question = "Tokyo."

        func inputTokens(schemaInPrompt: Bool?) async throws -> Int {
            var request = AIRequest.chat(question).withMaxTokens(256)
            if let schemaInPrompt {
                request = request
                    .withResponseFormat(.structured(schema: schemaJSON))
                    .withProviderOptions(
                        AppleFMOptions(includeSchemaInPrompt: schemaInPrompt), for: .appleFoundation
                    )
            }
            return try #require(try await provider.generate(request).usage?.inputTokens)
        }

        let plain = try await inputTokens(schemaInPrompt: nil)
        let described = try await inputTokens(schemaInPrompt: true)
        let constrainedOnly = try await inputTokens(schemaInPrompt: false)

        let schemaTokens = try await SystemLanguageModel.default.tokenCount(
            for: FMBridge.generationSchema(
                from: try FMSchemaConverter.tree(fromSchemaString: schemaJSON, rootName: "Response")
            )
        )

        // Described in the prompt: costs about its own size, once. Counting it twice would
        // put the difference at roughly double.
        #expect(described > plain)
        #expect(described - plain < schemaTokens * 3 / 2)
        // Constraint only: never sent as text, so it costs the same as no schema at all.
        #expect(constrainedOnly == plain)
    }

    @Test func localeSupportIsReportedFromTheModel() async {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        guard await provider.isAvailable else { return }

        #expect(provider.supportsLocale(Locale(identifier: "en_US")))
        #expect(!provider.supportedLanguages.isEmpty)
    }

    /// The end-to-end claim behind `supportedTasks.structuredOutput`: a JSON Schema string
    /// comes back as JSON matching it, decoded by constrained generation rather than by
    /// asking the model nicely.
    @Test func aStructuredSchemaConstrainsTheAnswer() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let provider = AppleFoundationProvider()
        guard await provider.isAvailable else { return }

        let response = try await provider.generate(
            AIRequest.chat("Tokyo's population, to the nearest million.")
                .withMaxTokens(512)
                .withResponseFormat(.structured(schema: """
                {"type": "object",
                 "properties": {"city": {"type": "string"}, "populationMillions": {"type": "integer"}},
                 "required": ["city", "populationMillions"]}
                """))
        )

        let decoded = try JSONDecoder().decode(
            [String: JSONValue].self, from: Data(response.content.utf8)
        )
        #expect(decoded["city"] != nil)
        #expect(decoded["populationMillions"] != nil)
    }
}

/// Counts executor invocations across the concurrency boundary the session calls them on.
private actor CallCounter {
    private(set) var count = 0
    private(set) var arguments: [JSONValue] = []

    func record(_ value: JSONValue) {
        count += 1
        arguments.append(value)
    }
}

#endif
