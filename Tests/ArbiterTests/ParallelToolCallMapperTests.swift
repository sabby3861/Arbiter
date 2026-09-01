// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

/// One assistant turn issuing three parallel tool calls, followed by the turn
/// carrying all three results — replayed through every provider mapper.
private enum ToolTurnFixture {
    static let calls = [
        ToolCall(id: "call_weather", name: "get_weather", arguments: .object(["city": .string("Tokyo")])),
        ToolCall(id: "call_time", name: "get_time", arguments: .object(["tz": .string("JST")])),
        ToolCall(
            id: "call_stock",
            name: "get_stock",
            arguments: .object(["ticker": .string("AAPL"), "days": .number(5)])
        ),
    ]

    static let results = [
        ToolResult(toolCallId: "call_weather", name: "get_weather", content: "Sunny, 24°C"),
        ToolResult(toolCallId: "call_time", name: "get_time", content: "14:05"),
        ToolResult(toolCallId: "call_stock", name: "get_stock", content: "232.10"),
    ]

    static var request: AIRequest {
        AIRequest(messages: [
            .user("Weather, time and AAPL please"),
            Message(role: .assistant, content: .toolCalls(calls)),
            Message(role: .tool, content: .toolResults(results)),
        ])
    }
}

@Suite("Parallel tool calls — Anthropic")
struct AnthropicParallelToolCallTests {
    let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)

    @Test func assistantTurnEmitsOneToolUseBlockPerCall() throws {
        let data = try mapper.buildRequestBody(ToolTurnFixture.request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.count == 3)
        #expect(messages[1]["role"] as? String == "assistant")

        let blocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(blocks.count == 3)
        #expect(blocks.map { $0["type"] as? String } == ["tool_use", "tool_use", "tool_use"])
        #expect(blocks.map { $0["id"] as? String } == ["call_weather", "call_time", "call_stock"])
        #expect(blocks.map { $0["name"] as? String } == ["get_weather", "get_time", "get_stock"])

        // `input` must be a JSON object, not an encoded string.
        let firstInput = try #require(blocks[0]["input"] as? [String: Any])
        #expect(firstInput["city"] as? String == "Tokyo")
        let stockInput = try #require(blocks[2]["input"] as? [String: Any])
        #expect(stockInput["ticker"] as? String == "AAPL")
        #expect((stockInput["days"] as? NSNumber)?.doubleValue == 5)
    }

    @Test func toolResultTurnIsOneUserMessageWithEveryResult() throws {
        let data = try mapper.buildRequestBody(ToolTurnFixture.request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages[2]["role"] as? String == "user")

        let blocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(blocks.count == 3)
        #expect(blocks.map { $0["type"] as? String } == ["tool_result", "tool_result", "tool_result"])
        #expect(blocks.map { $0["tool_use_id"] as? String } == ["call_weather", "call_time", "call_stock"])
        #expect(blocks.map { $0["content"] as? String } == ["Sunny, 24°C", "14:05", "232.10"])
    }

    @Test func mixedTurnKeepsTextAndToolUseBlocks() throws {
        let call = ToolCall(id: "call_1", name: "search", arguments: .object(["q": .string("swift")]))
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .mixed([.text("Looking that up."), .toolCalls([call])])),
        ])

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])

        #expect(messages[0]["role"] as? String == "assistant")
        #expect(blocks.map { $0["type"] as? String } == ["text", "tool_use"])
        #expect(blocks[0]["text"] as? String == "Looking that up.")
        #expect(blocks[1]["id"] as? String == "call_1")
    }

    /// Anthropic requires every `tool_result` block to precede any other block in
    /// the message carrying it, whatever order the caller wrote the parts in.
    @Test func toolResultBlocksComeBeforeTextInTheSameTurn() throws {
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .toolCalls(ToolTurnFixture.calls)),
            Message(role: .user, content: .mixed([
                .text("Here you go."),
                .toolResults(ToolTurnFixture.results),
            ])),
        ])

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.count == 2)
        #expect(messages[1]["role"] as? String == "user")
        let blocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String }
            == ["tool_result", "tool_result", "tool_result", "text"])
    }

    /// `tool_use` may only ride an assistant turn and `tool_result` only a user
    /// turn, so a turn holding both is split rather than emitted as one message.
    @Test func turnWithBothCallsAndResultsSplitsByRole() throws {
        let call = ToolCall(id: "call_next", name: "get_news", arguments: .object([:]))
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .toolCalls([ToolTurnFixture.calls[0]])),
            Message(role: .assistant, content: .mixed([
                .toolResults([ToolTurnFixture.results[0]]),
                .text("Now the news."),
                .toolCalls([call]),
            ])),
        ])

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.count == 3)
        #expect(messages[1]["role"] as? String == "user")
        #expect((messages[1]["content"] as? [[String: Any]])?.map { $0["type"] as? String }
            == ["tool_result"])

        #expect(messages[2]["role"] as? String == "assistant")
        #expect((messages[2]["content"] as? [[String: Any]])?.map { $0["type"] as? String }
            == ["text", "tool_use"])
    }
}

