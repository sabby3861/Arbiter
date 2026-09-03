// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

/// Replays the shapes the Messages API actually sends and expects: a
/// multi-round tool conversation, a streamed tool call, the advanced request
/// options, and the error statuses that carry retry information.
@Suite("Anthropic — tool history")
struct AnthropicToolHistoryTests {
    let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)

    /// A conversation that has already been through two tool rounds must
    /// replay as legal message JSON — this is the shape that used to 400.
    @Test func multiRoundToolConversationReplays() throws {
        let firstCalls = [
            ToolCall(id: "toolu_01", name: "get_weather", arguments: .object(["city": .string("Tokyo")])),
            ToolCall(id: "toolu_02", name: "get_time", arguments: .object(["tz": .string("JST")])),
        ]
        let request = AIRequest(messages: [
            .user("Weather and time in Tokyo?"),
            Message(role: .assistant, content: .mixed([
                .text("Checking both."),
                .toolCalls(firstCalls),
            ])),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "toolu_01", content: "Sunny, 24°C"),
                ToolResult(toolCallId: "toolu_02", content: "14:05"),
            ])),
            .assistant("It is sunny and 24°C at 14:05."),
            .user("And the forecast?"),
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "toolu_03", name: "get_forecast", arguments: .object(["days": .number(3)])),
            ])),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "toolu_03", content: "Rain Thursday"),
            ])),
        ])

        let json = try #require(try JSONSerialization.jsonObject(
            with: mapper.buildRequestBody(request, stream: false)
        ) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.map { $0["role"] as? String }
            == ["user", "assistant", "user", "assistant", "user", "assistant", "user"])

        // Round one: text block then both tool_use blocks, arguments as objects.
        let callBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(callBlocks.map { $0["type"] as? String } == ["text", "tool_use", "tool_use"])
        #expect(callBlocks[1]["id"] as? String == "toolu_01")
        #expect((callBlocks[1]["input"] as? [String: Any])?["city"] as? String == "Tokyo")

        // Both results ride one user turn.
        let resultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(resultBlocks.map { $0["type"] as? String } == ["tool_result", "tool_result"])
        #expect(resultBlocks.map { $0["tool_use_id"] as? String } == ["toolu_01", "toolu_02"])
        #expect(resultBlocks[0]["content"] as? String == "Sunny, 24°C")

        // Round two survives the round-one history intact.
        let secondCall = try #require(messages[5]["content"] as? [[String: Any]])
        #expect(secondCall[0]["id"] as? String == "toolu_03")
        let secondResult = try #require(messages[6]["content"] as? [[String: Any]])
        #expect(secondResult[0]["tool_use_id"] as? String == "toolu_03")
    }

    /// Results split across separate turns must still reach the API as one
    /// user message; splitting them is rejected.
    @Test func resultsFromSeparateTurnsMergeIntoOneUserMessage() throws {
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "toolu_a", name: "a", arguments: .object([:])),
                ToolCall(id: "toolu_b", name: "b", arguments: .object([:])),
            ])),
            Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "toolu_a", content: "A")])),
            Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "toolu_b", content: "B")])),
        ])

        let json = try #require(try JSONSerialization.jsonObject(
            with: mapper.buildRequestBody(request, stream: false)
        ) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.count == 2)
        let blocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(blocks.map { $0["tool_use_id"] as? String } == ["toolu_a", "toolu_b"])
    }

    /// A user comment after the results joins the same turn, behind them.
    @Test func trailingUserTextJoinsTheResultTurnAfterTheResults() throws {
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "toolu_a", name: "a", arguments: .object([:])),
            ])),
            Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "toolu_a", content: "A")])),
            .user("Thanks — now summarise."),
        ])

        let json = try #require(try JSONSerialization.jsonObject(
            with: mapper.buildRequestBody(request, stream: false)
        ) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.count == 2)
        let blocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["tool_result", "text"])
        #expect(blocks[1]["text"] as? String == "Thanks — now summarise.")
    }

    @Test func toolResultWithoutPrecedingCallIsRejected() throws {
        let request = AIRequest(messages: [
            .user("Hello"),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "toolu_missing", content: "orphan"),
            ])),
        ])

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    /// A result may only answer a call the model already made, so a result
    /// placed *before* its call in the same conversation is still rejected.
    @Test func toolResultBeforeItsCallIsRejected() throws {
        let request = AIRequest(messages: [
            Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "toolu_1", content: "early")])),
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "toolu_1", name: "a", arguments: .object([:])),
            ])),
        ])

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }
}

