// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("Provider Error Handling")
struct ProviderErrorTests {

    @Test func openAIEmptyChoicesReturnsEmptyContent() throws {
        let mapper = OpenAIMapper(defaultModel: .gpt4o)
        let responseJSON: [String: Any] = [
            "id": "chatcmpl-err",
            "model": "gpt-4o",
            "choices": [[String: Any]](),
            "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)
        #expect(response.content == "")
        #expect(response.finishReason == nil)
    }

    @Test func openAIRateLimitFinishReason() throws {
        let mapper = OpenAIMapper(defaultModel: .gpt4o)
        let responseJSON: [String: Any] = [
            "id": "chatcmpl-limited",
            "model": "gpt-4o",
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": "Partial response...",
                ],
                "finish_reason": "length",
            ]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 4096, "total_tokens": 4196],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)

        #expect(response.finishReason == .maxTokens)
        #expect(response.usage?.outputTokens == 4096)
    }

    @Test func openAIContentFilterFinishReason() throws {
        let mapper = OpenAIMapper(defaultModel: .gpt4o)
        let responseJSON: [String: Any] = [
            "id": "chatcmpl-filtered",
            "model": "gpt-4o",
            "choices": [[
                "message": ["role": "assistant", "content": ""],
                "finish_reason": "content_filter",
            ]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 0, "total_tokens": 10],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)
        #expect(response.finishReason == .contentFilter)
    }

    @Test func geminiSafetyFilter() throws {
        let mapper = GeminiMapper(defaultModel: .flash25)
        let responseJSON: [String: Any] = [
            "candidates": [[
                "content": ["parts": [[String: Any]](), "role": "model"],
                "finishReason": "SAFETY",
            ]],
            "usageMetadata": ["promptTokenCount": 5, "candidatesTokenCount": 0, "totalTokenCount": 5],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)
        #expect(response.finishReason == .contentFilter)
    }

    @Test func geminiMaxTokens() throws {
        let mapper = GeminiMapper(defaultModel: .flash25)
        let responseJSON: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [["text": "Truncated"]],
                    "role": "model",
                ],
                "finishReason": "MAX_TOKENS",
            ]],
            "usageMetadata": ["promptTokenCount": 5, "candidatesTokenCount": 100, "totalTokenCount": 105],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)
        #expect(response.finishReason == .maxTokens)
        #expect(response.content == "Truncated")
    }

    @Test func geminiEmptyCandidates() throws {
        let mapper = GeminiMapper(defaultModel: .flash25)
        let responseJSON: [String: Any] = ["candidates": [[String: Any]]()]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)
        #expect(response.content == "")
    }

    @Test func anthropicMaxTokensStopReason() throws {
        let mapper = AnthropicMapper(defaultModel: .claude4Sonnet)
        let responseJSON: [String: Any] = [
            "id": "msg-123",
            "model": "claude-sonnet-4-20250514",
            "content": [["type": "text", "text": "Truncated"]],
            "stop_reason": "max_tokens",
            "usage": ["input_tokens": 10, "output_tokens": 1024],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)
        #expect(response.finishReason == .maxTokens)
    }

    @Test func anthropicToolUseStopReason() throws {
        let mapper = AnthropicMapper(defaultModel: .claude4Sonnet)
        let responseJSON: [String: Any] = [
            "id": "msg-tool",
            "model": "claude-sonnet-4-20250514",
            "content": [
                [
                    "type": "tool_use",
                    "id": "tool_123",
                    "name": "calculator",
                    "input": ["expression": "2+2"],
                ],
            ],
            "stop_reason": "tool_use",
            "usage": ["input_tokens": 20, "output_tokens": 15],
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)
        #expect(response.finishReason == .toolCall)
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "calculator")
        #expect(response.toolCalls[0].id == "tool_123")
    }

    @Test func ollamaEmptyResponse() throws {
        let mapper = OllamaMapper(defaultModel: "llama3.2")
        let responseJSON: [String: Any] = [
            "model": "llama3.2",
            "message": ["role": "assistant", "content": ""],
            "done": true,
        ]

        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = try mapper.parseResponse(data)
        #expect(response.content == "")
        #expect(response.provider == .ollama)
        #expect(response.usage == nil)
    }

    @Test func ollamaStreamEmptyLine() {
        let mapper = OllamaMapper(defaultModel: "llama3.2")
        var accumulated = ""
        let chunk = mapper.parseStreamLine("", accumulated: &accumulated)
        #expect(chunk == nil)
    }

    @Test func ollamaStreamInvalidJSON() {
        let mapper = OllamaMapper(defaultModel: "llama3.2")
        var accumulated = ""
        let chunk = mapper.parseStreamLine("not json", accumulated: &accumulated)
        #expect(chunk == nil)
    }
}