@Suite("Parallel tool calls — OpenAI")
struct OpenAIParallelToolCallTests {
    let mapper = OpenAIMapper(defaultModel: .gpt4o)

    @Test func assistantTurnCarriesEveryToolCall() throws {
        let data = try mapper.buildRequestBody(ToolTurnFixture.request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        // 1 user + 1 assistant + one `tool` message per result.
        #expect(messages.count == 5)
        #expect(messages[1]["role"] as? String == "assistant")
        #expect(messages[1]["content"] is NSNull)

        let toolCalls = try #require(messages[1]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.count == 3)
        #expect(toolCalls.map { $0["id"] as? String } == ["call_weather", "call_time", "call_stock"])
        #expect(toolCalls.allSatisfy { $0["type"] as? String == "function" })

        // OpenAI takes `arguments` as an encoded JSON string.
        let function = try #require(toolCalls[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_weather")
        let argumentString = try #require(function["arguments"] as? String)
        let arguments = try #require(
            try JSONSerialization.jsonObject(with: Data(argumentString.utf8)) as? [String: Any]
        )
        #expect(arguments["city"] as? String == "Tokyo")
    }

    @Test func eachToolResultBecomesItsOwnToolMessage() throws {
        let data = try mapper.buildRequestBody(ToolTurnFixture.request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        let toolMessages = messages.filter { $0["role"] as? String == "tool" }
        #expect(toolMessages.count == 3)
        #expect(toolMessages.map { $0["tool_call_id"] as? String } == ["call_weather", "call_time", "call_stock"])
        #expect(toolMessages.map { $0["content"] as? String } == ["Sunny, 24°C", "14:05", "232.10"])
    }

    @Test func mixedTurnMergesTextIntoTheToolCallMessage() throws {
        let call = ToolCall(id: "call_1", name: "search", arguments: .object(["q": .string("swift")]))
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .mixed([.text("Looking that up."), .toolCalls([call])])),
        ])

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "assistant")
        let contentParts = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(contentParts.count == 1)
        #expect(contentParts[0]["text"] as? String == "Looking that up.")
        #expect((messages[0]["tool_calls"] as? [[String: Any]])?.count == 1)
    }
}

@Suite("Parallel tool calls — Gemini")
struct GeminiParallelToolCallTests {
    let mapper = GeminiMapper(defaultModel: .flash25)

    @Test func modelTurnEmitsOneFunctionCallPartPerCall() throws {
        let data = try mapper.buildRequestBody(ToolTurnFixture.request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])

        #expect(contents.count == 3)
        #expect(contents[1]["role"] as? String == "model")

        let parts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(parts.count == 3)

        let functionCalls = parts.compactMap { $0["functionCall"] as? [String: Any] }
        #expect(functionCalls.count == 3)
        #expect(functionCalls.map { $0["name"] as? String } == ["get_weather", "get_time", "get_stock"])

        let stockArgs = try #require(functionCalls[2]["args"] as? [String: Any])
        #expect(stockArgs["ticker"] as? String == "AAPL")
        #expect((stockArgs["days"] as? NSNumber)?.doubleValue == 5)
    }

    @Test func responseTurnEmitsOneFunctionResponsePartPerResult() throws {
        let data = try mapper.buildRequestBody(ToolTurnFixture.request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])

        #expect(contents[2]["role"] as? String == "user")

        let parts = try #require(contents[2]["parts"] as? [[String: Any]])
        let responses = parts.compactMap { $0["functionResponse"] as? [String: Any] }
        #expect(responses.count == 3)
        // Gemini correlates on the function name, not a call id.
        #expect(responses.map { $0["name"] as? String } == ["get_weather", "get_time", "get_stock"])
        #expect(responses.compactMap { ($0["response"] as? [String: Any])?["result"] as? String }
            == ["Sunny, 24°C", "14:05", "232.10"])
    }
}

@Suite("Parallel tool calls — Ollama")
struct OllamaParallelToolCallTests {
    let mapper = OllamaMapper(defaultModel: "llama3.2")