@Suite("Anthropic — streaming tool input")
struct AnthropicStreamingToolTests {
    let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)

    /// A recorded SSE turn: text, then a tool call whose arguments arrive as
    /// `input_json_delta` fragments, then the closing `message_delta`.
    static let toolUseStream = [
        #"{"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":472,"output_tokens":1,"cache_creation_input_tokens":118,"cache_read_input_tokens":2048}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me check."}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01A","name":"get_weather","input":{}}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"ci"}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"ty\": \"Tok"}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"yo\", \"days\": 3}"}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":57}}"#,
        #"{"type":"message_stop"}"#,
    ]

    private func replay(_ events: [String]) -> [AIStreamChunk] {
        var state = AnthropicStreamState()
        return events.compactMap { mapper.parseStreamEvent($0, state: &state) }
    }

    @Test func streamedToolCallSurfacesWithParsedArguments() throws {
        let chunks = replay(Self.toolUseStream)

        // Text delta, the completed tool call, and the final chunk.
        #expect(chunks.count == 3)
        #expect(chunks[0].delta == "Let me check.")

        let completed = try #require(chunks[1].toolCalls)
        #expect(completed.count == 1)
        #expect(completed[0].id == "toolu_01A")
        #expect(completed[0].name == "get_weather")
        #expect(completed[0].arguments == .object(["city": .string("Tokyo"), "days": .number(3)]))
        #expect(chunks[1].isComplete == false)
    }

    @Test func finalChunkCarriesFinishReasonAndEveryCall() throws {
        let final = try #require(replay(Self.toolUseStream).last)

        #expect(final.isComplete)
        #expect(final.finishReason == .toolCall)
        #expect(final.toolCalls?.map(\.id) == ["toolu_01A"])
        #expect(final.accumulatedContent == "Let me check.")
        #expect(final.usage?.inputTokens == 472)
        #expect(final.usage?.outputTokens == 57)
        #expect(final.usage?.cacheCreationInputTokens == 118)
        #expect(final.usage?.cacheReadInputTokens == 2048)
    }

    @Test func parallelStreamedToolCallsAllSurface() throws {
        let events = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"a","input":{}}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_2","name":"b","input":{}}}"#,
            // Anthropic interleaves fragments for concurrent blocks by index.
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"x\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"y\":"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"1}"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"2}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}"#,
        ]
        let final = try #require(replay(events).last)

        #expect(final.toolCalls?.count == 2)
        #expect(final.toolCalls?[0].arguments == .object(["x": .number(1)]))
        #expect(final.toolCalls?[1].arguments == .object(["y": .number(2)]))
    }

    /// A tool taking no arguments streams no fragments at all.
    @Test func toolCallWithNoStreamedArgumentsYieldsEmptyObject() throws {
        let events = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"ping","input":{}}}"#,
            #"{"type":"content_block_stop","index":0}"#,
        ]
        let call = try #require(replay(events).first?.toolCalls?.first)

        #expect(call.name == "ping")
        #expect(call.arguments == .object([:]))
    }

    /// Thinking deltas are not answer text and must not pollute the content.
    @Test func thinkingDeltasDoNotAppearInStreamedText() throws {
        let events = [
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"weighing options"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer"}}"#,
        ]
        let chunks = replay(events)

        #expect(chunks.count == 1)
        #expect(chunks[0].accumulatedContent == "Answer")
    }

    @Test func closingTextBlockDoesNotEmitAToolCall() {
        let events = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_stop","index":0}"#,
        ]
        #expect(replay(events).isEmpty)
    }
}

@Suite("Anthropic — stop reasons")
struct AnthropicStopReasonTests {
    let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)

    private func response(stopReason: String) throws -> AIResponse {
        let json: [String: Any] = [
            "id": "msg_1",
            "role": "assistant",
            "model": "claude-sonnet-5",
            "content": [["type": "text", "text": "hi"]],
            "stop_reason": stopReason,
            "usage": ["input_tokens": 1, "output_tokens": 1],
        ]
        return try mapper.parseResponse(try JSONSerialization.data(withJSONObject: json))
    }

    @Test(arguments: [
        ("end_turn", FinishReason.complete),
        ("max_tokens", .maxTokens),
        ("stop_sequence", .stopSequence),
        ("tool_use", .toolCall),
        ("refusal", .refusal),
        ("pause_turn", .pauseTurn),
    ])
    func stopReasonMapsToFinishReason(rawValue: String, expected: FinishReason) throws {
        #expect(try response(stopReason: rawValue).finishReason == expected)
    }

    @Test func unknownStopReasonIsNil() throws {
        #expect(try response(stopReason: "something_new").finishReason == nil)
    }
}

