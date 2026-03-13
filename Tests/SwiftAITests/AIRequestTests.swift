// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
@testable import SwiftAI

@Suite("AIRequest Builder")
struct AIRequestTests {
    @Test func chatBuilderCreatesUserMessage() {
        let request = AIRequest.chat("Hello")

        #expect(request.messages.count == 1)
        #expect(request.messages.first?.role == .user)
        #expect(request.messages.first?.content.text == "Hello")
    }

    @Test func builderChaining() {
        let request = AIRequest.chat("Hello")
            .withSystem("You are a helpful assistant")
            .withMaxTokens(500)
            .withModel("claude-sonnet-4-20250514")
            .withTemperature(0.7)
            .withTopP(0.9)
            .withResponseFormat(.json)

        #expect(request.systemPrompt == "You are a helpful assistant")
        #expect(request.maxTokens == 500)
        #expect(request.model == "claude-sonnet-4-20250514")
        #expect(request.temperature == 0.7)
        #expect(request.topP == 0.9)
        #expect(request.responseFormat == .json)
    }

    @Test func builderWithTools() {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get current weather",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "location": .object(["type": "string"]),
                ]),
            ])
        )

        let request = AIRequest.chat("What's the weather?")
            .withTools([tool])

        #expect(request.tools?.count == 1)
        #expect(request.tools?.first?.name == "get_weather")
    }

    @Test func defaultValuesAreNil() {
        let request = AIRequest.chat("Hello")

        #expect(request.model == nil)
        #expect(request.maxTokens == nil)
        #expect(request.temperature == nil)
        #expect(request.topP == nil)
        #expect(request.systemPrompt == nil)
        #expect(request.tools == nil)
        #expect(request.responseFormat == nil)
    }

    @Test func builderIsImmutable() {
        let original = AIRequest.chat("Hello")
        let modified = original.withMaxTokens(100)

        #expect(original.maxTokens == nil)
        #expect(modified.maxTokens == 100)
    }
}
