// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

/// Extended thinking survives a tool round-trip only if the block's opaque signature comes
/// back with it, so these pin the whole path: parsed off the response, carried in the
/// message model, and put back on the wire unchanged.
@Suite("Thinking replay")
struct ThinkingReplayTests {
    static let signed = ThinkingBlock(text: "Let me work through this.", signature: "sig-abc123")
    static let redacted = ThinkingBlock.redacted(data: "EncryptedPayload==")

    @Test func thinkingContentRoundTripsThroughCodable() throws {
        let original = Message(
            role: .assistant,
            content: .mixed([
                .thinking([Self.signed, Self.redacted]),
                .text("Here goes"),
                .toolCalls([ToolCall(id: "c1", name: "search", arguments: .object([:]))]),
            ])
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == original)
        let blocks = decoded.content.allThinking
        #expect(blocks.count == 2)
        #expect(blocks[0].signature == "sig-abc123")
        #expect(blocks[1].isRedacted)
        #expect(blocks[1].redactedData == "EncryptedPayload==")
        // Thinking is not the turn's answer, so it never reads as the message's text.
        #expect(MessageContent.thinking([Self.signed]).text == nil)
    }

    @Test func anthropicSendsThinkingFirstWithItsSignature() throws {
        let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)
        let request = AIRequest(messages: [
            .user("Weather in Tokyo?"),
            Message(role: .assistant, content: .mixed([
                .text("Looking that up."),
                .thinking([Self.signed, Self.redacted]),
                .toolCalls([ToolCall(
                    id: "call_weather", name: "get_weather",
                    arguments: .object(["city": .string("Tokyo")])
                )]),
            ])),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "call_weather", name: "get_weather", content: "Sunny"),
            ])),
        ])

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let blocks = try #require(messages[1]["content"] as? [[String: Any]])

        // Thinking leads the turn even though the caller wrote text first, because the API
        // requires it there.
        #expect(blocks.map { $0["type"] as? String }
            == ["thinking", "redacted_thinking", "text", "tool_use"])
        #expect(blocks[0]["thinking"] as? String == "Let me work through this.")
        #expect(blocks[0]["signature"] as? String == "sig-abc123")
        #expect(blocks[1]["data"] as? String == "EncryptedPayload==")
    }

    @Test func anUnsignedThinkingBlockIsDroppedRatherThanRejectedByTheAPI() throws {
        let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)
        let request = AIRequest(messages: [
            .user("Hello"),
            Message(role: .assistant, content: .mixed([
                .thinking([ThinkingBlock(text: "No signature here")]),
                .text("Hi"),
            ])),
            .user("Again"),
        ])

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let blocks = try #require(messages[1]["content"] as? [[String: Any]])

        #expect(blocks.map { $0["type"] as? String } == ["text"])
    }

    @Test func thinkingOnANonAssistantTurnIsNotSent() throws {
        let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)
        let request = AIRequest(messages: [
            Message(role: .user, content: .mixed([
                .thinking([Self.signed]),
                .text("Hello"),
            ])),
        ])

        let data = try mapper.buildRequestBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])

        #expect(blocks.map { $0["type"] as? String } == ["text"])
    }

    @Test func anthropicParsesThinkingBlocksWithTheirSignatures() throws {
        let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)
        let body = """
            {"id":"msg_1","model":"claude-sonnet-5","stop_reason":"tool_use",
             "content":[
               {"type":"thinking","thinking":"Working it out","signature":"sig-xyz"},
               {"type":"redacted_thinking","data":"Encrypted=="},
               {"type":"text","text":"Checking the weather"},
               {"type":"tool_use","id":"call_1","name":"get_weather","input":{"city":"Tokyo"}}],
             "usage":{"input_tokens":10,"output_tokens":20}}
            """

        let response = try mapper.parseResponse(Data(body.utf8))

        #expect(response.thinking.count == 2)
        #expect(response.thinking[0].text == "Working it out")
        #expect(response.thinking[0].signature == "sig-xyz")
        #expect(response.thinking[1].redactedData == "Encrypted==")
        // The readable form is unchanged for callers that only want to show it.
        #expect(response.reasoning == "Working it out")
        #expect(response.finishReason == .toolCall)
    }

    @Test func theToolLoopReplaysThinkingUnchangedOnTheNextRound() async throws {
        let call = ToolCall(id: "c1", name: "search", arguments: .object(["q": .string("ada")]))
        let provider = ScriptedProvider(script: [
            .toolCallTurn([call], text: "Looking it up", thinking: [Self.signed, Self.redacted]),
            .answerTurn("Ada Lovelace"),
        ])
        let ai = Arbiter(provider: provider)
        let tool = FunctionTool(
            name: "search", description: "Search", inputSchema: .object([:])
        ) { _, _ in "found" }

        let result = try await ai.run([.user("Who is Ada?")], tools: [tool])

        #expect(result.content == "Ada Lovelace")
        // The second request carries the assistant turn as the model produced it.
        let replayed = provider.requests[1].messages[1]
        #expect(replayed.role == .assistant)
        #expect(replayed.content.allThinking == [Self.signed, Self.redacted])
        #expect(replayed.content.allToolCalls == [call])

        // And that turn maps onto the wire with its signature intact.
        let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)
        let data = try mapper.buildRequestBody(provider.requests[1], stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let blocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(blocks[0]["signature"] as? String == "sig-abc123")
        #expect(blocks.last?["type"] as? String == "tool_use")
    }
}