@Suite("Anthropic — advanced request options")
struct AnthropicOptionTests {
    let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)

    private func body(_ request: AIRequest) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(
            with: mapper.buildRequestBody(request, stream: false)
        ) as? [String: Any])
    }

    @Test func adaptiveThinkingIsSentForCurrentModels() throws {
        let request = AIRequest.chat("Think it through")
            .withProviderOptions(AnthropicOptions.adaptiveThinking(), for: .anthropic)

        let thinking = try #require(try body(request)["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["budget_tokens"] == nil)
    }

    /// A fixed budget is a 400 on models that only take adaptive thinking, so
    /// it is rejected before the request leaves the process.
    @Test func thinkingBudgetIsRejectedOnAdaptiveOnlyModels() {
        let request = AIRequest.chat("Think")
            .withMaxTokens(8192)
            .withProviderOptions(AnthropicOptions.extendedThinking(budgetTokens: 4096), for: .anthropic)

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    @Test func thinkingBudgetIsSentForModelsThatTakeOne() throws {
        let request = AIRequest.chat("Think")
            .withModel(AnthropicModel.claudeHaiku45.rawValue)
            .withMaxTokens(8192)
            .withProviderOptions(AnthropicOptions.extendedThinking(budgetTokens: 4096), for: .anthropic)

        let thinking = try #require(try body(request)["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == 4096)
    }

    @Test func adaptiveThinkingIsRejectedOnBudgetOnlyModels() {
        let request = AIRequest.chat("Think")
            .withModel(AnthropicModel.claudeHaiku45.rawValue)
            .withProviderOptions(AnthropicOptions.adaptiveThinking(), for: .anthropic)

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    @Test func thinkingBudgetMustFitInsideMaxTokens() {
        let request = AIRequest.chat("Think")
            .withModel(AnthropicModel.claudeHaiku45.rawValue)
            .withMaxTokens(2048)
            .withProviderOptions(AnthropicOptions.extendedThinking(budgetTokens: 4096), for: .anthropic)

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    @Test func thinkingBudgetBelowTheMinimumIsRejected() {
        let request = AIRequest.chat("Think")
            .withModel(AnthropicModel.claudeHaiku45.rawValue)
            .withMaxTokens(8192)
            .withProviderOptions(AnthropicOptions.extendedThinking(budgetTokens: 512), for: .anthropic)

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    /// Sampling parameters are a 400 on current models, so they are dropped
    /// rather than sent.
    @Test func samplingParametersAreDroppedForModelsThatRejectThem() throws {
        let request = AIRequest.chat("Hello")
            .withTemperature(0.9)
            .withTopP(0.95)

        let json = try body(request)
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
    }

    @Test func samplingParametersSurviveForModelsThatAcceptThem() throws {
        let request = AIRequest.chat("Hello")
            .withModel(AnthropicModel.claudeHaiku45.rawValue)
            .withTemperature(0.9)

        #expect(try body(request)["temperature"] as? Double == 0.9)
    }

    /// An unrecognised model (a proxy alias, a preview) gets no per-model
    /// rules applied — the caller's values pass through.
    @Test func unknownModelKeepsCallerSuppliedSamplingParameters() throws {
        let request = AIRequest.chat("Hello")
            .withModel("some-proxy/claude-next")
            .withTemperature(0.5)

        #expect(try body(request)["temperature"] as? Double == 0.5)
    }

    @Test func promptCachingMarksSystemAndRecentMessages() throws {
        let request = AIRequest(
            messages: [.user("One"), .assistant("Two"), .user("Three")],
            systemPrompt: "You are helpful",
            providerOptions: [.anthropic: AnthropicOptions.promptCaching(breakpoints: 3)]
        )

        let json = try body(request)

        // A cached system prompt has to be sent in block form.
        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system[0]["text"] as? String == "You are helpful")
        #expect(system[0]["cache_control"] as? [String: String] == ["type": "ephemeral"])

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "One")
        for index in [1, 2] {
            let blocks = try #require(messages[index]["content"] as? [[String: Any]])
            #expect(blocks.last?["cache_control"] as? [String: String] == ["type": "ephemeral"])
        }
    }

    @Test func promptCachingMarksTheToolListFirst() throws {
        let tools = [
            ToolDefinition(name: "a", description: "A", inputSchema: .object([:])),
            ToolDefinition(name: "b", description: "B", inputSchema: .object([:])),
        ]
        let request = AIRequest(
            messages: [.user("Hi")],
            tools: tools,
            providerOptions: [.anthropic: AnthropicOptions.promptCaching(breakpoints: 1)]
        )

        let json = try body(request)
        let toolsJSON = try #require(json["tools"] as? [[String: Any]])

        #expect(toolsJSON[0]["cache_control"] == nil)
        #expect(toolsJSON[1]["cache_control"] as? [String: String] == ["type": "ephemeral"])
        // The single breakpoint was spent on the tools, so nothing else is marked.
        #expect(json["system"] == nil)
        #expect((json["messages"] as? [[String: Any]])?[0]["content"] as? String == "Hi")
    }

    @Test func promptCachingNeverExceedsFourBreakpoints() throws {
        let request = AIRequest(
            messages: (1...8).map { .user("Message \($0)") },
            systemPrompt: "System",
            tools: [ToolDefinition(name: "a", description: "A", inputSchema: .object([:]))],
            providerOptions: [.anthropic: AnthropicOptions.promptCaching(breakpoints: 99)]
        )

        let json = try body(request)
        let marked = try countCacheControls(in: json)
        #expect(marked == AnthropicPromptCaching.maxBreakpoints)
    }

    @Test func noCachingLeavesTheSystemPromptAsAString() throws {
        let request = AIRequest(messages: [.user("Hi")], systemPrompt: "You are helpful")
        #expect(try body(request)["system"] as? String == "You are helpful")
    }

    /// Options addressed to another provider must not leak into the body.
    @Test func otherProvidersOptionsAreIgnored() throws {
        let request = AIRequest(
            messages: [.user("Hi")],
            providerOptions: [.openAI: AnthropicOptions.adaptiveThinking()]
        )
        #expect(try body(request)["thinking"] == nil)
    }

    @Test func documentContentIsSentAsABase64DocumentBlock() throws {
        let document = DocumentSource(
            base64: "JVBERi0xLjQK",
            title: "Q3 report",
            enableCitations: true
        )
        let request = AIRequest(messages: [
            Message(role: .user, content: .mixed([.document(document), .text("Summarise this.")])),
        ])

        let messages = try #require(try body(request)["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])

        #expect(blocks.map { $0["type"] as? String } == ["document", "text"])
        let source = try #require(blocks[0]["source"] as? [String: String])
        #expect(source["type"] == "base64")
        #expect(source["media_type"] == "application/pdf")
        #expect(source["data"] == "JVBERi0xLjQK")
        #expect(blocks[0]["title"] as? String == "Q3 report")
        #expect((blocks[0]["citations"] as? [String: Bool])?["enabled"] == true)
    }

    @Test func documentCitationsAreOffUnlessRequested() throws {
        let request = AIRequest(messages: [
            Message(role: .user, content: .document(DocumentSource(base64: "AAAA"))),
        ])

        let messages = try #require(try body(request)["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(blocks[0]["citations"] == nil)
    }

    private func countCacheControls(in json: [String: Any]) throws -> Int {
        var count = 0
        for tool in json["tools"] as? [[String: Any]] ?? [] where tool["cache_control"] != nil {
            count += 1
        }
        for block in json["system"] as? [[String: Any]] ?? [] where block["cache_control"] != nil {
            count += 1
        }
        for message in json["messages"] as? [[String: Any]] ?? [] {
            for block in message["content"] as? [[String: Any]] ?? [] where block["cache_control"] != nil {
                count += 1
            }
        }
        return count
    }
}

@Suite("Anthropic — response parsing")
struct AnthropicResponseParsingTests {
    let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)

    @Test func thinkingBlocksSurfaceAsReasoning() throws {
        let json: [String: Any] = [
            "id": "msg_1",
            "model": "claude-sonnet-5",
            "content": [
                ["type": "thinking", "thinking": "The user wants a sum.", "signature": "sig"],
                ["type": "text", "text": "4"],
            ],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 10, "output_tokens": 2],
        ]
        let response = try mapper.parseResponse(try JSONSerialization.data(withJSONObject: json))

        #expect(response.reasoning == "The user wants a sum.")
        #expect(response.content == "4")
    }

    @Test func responseWithoutThinkingHasNoReasoning() throws {
        let json: [String: Any] = [
            "id": "msg_1",
            "model": "claude-sonnet-5",
            "content": [["type": "text", "text": "Hi"]],
            "usage": ["input_tokens": 1, "output_tokens": 1],
        ]
        let response = try mapper.parseResponse(try JSONSerialization.data(withJSONObject: json))
        #expect(response.reasoning == nil)
    }

    @Test func citationBlocksAreParsed() throws {
        let json: [String: Any] = [
            "id": "msg_1",
            "model": "claude-sonnet-5",
            "content": [
                [
                    "type": "text",
                    "text": "Revenue rose 12%.",
                    "citations": [
                        [
                            "type": "char_location",
                            "cited_text": "revenue increased 12 percent",
                            "document_index": 0,
                            "document_title": "Q3 report",
                            "start_char_index": 104,
                            "end_char_index": 132,
                        ],
                        [
                            "type": "page_location",
                            "cited_text": "see chart",
                            "document_index": 1,
                            "start_page_number": 4,
                            "end_page_number": 5,
                        ],
                    ],
                ],
            ],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 10, "output_tokens": 5],
        ]
        let response = try mapper.parseResponse(try JSONSerialization.data(withJSONObject: json))

        #expect(response.citations.count == 2)
        #expect(response.citations[0].citedText == "revenue increased 12 percent")
        #expect(response.citations[0].title == "Q3 report")
        #expect(response.citations[0].documentIndex == 0)
        #expect(response.citations[0].startIndex == 104)
        #expect(response.citations[0].endIndex == 132)
        #expect(response.citations[1].startIndex == 4)
        #expect(response.citations[1].endIndex == 5)
    }

    @Test func cacheTokenCountsAreParsed() throws {
        let json: [String: Any] = [
            "id": "msg_1",
            "model": "claude-sonnet-5",
            "content": [["type": "text", "text": "Hi"]],
            "usage": [
                "input_tokens": 12,
                "output_tokens": 4,
                "cache_creation_input_tokens": 1024,
                "cache_read_input_tokens": 8192,
            ],
        ]
        let usage = try #require(
            try mapper.parseResponse(try JSONSerialization.data(withJSONObject: json)).usage
        )

        #expect(usage.inputTokens == 12)
        #expect(usage.cacheCreationInputTokens == 1024)
        #expect(usage.cacheReadInputTokens == 8192)
        // Cache tokens bill separately, so they stay out of the plain total.
        #expect(usage.totalTokens == 16)
    }

    @Test func absentCacheCountsStayNil() throws {
        let json: [String: Any] = [
            "id": "msg_1",
            "model": "claude-sonnet-5",
            "content": [["type": "text", "text": "Hi"]],
            "usage": ["input_tokens": 12, "output_tokens": 4],
        ]
        let usage = try #require(
            try mapper.parseResponse(try JSONSerialization.data(withJSONObject: json)).usage
        )

        #expect(usage.cacheCreationInputTokens == nil)
        #expect(usage.cacheReadInputTokens == nil)
    }
}

