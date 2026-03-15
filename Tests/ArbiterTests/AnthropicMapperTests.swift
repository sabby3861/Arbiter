// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("AnthropicMapper")
struct AnthropicMapperTests {
    let mapper = AnthropicMapper(defaultModel: .claude4Sonnet)

    @Test func buildSimpleRequestBody() throws {
        let request = AIRequest.chat("Hello, Claude!")
            .withMaxTokens(256)

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["model"] as? String == "claude-sonnet-4-20250514")
        #expect(json["max_tokens"] as? Int == 256)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Hello, Claude!")
    }

    @Test func buildRequestWithSystemPrompt() throws {
        let request = AIRequest.chat("Hello")
            .withSystem("You are a pirate")

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["system"] as? String == "You are a pirate")
    }

    @Test func buildRequestWithStreaming() throws {
        let request = AIRequest.chat("Stream this")
        let data = try mapper.buildRequestBody(request, stream: true)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["stream"] as? Bool == true)
    }

    @Test func buildRequestWithTemperature() throws {
        let request = AIRequest.chat("Creative prompt")
            .withTemperature(0.9)
            .withTopP(0.95)

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["temperature"] as? Double == 0.9)
        #expect(json["top_p"] as? Double == 0.95)
    }

    @Test func buildMultiTurnRequest() throws {
        let messages: [Message] = [
            .user("What is Swift?"),
            .assistant("Swift is a programming language by Apple."),
            .user("Tell me more about its concurrency model."),
        ]

        let request = AIRequest(messages: messages)
        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apiMessages = try #require(json["messages"] as? [[String: Any]])

        #expect(apiMessages.count == 3)
        #expect(apiMessages[0]["role"] as? String == "user")
        #expect(apiMessages[1]["role"] as? String == "assistant")
        #expect(apiMessages[2]["role"] as? String == "user")
    }

    @Test func buildRequestWithTools() throws {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get the weather for a location",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "location": .object([
                        "type": "string",
                        "description": "City name",
                    ]),
                ]),
                "required": .array([.string("location")]),
            ])
        )

        let request = AIRequest.chat("What's the weather in Tokyo?")
            .withTools([tool])

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])

        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "get_weather")
        #expect(tools[0]["description"] as? String == "Get the weather for a location")
    }

    @Test func parseSuccessResponse() throws {
        let responseJSON: [String: Any] = [
            "id": "msg_abc123",
            "type": "message",
            "role": "assistant",
            "content": [
                ["type": "text", "text": "Hello! How can I help you today?"],
            ],
            "model": "claude-sonnet-4-20250514",
            "stop_reason": "end_turn",
            "usage": [
                "input_tokens": 12,
                "output_tokens": 8,
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)

        #expect(response.id == "msg_abc123")
        #expect(response.content == "Hello! How can I help you today?")
        #expect(response.model == "claude-sonnet-4-20250514")
        #expect(response.provider == .anthropic)
        #expect(response.finishReason == .complete)
        #expect(response.usage?.inputTokens == 12)
        #expect(response.usage?.outputTokens == 8)
        #expect(response.usage?.totalTokens == 20)
    }

    @Test func parseResponseWithToolUse() throws {
        let responseJSON: [String: Any] = [
            "id": "msg_tool123",
            "type": "message",
            "role": "assistant",
            "content": [
                ["type": "text", "text": "Let me check the weather."],
                [
                    "type": "tool_use",
                    "id": "toolu_abc",
                    "name": "get_weather",
                    "input": ["location": "Tokyo"],
                ],
            ],
            "model": "claude-sonnet-4-20250514",
            "stop_reason": "tool_use",
            "usage": ["input_tokens": 20, "output_tokens": 15],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)

        #expect(response.content == "Let me check the weather.")
        #expect(response.finishReason == .toolCall)
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "get_weather")
        #expect(response.toolCalls[0].id == "toolu_abc")
    }

    @Test func parseStreamContentDelta() {
        var accumulated = ""
        var streamInputTokens: Int?
        let eventData = """
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
        """

        let chunk = mapper.parseStreamEvent(eventData, accumulated: &accumulated, streamInputTokens: &streamInputTokens)
        #expect(chunk?.delta == "Hello")
        #expect(chunk?.accumulatedContent == "Hello")
        #expect(chunk?.isComplete == false)
        #expect(accumulated == "Hello")
    }

    @Test func parseStreamAccumulation() {
        var accumulated = ""
        var streamInputTokens: Int?

        let event1 = """
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}
        """
        let event2 = """
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}
        """

        _ = mapper.parseStreamEvent(event1, accumulated: &accumulated, streamInputTokens: &streamInputTokens)
        let chunk2 = mapper.parseStreamEvent(event2, accumulated: &accumulated, streamInputTokens: &streamInputTokens)

        #expect(chunk2?.delta == "world")
        #expect(chunk2?.accumulatedContent == "Hello world")
    }

    @Test func parseStreamMessageDeltaWithUsage() {
        var accumulated = "Hello world"
        var streamInputTokens: Int? = 10

        let eventData = """
        {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}
        """

        let chunk = mapper.parseStreamEvent(eventData, accumulated: &accumulated, streamInputTokens: &streamInputTokens)
        #expect(chunk?.isComplete == true)
        #expect(chunk?.accumulatedContent == "Hello world")
        #expect(chunk?.usage?.inputTokens == 10)
        #expect(chunk?.usage?.outputTokens == 5)
        #expect(chunk?.finishReason == .complete)
    }

    @Test func parseStreamMessageStartCapturesInputTokens() {
        var accumulated = ""
        var streamInputTokens: Int?

        let messageStart = """
        {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4-20250514","usage":{"input_tokens":25,"output_tokens":0}}}
        """

        let chunk = mapper.parseStreamEvent(messageStart, accumulated: &accumulated, streamInputTokens: &streamInputTokens)
        #expect(chunk == nil)
        #expect(streamInputTokens == 25)
    }

    @Test func systemMessagesExcludedFromAPIMessages() throws {
        let messages: [Message] = [
            .system("You are helpful"),
            .user("Hello"),
        ]

        let request = AIRequest(messages: messages, systemPrompt: "Be kind")
        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apiMessages = try #require(json["messages"] as? [[String: Any]])

        // System messages should be filtered out — system prompt goes in "system" field
        #expect(apiMessages.count == 1)
        #expect(apiMessages[0]["role"] as? String == "user")
    }

    @Test func parseStreamEventWithLeadingTrailingWhitespace() {
        var accumulated = ""
        var streamInputTokens: Int?
        // Simulate whitespace that URLSession.AsyncBytes.lines may leave
        let eventData = "  {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}  "

        let chunk = mapper.parseStreamEvent(eventData, accumulated: &accumulated, streamInputTokens: &streamInputTokens)
        #expect(chunk?.delta == "Hello")
        #expect(chunk?.accumulatedContent == "Hello")
        #expect(chunk?.isComplete == false)
    }

    @Test func parseStreamEventEmptyDataReturnsNil() {
        var accumulated = ""
        var streamInputTokens: Int?

        let chunk1 = mapper.parseStreamEvent("", accumulated: &accumulated, streamInputTokens: &streamInputTokens)
        #expect(chunk1 == nil)

        let chunk2 = mapper.parseStreamEvent("   ", accumulated: &accumulated, streamInputTokens: &streamInputTokens)
        #expect(chunk2 == nil)

        #expect(accumulated == "")
    }

    @Test func parseStreamEventUnknownTypeReturnsNil() {
        var accumulated = ""
        var streamInputTokens: Int?
        let eventData = """
        {"type":"ping"}
        """

        let chunk = mapper.parseStreamEvent(eventData, accumulated: &accumulated, streamInputTokens: &streamInputTokens)
        #expect(chunk == nil)
    }

    @Test func parseInvalidJSONThrowsDecodingError() throws {
        let invalidData = Data("not json".utf8)

        #expect(throws: ArbiterError.self) {
            try mapper.parseResponse(invalidData)
        }
    }
}