    @Test func assistantTurnCarriesEveryToolCall() throws {
        let data = try mapper.buildChatBody(ToolTurnFixture.request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.count == 5)
        #expect(messages[1]["role"] as? String == "assistant")

        let toolCalls = try #require(messages[1]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.count == 3)

        let functions = toolCalls.compactMap { $0["function"] as? [String: Any] }
        #expect(functions.map { $0["name"] as? String } == ["get_weather", "get_time", "get_stock"])
        // Ollama takes arguments as an object, not an encoded string.
        let weatherArgs = try #require(functions[0]["arguments"] as? [String: Any])
        #expect(weatherArgs["city"] as? String == "Tokyo")
    }

    @Test func eachToolResultBecomesItsOwnToolMessage() throws {
        let data = try mapper.buildChatBody(ToolTurnFixture.request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        let toolMessages = messages.filter { $0["role"] as? String == "tool" }
        #expect(toolMessages.count == 3)
        #expect(toolMessages.map { $0["content"] as? String } == ["Sunny, 24°C", "14:05", "232.10"])
        #expect(toolMessages.map { $0["tool_name"] as? String } == ["get_weather", "get_time", "get_stock"])
    }
}

@Suite("Parallel tool calls — MLX chat text")
struct MLXParallelToolCallTests {
    @Test func toolCallsRenderAsJSONLines() throws {
        let rendered = try #require(MLXChatText.render(.toolCalls(ToolTurnFixture.calls)))
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.count == 3)
        let first = try #require(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        #expect(first["name"] as? String == "get_weather")
        #expect((first["arguments"] as? [String: Any])?["city"] as? String == "Tokyo")
    }

    @Test func toolResultsRenderAsTheirContent() {
        #expect(MLXChatText.render(.toolResults(ToolTurnFixture.results))
            == "Sunny, 24°C\n14:05\n232.10")
    }

    @Test func mixedTurnKeepsTextAndToolCalls() throws {
        let call = ToolCall(id: "call_1", name: "search", arguments: .object(["q": .string("swift")]))
        let rendered = try #require(MLXChatText.render(.mixed([.text("Looking that up."), .toolCalls([call])])))

        #expect(rendered.hasPrefix("Looking that up.\n"))
        #expect(rendered.contains("\"name\":\"search\""))
    }

    @Test func imageOnlyContentRendersNothing() {
        #expect(MLXChatText.render(.image(.base64(data: "abc", mimeType: "image/png"))) == nil)
    }

    @Test func plainTextRendersUnchanged() {
        #expect(MLXChatText.render(.text("hello")) == "hello")
    }
}

@Suite("Parallel tool calls — degenerate content")
struct DegenerateToolContentTests {
    /// An empty tool array must not produce a message body every provider rejects
    /// (Anthropic: empty `content`; OpenAI/Ollama: empty `tool_calls`).
    @Test func emptyToolCallsProduceNoMessage() throws {
        let request = AIRequest(messages: [Message(role: .assistant, content: .toolCalls([]))])

        let anthropic = try JSONSerialization.jsonObject(
            with: AnthropicMapper(defaultModel: .claudeSonnet5).buildRequestBody(request, stream: false)
        ) as? [String: Any]
        #expect((anthropic?["messages"] as? [[String: Any]])?.isEmpty == true)

        let openAI = try JSONSerialization.jsonObject(
            with: OpenAIMapper(defaultModel: .gpt4o).buildRequestBody(request, stream: false)
        ) as? [String: Any]
        #expect((openAI?["messages"] as? [[String: Any]])?.isEmpty == true)

        let gemini = try JSONSerialization.jsonObject(
            with: GeminiMapper(defaultModel: .flash25).buildRequestBody(request)
        ) as? [String: Any]
        #expect((gemini?["contents"] as? [[String: Any]])?.isEmpty == true)

        let ollama = try JSONSerialization.jsonObject(
            with: OllamaMapper(defaultModel: "llama3.2").buildChatBody(request, stream: false)
        ) as? [String: Any]
        #expect((ollama?["messages"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func emptyToolResultsProduceNoMessage() throws {
        let request = AIRequest(messages: [Message(role: .tool, content: .toolResults([]))])

        let anthropic = try JSONSerialization.jsonObject(
            with: AnthropicMapper(defaultModel: .claudeSonnet5).buildRequestBody(request, stream: false)
        ) as? [String: Any]
        #expect((anthropic?["messages"] as? [[String: Any]])?.isEmpty == true)

        let openAI = try JSONSerialization.jsonObject(
            with: OpenAIMapper(defaultModel: .gpt4o).buildRequestBody(request, stream: false)
        ) as? [String: Any]
        #expect((openAI?["messages"] as? [[String: Any]])?.isEmpty == true)

        let ollama = try JSONSerialization.jsonObject(
            with: OllamaMapper(defaultModel: "llama3.2").buildChatBody(request, stream: false)
        ) as? [String: Any]
        #expect((ollama?["messages"] as? [[String: Any]])?.isEmpty == true)
    }