@Suite("Anthropic — HTTP errors")
struct AnthropicHTTPErrorTests {
    let provider = AnthropicProvider(resolvedKey: "test-key", baseURL: nil, defaultModel: .claudeSonnet5)

    @Test func retryAfterSecondsBecomeTheRetryDelay() throws {
        let error = provider.mapHTTPError(
            statusCode: 429, retryAfterHeader: "30", body: #"{"error":{"message":"slow down"}}"#
        )

        guard case .rateLimited(let id, let retryAfter) = error else {
            Issue.record("Expected rateLimited, got \(error)")
            return
        }
        #expect(id == .anthropic)
        #expect(retryAfter == .seconds(30))
    }

    @Test func missingRetryAfterLeavesTheDelayUnset() throws {
        let error = provider.mapHTTPError(statusCode: 429, retryAfterHeader: nil, body: "")

        guard case .rateLimited(_, let retryAfter) = error else {
            Issue.record("Expected rateLimited, got \(error)")
            return
        }
        #expect(retryAfter == nil)
    }

    @Test func unparseableRetryAfterLeavesTheDelayUnset() {
        let error = provider.mapHTTPError(statusCode: 429, retryAfterHeader: "soon", body: "")

        guard case .rateLimited(_, let retryAfter) = error else {
            Issue.record("Expected rateLimited, got \(error)")
            return
        }
        #expect(retryAfter == nil)
    }

