// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("OllamaMapper")
struct OllamaMapperTests {
    let mapper = OllamaMapper(defaultModel: "llama3.2")

    @Test func buildSimpleChatBody() throws {
        let request = AIRequest.chat("Hello Llama!")

        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["model"] as? String == "llama3.2")
        #expect(json["stream"] as? Bool == false)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Hello Llama!")
    }

    @Test func buildRequestWithSystemPrompt() throws {
        let request = AIRequest.chat("Hi").withSystem("You are helpful")

        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "You are helpful")
    }

    @Test func buildStreamingRequest() throws {
        let request = AIRequest.chat("Stream")
        let data = try mapper.buildChatBody(request, stream: true)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
    }

    @Test func buildRequestWithOptions() throws {
        let request = AIRequest.chat("Test")
            .withTemperature(0.7)
            .withTopP(0.9)
            .withMaxTokens(256)

        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])

        #expect(options["temperature"] as? Double == 0.7)
        #expect(options["top_p"] as? Double == 0.9)
        #expect(options["num_predict"] as? Int == 256)
    }

    @Test func buildRequestWithJSONFormat() throws {
        let request = AIRequest.chat("JSON").withResponseFormat(.json)
        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["format"] as? String == "json")
    }

    @Test func parseNonStreamingResponse() throws {
        let responseJSON: [String: Any] = [
            "model": "llama3.2",
            "message": [
                "role": "assistant",
                "content": "Hello! I'm Llama.",
            ],
            "done": true,
            "prompt_eval_count": 12,
            "eval_count": 8,
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)

        #expect(response.content == "Hello! I'm Llama.")
        #expect(response.model == "llama3.2")
        #expect(response.provider == .ollama)
        #expect(response.usage?.inputTokens == 12)
        #expect(response.usage?.outputTokens == 8)
    }

    @Test func parseStreamingChunk() {
        var accumulated = ""
        let line = """
        {"model":"llama3.2","message":{"role":"assistant","content":"Hello"},"done":false}
        """

        let chunk = mapper.parseStreamLine(line, accumulated: &accumulated)
        #expect(chunk?.delta == "Hello")
        #expect(chunk?.accumulatedContent == "Hello")
        #expect(chunk?.isComplete == false)
        #expect(chunk?.provider == .ollama)
    }

    @Test func parseStreamingDone() {
        var accumulated = "Hello world"
        let line = """
        {"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":10,"eval_count":5}
        """

        let chunk = mapper.parseStreamLine(line, accumulated: &accumulated)
        #expect(chunk?.isComplete == true)
        #expect(chunk?.accumulatedContent == "Hello world")
        #expect(chunk?.usage?.inputTokens == 10)
        #expect(chunk?.usage?.outputTokens == 5)
    }

    @Test func parseStreamAccumulation() {
        var accumulated = ""

        let line1 = """
        {"model":"llama3.2","message":{"role":"assistant","content":"Hello "},"done":false}
        """
        let line2 = """
        {"model":"llama3.2","message":{"role":"assistant","content":"world"},"done":false}
        """

        _ = mapper.parseStreamLine(line1, accumulated: &accumulated)
        let chunk2 = mapper.parseStreamLine(line2, accumulated: &accumulated)

        #expect(chunk2?.delta == "world")
        #expect(chunk2?.accumulatedContent == "Hello world")
    }

    @Test func parseStreamLineWithWhitespace() {
        var accumulated = ""
        let line = "  {\"model\":\"llama3.2\",\"message\":{\"role\":\"assistant\",\"content\":\"Hi\"},\"done\":false}  "

        let chunk = mapper.parseStreamLine(line, accumulated: &accumulated)
        #expect(chunk?.delta == "Hi")
        #expect(chunk?.isComplete == false)
    }

    @Test func parseStreamLineEmptyReturnsNil() {
        var accumulated = ""
        #expect(mapper.parseStreamLine("", accumulated: &accumulated) == nil)
        #expect(mapper.parseStreamLine("   ", accumulated: &accumulated) == nil)
    }

    @Test func parseInvalidJSON() {
        #expect(throws: ArbiterError.self) {
            try mapper.parseResponse(Data("broken".utf8))
        }
    }
}
