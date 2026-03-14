// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

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
        #expect(MessageContent.toolResult(toolResult).text == "result")
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
        #expect(!MessageContent.toolCall(toolCall).isImage)
    }

    @Test func toolResultIsNotImage() {
        let result = ToolResult(toolCallId: "1", content: "result")
        #expect(!MessageContent.toolResult(result).isImage)
    }
}