    @Test func httpDateRetryAfterBecomesADelay() throws {
        let future = Date().addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        let error = provider.mapHTTPError(
            statusCode: 429, retryAfterHeader: formatter.string(from: future), body: ""
        )

        guard case .rateLimited(_, let retryAfter) = error else {
            Issue.record("Expected rateLimited, got \(error)")
            return
        }
        let delay = try #require(retryAfter)
        #expect(delay > Duration.seconds(100) && delay <= Duration.seconds(120))
    }

    @Test func overloadedStatusMapsToARetryableError() {
        let error = provider.mapHTTPError(statusCode: 529, retryAfterHeader: nil, body: "overloaded")

        guard case .overloaded(let id) = error else {
            Issue.record("Expected overloaded, got \(error)")
            return
        }
        #expect(id == .anthropic)
        #expect(RetryEngine(maxRetries: 1).isRetryable(error))
    }

    @Test func otherServerErrorsStayHTTPErrors() {
        let error = provider.mapHTTPError(statusCode: 503, retryAfterHeader: nil, body: "unavailable")

        guard case .httpError(let statusCode, _) = error else {
            Issue.record("Expected httpError, got \(error)")
            return
        }
        #expect(statusCode == 503)
    }
}

@Suite("Anthropic — URL image resolution")
struct AnthropicImageResolverTests {
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])

    @Test func urlImagesAreDownloadedAndInlined() async throws {
        let resolver = AnthropicImageResolver { _ in (Self.pngBytes, "image/png") }
        let request = AIRequest(messages: [
            Message(role: .user, content: .image(.url(URL(string: "https://example.com/cat.png")!))),
        ])

        let resolved = try await resolver.resolvingImages(in: request)

        guard case .image(.base64(let data, let mimeType)) = resolved.messages[0].content else {
            Issue.record("Expected inline base64 image")
            return
        }
        #expect(data == Self.pngBytes.base64EncodedString())
        #expect(mimeType == "image/png")
        // Identity is preserved so the caller's message still matches up.
        #expect(resolved.messages[0].id == request.messages[0].id)
    }

    @Test func nestedURLImagesAreResolved() async throws {
        let resolver = AnthropicImageResolver { _ in (Self.pngBytes, "image/png") }
        let request = AIRequest(messages: [
            Message(role: .user, content: .mixed([
                .text("What is this?"),
                .image(.url(URL(string: "https://example.com/cat.png")!)),
            ])),
        ])

        let resolved = try await resolver.resolvingImages(in: request)

        guard case .mixed(let parts) = resolved.messages[0].content,
              case .image(.base64) = parts[1] else {
            Issue.record("Expected the nested image to be inlined")
            return
        }
    }

    @Test func oversizedImagesAreRejected() async {
        let resolver = AnthropicImageResolver(maxBytes: 8) { _ in
            (Data(repeating: 0, count: 9), "image/png")
        }
        let request = AIRequest(messages: [
            Message(role: .user, content: .image(.url(URL(string: "https://example.com/big.png")!))),
        ])

        await #expect(throws: ArbiterError.self) {
            try await resolver.resolvingImages(in: request)
        }
    }

    @Test func unsupportedMediaTypesAreRejected() async {
        let resolver = AnthropicImageResolver { _ in (Self.pngBytes, "image/tiff") }
        let request = AIRequest(messages: [
            Message(role: .user, content: .image(.url(URL(string: "https://example.com/x.tiff")!))),
        ])

        await #expect(throws: ArbiterError.self) {
            try await resolver.resolvingImages(in: request)
        }
    }

    /// A request with nothing to fetch must not touch the network.
    @Test func requestsWithoutURLImagesAreLeftAlone() async throws {
        let resolver = AnthropicImageResolver { _ in
            Issue.record("Should not download anything")
            return (Data(), nil)
        }
        let request = AIRequest(messages: [.user("Hello")])

        let resolved = try await resolver.resolvingImages(in: request)
        #expect(resolved.messages[0].content.text == "Hello")
    }

    @Test func inlinedImagesReachTheRequestBody() async throws {
        let resolver = AnthropicImageResolver { _ in (Self.pngBytes, "image/png") }
        let request = AIRequest(messages: [
            Message(role: .user, content: .image(.url(URL(string: "https://example.com/cat.png")!))),
        ])

        let resolved = try await resolver.resolvingImages(in: request)
        let data = try AnthropicMapper(defaultModel: .claudeSonnet5)
            .buildRequestBody(resolved, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])

        #expect(blocks[0]["type"] as? String == "image")
        #expect((blocks[0]["source"] as? [String: String])?["media_type"] == "image/png")
    }
}