    /// `JSONValue.number` can hold a non-finite Double; feeding one straight to
    /// `JSONSerialization` raises an uncatchable ObjC exception, so it is nulled.
    @Test func nonFiniteToolArgumentsSerialiseAsNull() throws {
        let call = ToolCall(
            id: "call_1",
            name: "compute",
            arguments: .object(["ratio": .number(.nan), "limit": .number(.infinity)])
        )
        let request = AIRequest(messages: [Message(role: .assistant, content: .toolCalls([call]))])

        let data = try AnthropicMapper(defaultModel: .claudeSonnet5).buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        let input = try #require(blocks[0]["input"] as? [String: Any])

        #expect(input["ratio"] is NSNull)
        #expect(input["limit"] is NSNull)
    }

    /// Tool arguments are objects by contract; a non-object degrades to `{}`
    /// rather than producing a body the provider rejects.
    @Test func nonObjectToolArgumentsDegradeToEmptyObject() throws {
        let call = ToolCall(id: "call_1", name: "ping", arguments: .string("not-an-object"))
        let request = AIRequest(messages: [Message(role: .assistant, content: .toolCalls([call]))])

        let data = try AnthropicMapper(defaultModel: .claudeSonnet5).buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])

        #expect((blocks[0]["input"] as? [String: Any])?.isEmpty == true)
    }
}

@Suite("Parallel tool calls — turn ordering")
struct ToolTurnOrderingTests {
    /// Every provider requires the tool results to sit directly after the assistant
    /// turn they answer; trailing caller text must not be interposed.
    @Test func toolResultsPrecedeTrailingTextOnOpenAI() throws {
        let request = mixedResultsThenTextRequest()
        let data = try OpenAIMapper(defaultModel: .gpt4o).buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.map { $0["role"] as? String } == ["assistant", "tool", "tool", "tool", "user"])
    }

    @Test func toolResultsPrecedeTrailingTextOnOllama() throws {
        let request = mixedResultsThenTextRequest()
        let data = try OllamaMapper(defaultModel: "llama3.2").buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.map { $0["role"] as? String } == ["assistant", "tool", "tool", "tool", "user"])
    }

    @Test func geminiSplitsATurnHoldingBothCallsAndResults() throws {
        let call = ToolCall(id: "call_next", name: "get_news", arguments: .object([:]))
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .mixed([
                .toolResults([ToolResult(toolCallId: "call_weather", name: "get_weather", content: "Sunny")]),
                .text("Now the news."),
                .toolCalls([call]),
            ])),
        ])

        let data = try GeminiMapper(defaultModel: .flash25).buildRequestBody(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])

        #expect(contents.count == 2)
        #expect(contents[0]["role"] as? String == "user")
        #expect((contents[0]["parts"] as? [[String: Any]])?.allSatisfy { $0["functionResponse"] != nil } == true)

        #expect(contents[1]["role"] as? String == "model")
        let modelParts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(modelParts[0]["text"] as? String == "Now the news.")
        #expect(modelParts[1]["functionCall"] != nil)
    }

    @Test func geminiKeepsResultsAndTextInOneUserTurn() throws {
        let request = mixedResultsThenTextRequest()
        let data = try GeminiMapper(defaultModel: .flash25).buildRequestBody(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])

        #expect(contents.map { $0["role"] as? String } == ["model", "user"])
        let parts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(parts.count == 4)
        #expect(parts[3]["text"] as? String == "Here you go.")
    }

    private func mixedResultsThenTextRequest() -> AIRequest {
        AIRequest(messages: [
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "call_weather", name: "get_weather", arguments: .object(["city": .string("Tokyo")])),
                ToolCall(id: "call_time", name: "get_time", arguments: .object([:])),
                ToolCall(id: "call_stock", name: "get_stock", arguments: .object([:])),
            ])),
            Message(role: .user, content: .mixed([
                .text("Here you go."),
                .toolResults([
                    ToolResult(toolCallId: "call_weather", name: "get_weather", content: "Sunny"),
                    ToolResult(toolCallId: "call_time", name: "get_time", content: "14:05"),
                    ToolResult(toolCallId: "call_stock", name: "get_stock", content: "232.10"),
                ]),
            ])),
        ])
    }
}

@Suite("MLX chat text — empty content")
struct MLXEmptyContentTests {
    /// An empty text turn still renders, as it did before tool content was modelled.
    @Test func emptyTextStillRenders() {
        #expect(MLXChatText.render(.text("")) == "")
    }
}
