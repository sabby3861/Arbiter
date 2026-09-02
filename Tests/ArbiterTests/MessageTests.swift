// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("Message")
struct MessageTests {
    @Test func userConvenienceInit() {
        let message = Message.user("Hello")
        #expect(message.role == .user)
        #expect(message.content.text == "Hello")
    }

    @Test func assistantConvenienceInit() {
        let message = Message.assistant("Hi there")
        #expect(message.role == .assistant)
        #expect(message.content.text == "Hi there")
    }

    @Test func systemConvenienceInit() {
        let message = Message.system("You are helpful")
        #expect(message.role == .system)
        #expect(message.content.text == "You are helpful")
    }

    @Test func messageHasUniqueID() {
        let message1 = Message.user("Hello")
        let message2 = Message.user("Hello")
        #expect(message1.id != message2.id)
    }

    @Test func textMessageCodableRoundTrip() throws {
        let original = Message.user("Test message")

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.role == .user)
        #expect(decoded.content.text == "Test message")
    }

    @Test func roleCodableRoundTrip() throws {
        let roles: [Role] = [.system, .user, .assistant, .tool]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for role in roles {
            let data = try encoder.encode(role)
            let decoded = try decoder.decode(Role.self, from: data)
            #expect(decoded == role)
        }
    }

    @Test func messageContentTextExtraction() throws {
        #expect(MessageContent.text("hello").text == "hello")

        let exampleURL = try #require(URL(string: "https://example.com"))
        #expect(MessageContent.image(.url(exampleURL)).text == nil)

        let toolResult = ToolResult(toolCallId: "1", content: "result")
        #expect(MessageContent.toolResults([toolResult]).text == "result")
    }

    @Test func toolCallCodable() throws {
        let toolCall = ToolCall(
            id: "call_123",
            name: "get_weather",
            arguments: .object(["location": .string("Tokyo")])
        )

        let data = try JSONEncoder().encode(toolCall)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)

        #expect(decoded.id == "call_123")
        #expect(decoded.name == "get_weather")
        #expect(decoded.arguments == .object(["location": .string("Tokyo")]))
    }

    @Test func toolResultCodable() throws {
        let result = ToolResult(toolCallId: "call_123", content: "Sunny, 72°F")

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)

        #expect(decoded.toolCallId == "call_123")
        #expect(decoded.content == "Sunny, 72°F")
    }

    @Test func textIsNotImage() {
        #expect(!MessageContent.text("hello").isImage)
    }

    @Test func imageIsImage() throws {
        let url = try #require(URL(string: "https://example.com/image.png"))
        #expect(MessageContent.image(.url(url)).isImage)
    }

    @Test func base64ImageIsImage() {
        #expect(MessageContent.image(.base64(data: "abc", mimeType: "image/png")).isImage)
    }

    @Test func mixedWithImageIsImage() throws {
        let url = try #require(URL(string: "https://example.com/image.png"))
        let mixed = MessageContent.mixed([.text("Caption"), .image(.url(url))])
        #expect(mixed.isImage)
    }

    @Test func mixedWithoutImageIsNotImage() {
        let mixed = MessageContent.mixed([.text("A"), .text("B")])
        #expect(!mixed.isImage)
    }

    @Test func toolCallIsNotImage() {
        let toolCall = ToolCall(id: "1", name: "test", arguments: .null)
        #expect(!MessageContent.toolCalls([toolCall]).isImage)
    }

    @Test func toolResultIsNotImage() {
        let result = ToolResult(toolCallId: "1", content: "result")
        #expect(!MessageContent.toolResults([result]).isImage)
    }

    // MARK: - Parallel tool calls

    /// Three calls issued in one assistant turn must survive a Codable round trip
    /// with their order and arguments intact.
    @Test func parallelToolCallsCodableRoundTrip() throws {
        let calls = [
            ToolCall(id: "call_1", name: "get_weather", arguments: .object(["city": .string("Tokyo")])),
            ToolCall(id: "call_2", name: "get_time", arguments: .object(["tz": .string("JST")])),
            ToolCall(id: "call_3", name: "get_stock", arguments: .object(["ticker": .string("AAPL"), "days": .number(5)])),
        ]
        let original = Message(role: .assistant, content: .toolCalls(calls))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == original)
        #expect(decoded.content.allToolCalls.map(\.id) == ["call_1", "call_2", "call_3"])
        #expect(decoded.content.allToolCalls[2].arguments == .object([
            "ticker": .string("AAPL"), "days": .number(5),
        ]))
    }

    @Test func parallelToolResultsCodableRoundTrip() throws {
        let results = [
            ToolResult(toolCallId: "call_1", name: "get_weather", content: "Sunny"),
            ToolResult(toolCallId: "call_2", name: "get_time", content: "14:05"),
            ToolResult(toolCallId: "call_3", name: "get_stock", content: "232.10"),
        ]
        let original = Message(role: .tool, content: .toolResults(results))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == original)
        #expect(decoded.content.allToolResults.map(\.toolCallId) == ["call_1", "call_2", "call_3"])
    }

    @Test func mixedContentCarriesToolParts() throws {
        let call = ToolCall(id: "call_1", name: "search", arguments: .object(["q": .string("swift")]))
        let result = ToolResult(toolCallId: "call_1", name: "search", content: "42 hits")
        let original = Message(
            role: .assistant,
            content: .mixed([.text("Let me look that up."), .toolCalls([call]), .toolResults([result])])
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        #expect(decoded == original)
        #expect(decoded.content.allToolCalls == [call])
        #expect(decoded.content.allToolResults == [result])
    }

    @Test func nestedMixedFlattensToolContent() {
        let outer = ToolCall(id: "a", name: "outer", arguments: .null)
        let inner = ToolCall(id: "b", name: "inner", arguments: .null)
        let content = MessageContent.mixed([
            .toolCalls([outer]),
            .mixed([.text("nested"), .toolCalls([inner])]),
        ])

        #expect(content.allToolCalls.map(\.id) == ["a", "b"])
    }

    @Test func toolResultsTextJoinsAllResults() {
        let content = MessageContent.toolResults([
            ToolResult(toolCallId: "1", content: "first"),
            ToolResult(toolCallId: "2", content: "second"),
        ])
        #expect(content.text == "first\nsecond")
    }

    @Test func emptyToolResultsHaveNoText() {
        #expect(MessageContent.toolResults([]).text == nil)
    }

    /// Conversations persisted before parallel tool calls were modelled must still decode.
    @Test func legacySingularToolCallPayloadDecodes() throws {
        let json = """
        {"type":"toolCall","toolCall":{"id":"call_1","name":"get_weather","arguments":{"city":"Tokyo"}}}
        """
        let decoded = try JSONDecoder().decode(MessageContent.self, from: Data(json.utf8))

        #expect(decoded == .toolCalls([
            ToolCall(id: "call_1", name: "get_weather", arguments: .object(["city": .string("Tokyo")])),
        ]))
    }

    @Test func legacySingularToolResultPayloadDecodes() throws {
        let json = """
        {"type":"toolResult","toolResult":{"toolCallId":"call_1","content":"Sunny"}}
        """
        let decoded = try JSONDecoder().decode(MessageContent.self, from: Data(json.utf8))

        #expect(decoded == .toolResults([ToolResult(toolCallId: "call_1", content: "Sunny")]))
    }

    @available(*, deprecated, message: "Exercises the deprecated singular shims on purpose.")
    @Test func deprecatedSingularShimsWrapIntoPluralCases() {
        let call = ToolCall(id: "call_1", name: "ping", arguments: .null)
        let result = ToolResult(toolCallId: "call_1", content: "pong")

        #expect(MessageContent.toolCall(call) == .toolCalls([call]))
        #expect(MessageContent.toolResult(result) == .toolResults([result]))
    }
}
