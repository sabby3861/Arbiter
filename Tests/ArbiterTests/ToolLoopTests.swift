// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("Tool loop")
struct ToolLoopTests {
    // MARK: - Helpers

    static func call(_ name: String, id: String? = nil, city: String = "Paris") -> ToolCall {
        ToolCall(
            id: id ?? "call-\(name)-\(UUID().uuidString.prefix(4))",
            name: name,
            arguments: .object(["city": .string(city)])
        )
    }

    static func tool(
        _ name: String,
        recorder: CallRecorder,
        concurrencySafe: Bool = true,
        timeout: Duration? = nil,
        delay: Duration? = nil,
        body: (@Sendable (JSONValue, ToolContext) async throws -> ToolOutput)? = nil
    ) -> FunctionTool {
        FunctionTool(
            name: name,
            description: "Test tool \(name)",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["city": .object(["type": .string("string")])]),
            ]),
            isConcurrencySafe: concurrencySafe,
            timeout: timeout
        ) { arguments, context in
            recorder.begin()
            defer { recorder.end(name) }
            if let delay { try await Task.sleep(for: delay) }
            if let body { return try await body(arguments, context) }
            return .content("\(name) ran")
        }
    }

    // MARK: - The loop

    @Test func parallelCallsRunTogetherAndEveryResultGoesBack() async throws {
        let recorder = CallRecorder()
        let calls = [
            Self.call("alpha", id: "c1"), Self.call("bravo", id: "c2"), Self.call("charlie", id: "c3"),
        ]
        let provider = ScriptedProvider(script: [
            .toolCallTurn(calls),
            .answerTurn("All three done"),
        ])
        let ai = Arbiter(provider: provider)

        let result = try await ai.run(
            [.user("Do three things")],
            tools: [
                Self.tool("alpha", recorder: recorder, delay: .milliseconds(60)),
                Self.tool("bravo", recorder: recorder, delay: .milliseconds(60)),
                Self.tool("charlie", recorder: recorder, delay: .milliseconds(60)),
            ]
        )

        #expect(result.content == "All three done")
        #expect(result.rounds == 1)
        #expect(result.invocations.count == 3)
        #expect(recorder.maximumConcurrency == 3)

        // The tool turn carries one result per call, in the order the model asked.
        let toolTurn = try #require(result.messages.first { $0.role == .tool })
        let results = toolTurn.content.allToolResults
        #expect(results.map(\.toolCallId) == ["c1", "c2", "c3"])
        #expect(results.allSatisfy { $0.content.hasSuffix("ran") })

        // And the model saw them: the second request contains the whole exchange.
        let secondRequest = provider.requests[1]
        #expect(secondRequest.messages.count == 3)
        #expect(secondRequest.messages[1].content.allToolCalls.count == 3)
        #expect(secondRequest.messages[2].content.allToolResults.count == 3)
    }

    @Test func aToolThatIsNotConcurrencySafeRunsAlone() async throws {
        let recorder = CallRecorder()
        let calls = [
            Self.call("alpha", id: "c1"), Self.call("exclusive", id: "c2"), Self.call("charlie", id: "c3"),
        ]
        let provider = ScriptedProvider(script: [.toolCallTurn(calls), .answerTurn("Done")])
        let ai = Arbiter(provider: provider)

        let result = try await ai.run(
            [.user("Go")],
            tools: [
                Self.tool("alpha", recorder: recorder, delay: .milliseconds(30)),
                Self.tool("exclusive", recorder: recorder, concurrencySafe: false, delay: .milliseconds(30)),
                Self.tool("charlie", recorder: recorder, delay: .milliseconds(30)),
            ]
        )

        #expect(recorder.maximumConcurrency == 1)
        #expect(recorder.calls == ["alpha", "exclusive", "charlie"])
        #expect(result.invocations.map(\.call.id) == ["c1", "c2", "c3"])
    }

    @Test func theLoopStopsAtTheRoundLimit() async throws {
        let recorder = CallRecorder()
        // The model never stops asking for tools. Each turn asks with a fresh call id, as
        // a real provider does, so nothing is served from an earlier identical call.
        let provider = ScriptedProvider(script: [
            .toolCallTurn([Self.call("alpha", id: "r1")]),
            .toolCallTurn([Self.call("alpha", id: "r2")]),
            .toolCallTurn([Self.call("alpha", id: "r3")]),
        ])
        let ai = Arbiter(provider: provider)

        let result = try await ai.run(
            [.user("Loop forever")],
            tools: [Self.tool("alpha", recorder: recorder)],
            maxToolRounds: 2
        )

        #expect(result.stoppedAtRoundLimit)
        #expect(result.rounds == 2)
        #expect(recorder.calls.count == 2)
        // Two rounds of tools means three model turns: the last one is what stopped it.
        #expect(provider.callCount == 3)
    }

    @Test func zeroRoundsExecutesNoToolsAtAll() async throws {
        let recorder = CallRecorder()
        let provider = ScriptedProvider(script: [.toolCallTurn([Self.call("alpha")])])
        let ai = Arbiter(provider: provider)

        let result = try await ai.run(
            [.user("Go")], tools: [Self.tool("alpha", recorder: recorder)], maxToolRounds: 0
        )

        #expect(result.stoppedAtRoundLimit)
        #expect(recorder.calls.isEmpty)
        #expect(provider.callCount == 1)
    }

    @Test func aTurnWithoutToolCallsEndsTheRun() async throws {
        let provider = ScriptedProvider(script: [.answerTurn("Straight answer")])
        let ai = Arbiter(provider: provider)

        let result = try await ai.run([.user("Hello")], tools: [])

        #expect(result.content == "Straight answer")
        #expect(result.rounds == 0)
        #expect(result.invocations.isEmpty)
        #expect(!result.stoppedAtRoundLimit)
    }

    // MARK: - Human in the loop

    @Test func approvalSuspendsTheRunAndResumesIt() async throws {
        let recorder = CallRecorder()
        let provider = ScriptedProvider(script: [
            .toolCallTurn([Self.call("transfer", id: "c1")]),
            .answerTurn("Transferred"),
        ])
        let ai = Arbiter(provider: provider)
        let tool = Self.tool("transfer", recorder: recorder) { _, context in
            context.isApproved ? .content("money moved") : .requiresApproval(payload: "Move £10?")
        }

        let run = Task { try await ai.run([.user("Send money")], tools: [tool]) }

        // The run is suspended until someone answers, and the request is waiting.
        var seen: ToolApprovalRequest?
        for await request in await ai.pendingApprovals {
            seen = request
            break
        }
        let pending = try #require(seen)
        #expect(pending.id == "c1")
        #expect(pending.payload == "Move £10?")
        await ai.approve(pending.id)

        let result = try await run.value
        #expect(result.content == "Transferred")
        #expect(result.invocations.first?.approval == .approved)
        #expect(result.invocations.first?.result.content == "money moved")
        // Called twice: once to ask, once to act.
        #expect(recorder.calls == ["transfer", "transfer"])
        #expect(await ai.pendingApprovalRequests.isEmpty)
    }

    @Test func denialTellsTheModelAndNeverRunsTheTool() async throws {
        let recorder = CallRecorder()
        let provider = ScriptedProvider(script: [
            .toolCallTurn([Self.call("transfer", id: "c1")]),
            .answerTurn("Understood, cancelled"),
        ])
        let ai = Arbiter(provider: provider)
        let tool = Self.tool("transfer", recorder: recorder) { _, context in
            context.isApproved ? .content("money moved") : .requiresApproval(payload: "Move £10?")
        }

        let run = Task { try await ai.run([.user("Send money")], tools: [tool]) }
        for await request in await ai.pendingApprovals {
            await ai.deny(request.id, reason: "not today")
            break
        }

        let result = try await run.value
        let invocation = try #require(result.invocations.first)
        #expect(invocation.approval == .denied(reason: "not today"))
        #expect(invocation.result.content.contains("denied"))
        #expect(invocation.result.content.contains("not today"))
        // The tool was asked once and never acted.
        #expect(recorder.calls == ["transfer"])
        #expect(result.content == "Understood, cancelled")
    }

    @Test func aDecisionThatArrivesFirstIsNotLost() async throws {
        let recorder = CallRecorder()
        let provider = ScriptedProvider(script: [
            .toolCallTurn([Self.call("transfer", id: "known-id")]),
            .answerTurn("Done"),
        ])
        let ai = Arbiter(provider: provider)
        let tool = Self.tool("transfer", recorder: recorder) { _, context in
            context.isApproved ? .content("moved") : .requiresApproval(payload: "Move £10?")
        }

        // Answered before the call is even made.
        await ai.approve("known-id")
        let result = try await ai.run([.user("Send money")], tools: [tool])

        #expect(result.invocations.first?.result.content == "moved")
    }

    // MARK: - Failure handling

    @Test func anUnknownToolIsReportedToTheModelRatherThanThrown() async throws {
        let provider = ScriptedProvider(script: [
            .toolCallTurn([Self.call("nonexistent", id: "c1")]),
            .answerTurn("I could not do that"),
        ])
        let ai = Arbiter(provider: provider)

        let result = try await ai.run([.user("Go")], tools: [])

        let invocation = try #require(result.invocations.first)
        #expect(invocation.failed)
        #expect(invocation.result.content.contains("no tool named 'nonexistent'"))
        #expect(result.content == "I could not do that")
    }

    @Test func aThrowingToolIsReportedToTheModel() async throws {
        let recorder = CallRecorder()
        let provider = ScriptedProvider(script: [
            .toolCallTurn([Self.call("broken", id: "c1")]),
            .answerTurn("Sorry, that failed"),
        ])
        let ai = Arbiter(provider: provider)
        let tool = Self.tool("broken", recorder: recorder) { _, _ in
            throw ArbiterError.invalidRequest(reason: "no such city")
        }

        let result = try await ai.run([.user("Go")], tools: [tool])

        let invocation = try #require(result.invocations.first)
        #expect(invocation.failed)
        #expect(invocation.result.content.contains("no such city"))
        #expect(result.content == "Sorry, that failed")
    }

    @Test func aToolThatOverrunsItsTimeoutIsCancelledAndReported() async throws {
        let recorder = CallRecorder()
        let provider = ScriptedProvider(script: [
            .toolCallTurn([Self.call("slow", id: "c1")]),
            .answerTurn("Moving on"),
        ])
        let ai = Arbiter(provider: provider)
        let tool = Self.tool(
            "slow", recorder: recorder, timeout: .milliseconds(50), delay: .seconds(5)
        )

        let result = try await ai.run([.user("Go")], tools: [tool])

        let invocation = try #require(result.invocations.first)
        #expect(invocation.failed)
        #expect(invocation.result.content.contains("timed out"))
    }

    @Test func repeatingOneCallIsServedFromTheFirstExecution() async throws {
        let recorder = CallRecorder()
        // The same call id and arguments coming back a second time is the same call, not a
        // new one: the side effect must not run twice.
        let repeated = Self.call("alpha", id: "same-id")
        let provider = ScriptedProvider(script: [
            .toolCallTurn([repeated]),
            .toolCallTurn([repeated]),
            .answerTurn("Done"),
        ])
        let ai = Arbiter(provider: provider)

        let result = try await ai.run(
            [.user("Go")], tools: [Self.tool("alpha", recorder: recorder)]
        )

        #expect(recorder.calls == ["alpha"])
        #expect(result.invocations.count == 2)
        #expect(result.invocations[1].wasDeduplicated)
        #expect(result.invocations[1].result.content == result.invocations[0].result.content)
    }

    @Test func theIdempotencyKeyIsStableForACallAndDiffersBetweenCalls() {
        let arguments = JSONValue.object(["city": .string("Paris")])
        let first = ToolIdempotency.key(callID: "c1", arguments: arguments)
        #expect(first == ToolIdempotency.key(callID: "c1", arguments: arguments))
        #expect(first != ToolIdempotency.key(callID: "c2", arguments: arguments))
        #expect(first != ToolIdempotency.key(
            callID: "c1", arguments: .object(["city": .string("Berlin")])
        ))
    }

    // MARK: - Streaming

    @Test func aStreamedRunReportsDeltasToolCallsAndResults() async throws {
        let recorder = CallRecorder()
        let provider = ScriptedProvider(script: [
            .toolCallTurn([Self.call("alpha", id: "c1")], text: "Let me check"),
            .answerTurn("The answer is here"),
        ])
        let ai = Arbiter(provider: provider)

        var deltas: [String] = []
        var started: [ToolCall] = []
        var results: [ToolResult] = []
        var rounds: [Int] = []
        var finished: RunResult?

        for try await event in ai.runStream(
            [.user("Go")], tools: [Self.tool("alpha", recorder: recorder)]
        ) {
            switch event {
            case .textDelta(let delta): deltas.append(delta)
            case .toolCallStarted(let call): started.append(call)
            case .toolResult(let result): results.append(result)
            case .roundCompleted(let index): rounds.append(index)
            case .finished(let result): finished = result
            case .approvalRequested: break
            }
        }

        #expect(deltas.joined().contains("Let me check"))
        #expect(deltas.joined().contains("The answer is here"))
        #expect(started.map(\.id) == ["c1"])
        #expect(results.map(\.toolCallId) == ["c1"])
        #expect(rounds == [0])
        let result = try #require(finished)
        #expect(result.rounds == 1)
        #expect(result.content == "The answer is here")
    }

    // MARK: - Apple Foundation Models

    @Test func theGenericLoopIsNotEnteredForAppleFoundationModels() async throws {
        let recorder = CallRecorder()
        // Apple runs its tools inside the session, then reports them on a `.complete`
        // response. A loop branching on `toolCalls` being non-empty would run them again.
        let provider = ScriptedProvider(
            id: .appleFoundation,
            script: [.answerTurn(
                "It is 20 degrees",
                provider: .appleFoundation,
                toolCalls: [Self.call("weather", id: "c1")],
                finishReason: .complete
            )]
        )
        let ai = Arbiter(provider: provider)

        let result = try await ai.run(
            [.user("Weather?")], tools: [Self.tool("weather", recorder: recorder)]
        )

        #expect(result.content == "It is 20 degrees")
        #expect(result.rounds == 0)
        #expect(provider.callCount == 1)
        // The loop executed nothing: whatever ran, ran inside the session.
        #expect(recorder.calls.isEmpty)
        #expect(result.invocations.isEmpty)
    }

    @Test func toolsReachAppleFoundationModelsAsBoundExecutors() async throws {
        let recorder = CallRecorder()
        let provider = ScriptedProvider(
            id: .appleFoundation,
            script: [.answerTurn("Done", provider: .appleFoundation)]
        )
        let ai = Arbiter(provider: provider)

        _ = try await ai.run([.user("Go")], tools: [Self.tool("weather", recorder: recorder)])

        let request = provider.requests[0]
        // Declared to the provider like any other, and bound to an executor it can run.
        #expect(request.tools?.map(\.name) == ["weather"])
        let fmOptions = try #require(request.providerOptions[.appleFoundation] as? AppleFMOptions)
        let binding = try #require(fmOptions.tools.first)
        #expect(binding.definition.name == "weather")

        // The binding runs through the same executor as the generic loop, so a tool called
        // on-device is subject to the same timeout, approval and reporting.
        let output = try await binding.execute(.object(["city": .string("Paris")]))
        #expect(output == "weather ran")
        #expect(recorder.calls == ["weather"])
    }

    @Test func aCallersOwnAppleOptionsSurviveAlongsideTheRunsTools() async throws {
        let recorder = CallRecorder()
        let provider = ScriptedProvider(
            id: .appleFoundation, script: [.answerTurn("Done", provider: .appleFoundation)]
        )
        let ai = Arbiter(provider: provider)
        let existing = AppleFMToolBinding(
            definition: ToolDefinition(
                name: "legacy", description: "Already bound", inputSchema: .object([:])
            ),
            execute: { _ in "legacy" }
        )
        let options = RequestOptions(providerOptions: [
            .appleFoundation: AppleFMOptions(conversationID: "chat-1", tools: [existing]),
        ])

        _ = try await ai.run(
            [.user("Go")], tools: [Self.tool("weather", recorder: recorder)], options: options
        )

        let fmOptions = try #require(
            provider.requests[0].providerOptions[.appleFoundation] as? AppleFMOptions
        )
        // The conversation is scoped to this run: a cached session keeps the executor
        // closures it was built with, and reusing one across runs would report the second
        // run's calls into the first run's log.
        let conversationID = try #require(fmOptions.conversationID)
        #expect(conversationID.hasPrefix("chat-1#arbiter-run-"))
        #expect(Set(fmOptions.tools.map(\.definition.name)) == ["legacy", "weather"])
    }

    @Test func aRunWithoutToolsLeavesTheCallersConversationAlone() async throws {
        let provider = ScriptedProvider(
            id: .appleFoundation, script: [.answerTurn("Hello", provider: .appleFoundation)]
        )
        let ai = Arbiter(provider: provider)
        let options = RequestOptions(providerOptions: [
            .appleFoundation: AppleFMOptions(conversationID: "chat-1"),
        ])

        _ = try await ai.run([.user("Hi")], tools: [], options: options)

        let fmOptions = try #require(
            provider.requests[0].providerOptions[.appleFoundation] as? AppleFMOptions
        )
        // Nothing was bound, so nothing is stale: the session — and Apple's KV cache —
        // can be reused across turns.
        #expect(fmOptions.conversationID == "chat-1")
    }

    @Test func aProviderReportingNoToolSupportIsPenalisedNotDisqualified() async throws {
        // Narrow claim: this passes because of the *one* configuration that rescues a
        // zeroed score, and pins that configuration rather than a general mechanism.
        // `CapabilityMatcher.score` zeroes the whole score — not just the capability
        // term — for a provider that reports `supportsToolCalling == false` on a request
        // carrying tools, and `SmartRouter.buildDecision` reports `.unavailable` for a
        // best score of 0. What saves this run is `applyComplexityAdjustments`, which
        // adds +15 to an `.onDevice`/`.system` provider — but only under `.smart`, only
        // when the device is not thermally constrained, and only for a trivial or simple
        // prompt, which is why the prompt here is "Go". Three other additive rescues
        // exist and none of them applies here: `applyTaskAdjustments` is behind the same
        // gate and keys on a `.structuredOutput` task this provider's `[.chat]` set does
        // not declare, `applyHealthAdjustments` needs a configured monitor, and
        // `applyPerformanceAdjustments` needs ten recorded requests. Change any of the
        // gate conditions and a cold, unmonitored lone Apple FM or MLX provider given
        // tools throws `allProvidersFailed`.
        // `filterByConstraints` has no tool filter, so nothing else removes it.
        let recorder = CallRecorder()
        let provider = ScriptedProvider(
            id: .appleFoundation,
            script: [.answerTurn("Answered anyway", provider: .appleFoundation)],
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat], maxContextTokens: 8_000,
                supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
                costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
                estimatedLatency: .fast, privacyLevel: .onDevice
            )
        )
        let ai = Arbiter {
            $0.system(provider)
            $0.routing(.smart)
        }

        let result = try await ai.run(
            [.user("Go")], tools: [Self.tool("weather", recorder: recorder)]
        )

        #expect(result.content == "Answered anyway")
    }
}