@Suite("Anthropic — model catalogue")
struct AnthropicModelCatalogueTests {
    /// Current-generation IDs are pinned snapshots without a date suffix;
    /// appending one names a model that does not exist.
    @Test func currentModelIdentifiersCarryNoDateSuffix() {
        for model in [AnthropicModel.claudeSonnet5, .claudeOpus5, .claudeFable51] {
            #expect(model.rawValue.range(of: #"-\d{8}$"#, options: .regularExpression) == nil)
        }
    }

    @Test func contextWindowsAndOutputCapsDifferPerModel() {
        #expect(AnthropicModel.claudeSonnet5.contextWindow == 1_000_000)
        #expect(AnthropicModel.claudeOpus5.contextWindow == 1_000_000)
        #expect(AnthropicModel.claudeFable51.contextWindow == 1_000_000)
        #expect(AnthropicModel.claudeHaiku45.contextWindow == 200_000)

        #expect(AnthropicModel.claudeSonnet5.maxOutputTokens == 128_000)
        #expect(AnthropicModel.claudeHaiku45.maxOutputTokens == 64_000)
    }

    @Test func retiredModelIdentifierIsNotOffered() {
        #expect(AnthropicModel(rawValue: "claude-opus-4-20250918") == nil)
    }

    @Test func thinkingSupportDiffersPerModel() {
        #expect(AnthropicModel.claudeFable51.thinkingSupport == .alwaysOnAdaptive)
        #expect(AnthropicModel.claudeSonnet5.thinkingSupport == .adaptive)
        #expect(AnthropicModel.claudeHaiku45.thinkingSupport == .extended)
    }

    @Test func providerAdvertisesTheDefaultModelsWindowAndPrice() {
        let provider = AnthropicProvider(resolvedKey: "test-key", baseURL: nil, defaultModel: .claudeOpus5)

        #expect(provider.capabilities.maxContextTokens == 1_000_000)
        #expect(provider.capabilities.costPerMillionInputTokens == 5.0)
        #expect(provider.capabilities.costPerMillionOutputTokens == 25.0)
    }

    /// The models Anthropic still lists as Active while marking them legacy.
    /// Before this, a caller pinning one of them silently got the *default*
    /// model's window and price, because `named` returned `nil`.
    @Test func legacyButActiveModelsResolveWithTheirOwnSpecs() {
        let legacy: [(String, Int, Int?, Double, Double)] = [
            ("claude-fable-5", 1_000_000, 128_000, 10.0, 50.0),
            ("claude-opus-4-8", 1_000_000, 128_000, 5.0, 25.0),
            ("claude-opus-4-7", 1_000_000, 128_000, 5.0, 25.0),
            ("claude-opus-4-6", 1_000_000, 128_000, 5.0, 25.0),
            ("claude-opus-4-5-20251101", 200_000, 64_000, 5.0, 25.0),
            ("claude-sonnet-4-6", 1_000_000, 128_000, 3.0, 15.0),
            ("claude-sonnet-4-5-20250929", 200_000, 64_000, 3.0, 15.0),
        ]
        for (id, window, output, input, outputPrice) in legacy {
            guard let model = AnthropicModel.named(id) else {
                Issue.record("\(id) is not in the catalogue")
                continue
            }
            #expect(model.contextWindow == window, "\(id) context window")
            #expect(model.maxOutputTokens == output, "\(id) output cap")
            #expect(model.costPerMillionInput == input, "\(id) input price")
            #expect(model.costPerMillionOutput == outputPrice, "\(id) output price")
            #expect(model.isLegacy, "\(id) legacy flag")
        }
    }

