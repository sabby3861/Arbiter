// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("Unified Response Types")
struct UnifiedResponseTests {

    // MARK: - All providers produce identical AIResponse structure

    @Test func allProvidersProduceAIResponse() throws {
        let openAIMapper = OpenAIMapper(defaultModel: .gpt4o)
        let geminiMapper = GeminiMapper(defaultModel: .flash25)
        let anthropicMapper = AnthropicMapper(defaultModel: .claude4Sonnet)
        let ollamaMapper = OllamaMapper(defaultModel: "llama3.2")

        let openAI = try openAIMapper.parseResponse(try makeOpenAIData())
        let gemini = try geminiMapper.parseResponse(try makeGeminiData())
        let anthropic = try anthropicMapper.parseResponse(try makeAnthropicData())
        let ollama = try ollamaMapper.parseResponse(try makeOllamaData())

        // All produce non-empty content
        #expect(!openAI.content.isEmpty)
        #expect(!gemini.content.isEmpty)
        #expect(!anthropic.content.isEmpty)
        #expect(!ollama.content.isEmpty)

        // All have correct provider tags
        #expect(openAI.provider == .openAI)
        #expect(gemini.provider == .gemini)
        #expect(anthropic.provider == .anthropic)
        #expect(ollama.provider == .ollama)

        // All have usage data
        #expect(openAI.usage != nil)
        #expect(gemini.usage != nil)
        #expect(anthropic.usage != nil)
        #expect(ollama.usage != nil)

        // All have finish reasons
        #expect(openAI.finishReason == .complete)
        #expect(gemini.finishReason == .complete)
        #expect(anthropic.finishReason == .complete)
        #expect(ollama.finishReason == .complete)
    }

    // MARK: - All providers produce identical AIStreamChunk structure

    @Test func allProvidersProduceStreamChunks() {
        let openAIMapper = OpenAIMapper(defaultModel: .gpt4o)
        let geminiMapper = GeminiMapper(defaultModel: .flash25)
        let anthropicMapper = AnthropicMapper(defaultModel: .claude4Sonnet)
        let ollamaMapper = OllamaMapper(defaultModel: "llama3.2")

        var accOpenAI = ""
        var accGemini = ""
        var accAnthropic = ""
        var accOllama = ""

        let openAIChunk = openAIMapper.parseStreamEvent(
            """
            {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}
            """,
            accumulated: &accOpenAI
        )

        let geminiChunk = geminiMapper.parseStreamEvent(
            """
            {"candidates":[{"content":{"parts":[{"text":"Hi"}],"role":"model"}}]}
            """,
            accumulated: &accGemini
        )

        var streamInputTokens: Int?
        let anthropicChunk = anthropicMapper.parseStreamEvent(
            """
            {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}
            """,
            accumulated: &accAnthropic,
            streamInputTokens: &streamInputTokens
        )

        let ollamaChunk = ollamaMapper.parseStreamLine(
            """
            {"model":"llama3.2","message":{"role":"assistant","content":"Hi"},"done":false}
            """,
            accumulated: &accOllama
        )

        // All produce valid chunks with same delta
        #expect(openAIChunk?.delta == "Hi")
        #expect(geminiChunk?.delta == "Hi")
        #expect(anthropicChunk?.delta == "Hi")
        #expect(ollamaChunk?.delta == "Hi")

        // All accumulate correctly
        #expect(openAIChunk?.accumulatedContent == "Hi")
        #expect(geminiChunk?.accumulatedContent == "Hi")
        #expect(anthropicChunk?.accumulatedContent == "Hi")
        #expect(ollamaChunk?.accumulatedContent == "Hi")

        // None are complete yet
        #expect(openAIChunk?.isComplete == false)
        #expect(geminiChunk?.isComplete == false)
        #expect(anthropicChunk?.isComplete == false)
        #expect(ollamaChunk?.isComplete == false)

        // All have correct provider
        #expect(openAIChunk?.provider == .openAI)
        #expect(geminiChunk?.provider == .gemini)
        #expect(anthropicChunk?.provider == .anthropic)
        #expect(ollamaChunk?.provider == .ollama)
    }

    // MARK: - TokenUsage equality

    @Test func tokenUsageEquality() {
        let a = TokenUsage(inputTokens: 10, outputTokens: 20)
        let b = TokenUsage(inputTokens: 10, outputTokens: 20)
        let c = TokenUsage(inputTokens: 5, outputTokens: 20)

        #expect(a == b)
        #expect(a != c)
        #expect(a.totalTokens == 30)
    }
}

// MARK: - Sample response builders

private func makeOpenAIData() throws -> Data {
    let json: [String: Any] = [
        "id": "chatcmpl-abc",
        "model": "gpt-4o",
        "choices": [[
            "index": 0,
            "message": ["role": "assistant", "content": "Hello from OpenAI!"],
            "finish_reason": "stop",
        ]],
        "usage": ["prompt_tokens": 5, "completion_tokens": 4, "total_tokens": 9],
    ]
    return try JSONSerialization.data(withJSONObject: json)
}

private func makeGeminiData() throws -> Data {
    let json: [String: Any] = [
        "candidates": [[
            "content": [
                "parts": [["text": "Hello from Gemini!"]],
                "role": "model",
            ],
            "finishReason": "STOP",
        ]],
        "usageMetadata": [
            "promptTokenCount": 5,
            "candidatesTokenCount": 4,
            "totalTokenCount": 9,
        ],
    ]
    return try JSONSerialization.data(withJSONObject: json)
}

private func makeAnthropicData() throws -> Data {
    let json: [String: Any] = [
        "id": "msg-abc",
        "model": "claude-sonnet-4-20250514",
        "content": [["type": "text", "text": "Hello from Anthropic!"]],
        "stop_reason": "end_turn",
        "usage": ["input_tokens": 5, "output_tokens": 4],
    ]
    return try JSONSerialization.data(withJSONObject: json)
}

private func makeOllamaData() throws -> Data {
    let json: [String: Any] = [
        "model": "llama3.2",
        "message": ["role": "assistant", "content": "Hello from Ollama!"],
        "done": true,
        "prompt_eval_count": 5,
        "eval_count": 4,
    ]
    return try JSONSerialization.data(withJSONObject: json)
}
