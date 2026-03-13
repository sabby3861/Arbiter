// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("GeminiMapper")
struct GeminiMapperTests {
    let mapper = GeminiMapper(defaultModel: .flash25)

    @Test func buildSimpleRequest() throws {
        let request = AIRequest.chat("Hello Gemini!")

        let data = try mapper.buildRequestBody(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents[0]["role"] as? String == "user")

        let parts = try #require(contents[0]["parts"] as? [[String: Any]])
        #expect(parts[0]["text"] as? String == "Hello Gemini!")
    }

    @Test func buildRequestWithSystemInstruction() throws {
        let request = AIRequest.chat("Hi").withSystem("Be creative")

        let data = try mapper.buildRequestBody(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let systemInstruction = try #require(json["systemInstruction"] as? [String: Any])
        let parts = try #require(systemInstruction["parts"] as? [[String: Any]])
        #expect(parts[0]["text"] as? String == "Be creative")
    }

    @Test func buildRequestWithGenerationConfig() throws {
        let request = AIRequest.chat("Test")
            .withMaxTokens(500)
            .withTemperature(0.8)
            .withTopP(0.9)

        let data = try mapper.buildRequestBody(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["maxOutputTokens"] as? Int == 500)
        #expect(config["temperature"] as? Double == 0.8)
        #expect(config["topP"] as? Double == 0.9)
    }

    @Test func buildRequestWithTools() throws {
        let tool = ToolDefinition(
            name: "search",
            description: "Search the web",
            inputSchema: .object(["type": "object"])
        )
        let request = AIRequest.chat("Search for Swift").withTools([tool])
        let data = try mapper.buildRequestBody(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let tools = try #require(json["tools"] as? [[String: Any]])
        let declarations = try #require(tools[0]["functionDeclarations"] as? [[String: Any]])
        #expect(declarations[0]["name"] as? String == "search")
    }

    @Test func assistantMappedAsModel() throws {
        let messages: [Message] = [
            .user("Hello"),
            .assistant("Hi there"),
            .user("How are you?"),
        ]
        let request = AIRequest(messages: messages)
        let data = try mapper.buildRequestBody(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])

        #expect(contents[1]["role"] as? String == "model")
    }

    @Test func parseSuccessResponse() throws {
        let responseJSON: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [["text": "Hello from Gemini!"]],
                    "role": "model",
                ],
                "finishReason": "STOP",
            ]],
            "usageMetadata": [
                "promptTokenCount": 5,
                "candidatesTokenCount": 10,
                "totalTokenCount": 15,
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)

        #expect(response.content == "Hello from Gemini!")
        #expect(response.provider == .gemini)
        #expect(response.finishReason == .complete)
        #expect(response.usage?.inputTokens == 5)
        #expect(response.usage?.outputTokens == 10)
    }

    @Test func parseResponseWithToolCall() throws {
        let responseJSON: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [[
                        "functionCall": [
                            "name": "get_weather",
                            "args": ["location": "Tokyo"],
                        ],
                    ]],
                    "role": "model",
                ],
                "finishReason": "STOP",
            ]],
            "usageMetadata": ["promptTokenCount": 10, "candidatesTokenCount": 5, "totalTokenCount": 15],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)

        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "get_weather")
    }

    @Test func parseStreamDelta() {
        var accumulated = ""
        let event = """
        {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}]}
        """

        let chunk = mapper.parseStreamEvent(event, accumulated: &accumulated)
        #expect(chunk?.delta == "Hello")
        #expect(chunk?.accumulatedContent == "Hello")
        #expect(chunk?.isComplete == false)
    }

    @Test func parseStreamFinish() {
        var accumulated = "Hello world"
        let event = """
        {"candidates":[{"content":{"parts":[{"text":""}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":10,"totalTokenCount":15}}
        """

        let chunk = mapper.parseStreamEvent(event, accumulated: &accumulated)
        #expect(chunk?.isComplete == true)
        #expect(chunk?.usage?.inputTokens == 5)
    }

    @Test func parseInvalidJSON() {
        #expect(throws: SwiftAIError.self) {
            try mapper.parseResponse(Data("invalid".utf8))
        }
    }

    @Test func jsonModeConfig() throws {
        let request = AIRequest.chat("JSON").withResponseFormat(.json)
        let data = try mapper.buildRequestBody(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
    }
}
