// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("OpenAIMapper")
struct OpenAIMapperTests {
    let mapper = OpenAIMapper(defaultModel: .gpt4o)

    @Test func buildSimpleRequest() throws {
        let request = AIRequest.chat("Hello!")
            .withMaxTokens(100)

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["model"] as? String == "gpt-4o")
        #expect(json["max_tokens"] as? Int == 100)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Hello!")
    }

    @Test func buildRequestWithSystemPrompt() throws {
        let request = AIRequest.chat("Hi")
            .withSystem("You are a pirate")

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "You are a pirate")
        #expect(messages[1]["role"] as? String == "user")
    }

    @Test func buildRequestWithStreaming() throws {
        let request = AIRequest.chat("Stream this")
        let data = try mapper.buildRequestBody(request, stream: true)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
    }

    @Test func buildRequestWithTools() throws {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get weather",
            inputSchema: .object(["type": "object"])
        )
        let request = AIRequest.chat("Weather?").withTools([tool])
        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])

        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_weather")
    }

    @Test func buildRequestWithJSONMode() throws {
        let request = AIRequest.chat("Give me JSON").withResponseFormat(.json)
        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let format = try #require(json["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
    }

    @Test func parseSuccessResponse() throws {
        let responseJSON: [String: Any] = [
            "id": "chatcmpl-abc123",
            "object": "chat.completion",
            "model": "gpt-4o",
            "choices": [[
                "index": 0,
                "message": [
                    "role": "assistant",
                    "content": "Hello! How can I help?",
                ],
                "finish_reason": "stop",
            ]],
            "usage": [
                "prompt_tokens": 10,
                "completion_tokens": 8,
                "total_tokens": 18,
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)

        #expect(response.id == "chatcmpl-abc123")
        #expect(response.content == "Hello! How can I help?")
        #expect(response.model == "gpt-4o")
        #expect(response.provider == .openAI)
        #expect(response.finishReason == .complete)
        #expect(response.usage?.inputTokens == 10)
        #expect(response.usage?.outputTokens == 8)
    }

    @Test func parseResponseWithToolCalls() throws {
        let responseJSON: [String: Any] = [
            "id": "chatcmpl-tool",
            "model": "gpt-4o",
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [[
                        "id": "call_abc",
                        "type": "function",
                        "function": [
                            "name": "get_weather",
                            "arguments": "{\"location\":\"Tokyo\"}",
                        ],
                    ]],
                ],
                "finish_reason": "tool_calls",
            ]],
            "usage": ["prompt_tokens": 15, "completion_tokens": 10, "total_tokens": 25],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)

        #expect(response.finishReason == .toolCall)
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "get_weather")
        #expect(response.toolCalls[0].id == "call_abc")
    }

    @Test func parseStreamContentDelta() {
        var state = OpenAIStreamState()
        let event = """
        {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
        """

        let chunk = mapper.parseStreamEvent(event, state: &state)
        #expect(chunk?.delta == "Hello")
        #expect(chunk?.accumulatedContent == "Hello")
        #expect(chunk?.isComplete == false)
    }

    @Test func parseStreamDoneEvent() {
        var state = OpenAIStreamState()
        state.accumulated = "Hello world"
        let chunk = mapper.parseStreamEvent("[DONE]", state: &state)
        #expect(chunk?.isComplete == true)
        #expect(chunk?.accumulatedContent == "Hello world")
    }

    /// The finish_reason chunk carries the reason but must NOT end the stream:
    /// with `stream_options.include_usage` the usage chunk still follows, and
    /// completing here would discard the token counts.
    @Test func parseStreamFinishReasonDoesNotEndStream() {
        var state = OpenAIStreamState()
        state.accumulated = "Hello"
        let event = """
        {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        """

        let chunk = mapper.parseStreamEvent(event, state: &state)
        #expect(chunk?.finishReason == .complete)
        #expect(chunk?.isComplete == false)

        // A host that never sends a usage chunk still terminates on [DONE],
        // and the reason recorded above survives onto that final chunk.
        let done = mapper.parseStreamEvent("[DONE]", state: &state)
        #expect(done?.isComplete == true)
        #expect(done?.finishReason == .complete)
    }

    @Test func parseStreamEventWithWhitespace() {
        var state = OpenAIStreamState()
        let event = "  {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}  "

        let chunk = mapper.parseStreamEvent(event, state: &state)
        #expect(chunk?.delta == "Hello")
        #expect(chunk?.isComplete == false)
    }

    @Test func parseStreamEventEmptyDataReturnsNil() {
        var state = OpenAIStreamState()
        #expect(mapper.parseStreamEvent("", state: &state) == nil)
        #expect(mapper.parseStreamEvent("   ", state: &state) == nil)
    }

    @Test func parseStreamDoneWithWhitespace() {
        var state = OpenAIStreamState()
        state.accumulated = "Hello"
        let chunk = mapper.parseStreamEvent(" [DONE] ", state: &state)
        // The provider trims each line before stripping "data: ", so the mapper
        // only ever sees a clean "[DONE]". A padded one is not recognised and is
        // ignored rather than crashing.
        #expect(chunk == nil || chunk?.isComplete == true)
    }

    @Test func parseInvalidJSON() {
        #expect(throws: ArbiterError.self) {
            try mapper.parseResponse(Data("not json".utf8))
        }
    }
}