    /// Extended thinking is deprecated on the 4.6 generation and not accepted
    /// after it, so those models take an adaptive configuration; 4.5 still
    /// takes a `budget_tokens`.
    @Test func legacyModelsThinkingAndSamplingMatchTheirGeneration() {
        #expect(AnthropicModel.claudeFable5.thinkingSupport == .alwaysOnAdaptive)
        #expect(AnthropicModel.claudeOpus48.thinkingSupport == .adaptive)
        // 4.6 is the crossover generation: adaptive is documented, a budget is
        // deprecated but still served.
        #expect(AnthropicModel.claudeOpus46.thinkingSupport == .adaptiveOrExtended)
        #expect(AnthropicModel.claudeSonnet46.thinkingSupport == .adaptiveOrExtended)
        #expect(AnthropicModel.claudeOpus45.thinkingSupport == .extended)
        #expect(AnthropicModel.claudeSonnet45.thinkingSupport == .extended)

        // Sampling parameters are a 400 from Opus 4.7 on, and accepted before it.
        #expect(AnthropicModel.claudeOpus47.supportsSamplingControls == false)
        #expect(AnthropicModel.claudeFable5.supportsSamplingControls == false)
        #expect(AnthropicModel.claudeOpus46.supportsSamplingControls == true)
        #expect(AnthropicModel.claudeSonnet46.supportsSamplingControls == true)
        #expect(AnthropicModel.claudeSonnet45.supportsSamplingControls == true)
    }

    /// Adding the 4.6 models to the catalogue must not make Arbiter refuse a call
    /// the API serves: before they were listed, `named` returned `nil` and a budget
    /// passed through unvalidated, so classifying them adaptive-only would have been
    /// a regression dressed as a correction.
    @Test func theCrossoverGenerationAcceptsBothThinkingForms() throws {
        let mapper = AnthropicMapper(defaultModel: .claudeOpus46)
        for model in [AnthropicModel.claudeOpus46, .claudeSonnet46] {
            let adaptive = try mapper.thinkingModeJSON(.adaptive, model: model, maxTokens: 8_000)
            #expect(adaptive["type"] as? String == "adaptive", "\(model.rawValue) adaptive")

            let budgeted = try mapper.thinkingModeJSON(
                .extended(budgetTokens: 4_000), model: model, maxTokens: 8_000
            )
            #expect(budgeted["type"] as? String == "enabled", "\(model.rawValue) budget type")
            #expect(budgeted["budget_tokens"] as? Int == 4_000, "\(model.rawValue) budget value")
        }

        // The neighbouring generations still refuse the form they do not take.
        #expect(throws: ArbiterError.self) {
            try mapper.thinkingModeJSON(
                .extended(budgetTokens: 4_000), model: .claudeOpus47, maxTokens: 8_000
            )
        }
        #expect(throws: ArbiterError.self) {
            try mapper.thinkingModeJSON(.adaptive, model: .claudeOpus45, maxTokens: 8_000)
        }
    }

    @Test func everyOfferedModelIsCallableAndTheRetiredOneIsNot() {
        #expect(AnthropicModel.allCases.count == 11)
        #expect(!AnthropicModel.allCases.contains { $0.rawValue == "claude-sonnet-4-20250514" })
        for model in AnthropicModel.allCases {
            #expect(AnthropicModel.named(model.rawValue) == model)
        }
    }
}