/// The loop turns conversations into `.mixed` turns, which the estimator used to value at a
/// flat 100 tokens each — and the budget guard and context-window check both read it.
@Suite("Tool loop accounting")
struct ToolLoopAccountingTests {
    @Test func aToolConversationIsNotValuedAtNothing() {
        let arguments = JSONValue.object(["city": .string("Tokyo"), "days": .number(5)])
        let call = ToolCall(id: "c1", name: "get_weather", arguments: arguments)
        let result = String(repeating: "Sunny and 24 degrees. ", count: 20)
        let messages = [
            Message.user("What is the weather in Tokyo?"),
            Message(role: .assistant, content: .mixed([
                .thinking([ThinkingBlock(text: String(repeating: "reasoning ", count: 30), signature: "s")]),
                .text("Let me check that."),
                .toolCalls([call]),
            ])),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "c1", name: "get_weather", content: result),
            ])),
        ]

        let estimate = TokenEstimator.estimateTokens(for: messages)
        // The assistant turn alone carries ~300 characters of thinking plus the call's JSON;
        // the old text-only reading scored it 100 for the whole turn.
        #expect(estimate > 200)

        let assistantText = TokenEstimator.billableText(of: messages[1].content)
        #expect(assistantText.contains("reasoning"))
        #expect(assistantText.contains("get_weather"))
        #expect(assistantText.contains("Tokyo"))
    }

    @Test func contentWithNoTextStillCountsSomething() {
        let messages = [Message(role: .user, content: .image(.base64(data: "AAAA", mimeType: "image/png")))]
        #expect(TokenEstimator.estimateTokens(for: messages) == 100)
    }
}