@Suite("Anthropic — review follow-ups")
struct AnthropicRequestGuardTests {
    let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)

    private func body(_ request: AIRequest) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(
            with: mapper.buildRequestBody(request, stream: false)
        ) as? [String: Any])
    }

    /// Current models omit the thinking text by default, so the caller has to
    /// ask for it or `AIResponse.reasoning` is always nil.
    @Test func thinkingDisplayIsSentWhenRequested() throws {
        let request = AIRequest.chat("Think")
            .withProviderOptions(AnthropicOptions.adaptiveThinking(display: .summarized), for: .anthropic)

        let thinking = try #require(try body(request)["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] as? String == "summarized")
    }

    @Test func thinkingDisplayIsOmittedUnlessAskedFor() throws {
        let request = AIRequest.chat("Think")
            .withProviderOptions(AnthropicOptions.adaptiveThinking(), for: .anthropic)

        let thinking = try #require(try body(request)["thinking"] as? [String: Any])
        #expect(thinking["display"] == nil)
    }

    /// Sampling controls are incompatible with thinking even on models that
    /// otherwise accept them, so sending both is a guaranteed 400.
    @Test func temperatureIsDroppedWhenThinkingIsOn() throws {
        let request = AIRequest.chat("Think")
            .withModel(AnthropicModel.claudeHaiku45.rawValue)
            .withMaxTokens(8192)
            .withTemperature(0.7)
            .withProviderOptions(AnthropicOptions.extendedThinking(budgetTokens: 4096), for: .anthropic)

        let json = try body(request)
        #expect(json["temperature"] == nil)
        #expect(json["thinking"] != nil)
    }

    @Test func topPOutsideTheThinkingRangeIsDropped() throws {
        func topP(_ value: Double) throws -> Double? {
            let request = AIRequest.chat("Think")
                .withModel(AnthropicModel.claudeHaiku45.rawValue)
                .withMaxTokens(8192)
                .withTopP(value)
                .withProviderOptions(AnthropicOptions.extendedThinking(budgetTokens: 4096), for: .anthropic)
            return try body(request)["top_p"] as? Double
        }

        #expect(try topP(0.5) == nil)
        #expect(try topP(0.96) == 0.96)
    }

    @Test func maxTokensAboveTheModelCapIsRejected() {
        let request = AIRequest.chat("Write a book")
            .withModel(AnthropicModel.claudeHaiku45.rawValue)
            .withMaxTokens(120_000)

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    @Test func maxTokensAtTheModelCapIsAccepted() throws {
        let request = AIRequest.chat("Write a book")
            .withModel(AnthropicModel.claudeSonnet5.rawValue)
            .withMaxTokens(128_000)

        #expect(try body(request)["max_tokens"] as? Int == 128_000)
    }

    /// Citations are all-or-none across a request's documents.
    @Test func mixedDocumentCitationSettingsAreRejected() {
        let request = AIRequest(messages: [
            Message(role: .user, content: .mixed([
                .document(DocumentSource(base64: "AAAA", enableCitations: true)),
                .document(DocumentSource(base64: "BBBB", enableCitations: false)),
            ])),
        ])

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    @Test func uniformDocumentCitationSettingsAreAccepted() throws {
        let request = AIRequest(messages: [
            Message(role: .user, content: .mixed([
                .document(DocumentSource(base64: "AAAA", enableCitations: true)),
                .document(DocumentSource(base64: "BBBB", enableCitations: true)),
            ])),
        ])

        let messages = try #require(try body(request)["messages"] as? [[String: Any]])
        #expect((messages[0]["content"] as? [[String: Any]])?.count == 2)
    }

    /// Results for one assistant turn must all arrive in the turn that follows
    /// it; a partially answered turn is rejected rather than sent.
    @Test func partiallyAnsweredToolTurnIsRejected() {
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "toolu_a", name: "a", arguments: .object([:])),
                ToolCall(id: "toolu_b", name: "b", arguments: .object([:])),
            ])),
            Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "toolu_a", content: "A")])),
            .assistant("Moving on."),
        ])

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    /// An assistant turn wedged between a call and the rest of its results
    /// breaks the merge, so it is caught instead of producing invalid JSON.
    @Test func resultsSeparatedByAnotherTurnAreRejected() {
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "toolu_a", name: "a", arguments: .object([:])),
                ToolCall(id: "toolu_b", name: "b", arguments: .object([:])),
            ])),
            Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "toolu_a", content: "A")])),
            .assistant("Thinking out loud."),
            Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "toolu_b", content: "B")])),
        ])

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    /// A turn whose results have not been produced yet is legitimate.
    @Test func trailingUnansweredToolTurnIsAllowed() throws {
        let request = AIRequest(messages: [
            .user("Weather?"),
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "toolu_a", name: "a", arguments: .object([:])),
            ])),
        ])

        #expect(try (body(request)["messages"] as? [[String: Any]])?.count == 2)
    }

    @Test func nonHTTPImageURLsAreRejected() async {
        let resolver = AnthropicImageResolver { _ in
            Issue.record("A file URL must never be fetched")
            return (Data(), nil)
        }
        let request = AIRequest(messages: [
            Message(role: .user, content: .image(.url(URL(string: "file:///etc/passwd")!))),
        ])

        await #expect(throws: ArbiterError.self) {
            try await resolver.resolvingImages(in: request)
        }
    }

    @Test func zeroRetryAfterMeansRetryImmediately() {
        let provider = AnthropicProvider(resolvedKey: "k", baseURL: nil, defaultModel: .claudeSonnet5)
        let error = provider.mapHTTPError(statusCode: 429, retryAfterHeader: "0", body: "")

        guard case .rateLimited(_, let retryAfter) = error else {
            Issue.record("Expected rateLimited, got \(error)")
            return
        }
        #expect(retryAfter == .zero)
    }
}

@Suite("Anthropic — cached token accounting")
struct CachedTokenAccountingTests {
    /// Cache writes and reads are billed on top of `input_tokens`, so a
    /// cache-heavy request must not look free to the budget guard.
    @Test func cacheTokensArePricedIntoTheCostEstimate() {
        let plain = TokenUsage(inputTokens: 1_000, outputTokens: 0)
        let cached = TokenUsage(
            inputTokens: 1_000,
            outputTokens: 0,
            cacheCreationInputTokens: 1_000_000,
            cacheReadInputTokens: 1_000_000
        )

        let plainCost = plain.cost(inputPerMillion: 3.0, outputPerMillion: 15.0)
        let cachedCost = cached.cost(inputPerMillion: 3.0, outputPerMillion: 15.0)

        #expect(cachedCost > plainCost)
        // One million written at 1.25x plus one million read at 0.1x of $3.
        #expect(abs(cachedCost - plainCost - 3.0 * 1.35) < 0.0001)
    }

    @Test func billedInputTokensIncludeCachedTokens() {
        let usage = TokenUsage(
            inputTokens: 10,
            outputTokens: 5,
            cacheCreationInputTokens: 100,
            cacheReadInputTokens: 1_000
        )

        #expect(usage.totalTokens == 15)
        #expect(usage.billedInputTokens == 1_110)
    }
}
