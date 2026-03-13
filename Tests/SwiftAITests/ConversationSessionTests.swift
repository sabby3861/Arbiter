// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("ConversationSession")
struct ConversationSessionTests {
    @Test @MainActor func initialStateIsEmpty() {
        let session = ConversationSession()
        #expect(session.messages.isEmpty)
        #expect(!session.isGenerating)
        #expect(session.systemPrompt == nil)
        #expect(session.estimatedTokenCount == 0)
    }

    @Test @MainActor func initWithSystemPrompt() {
        let session = ConversationSession(systemPrompt: "Be helpful")
        #expect(session.systemPrompt == "Be helpful")
    }

    @Test @MainActor func sendAppendsUserAndAssistantMessages() async throws {
        let ai = SwiftAI(provider: MockProvider(responseContent: "Hello back"))
        let session = ConversationSession()

        try await session.send("Hi", using: ai)

        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[0].content.text == "Hi")
        #expect(session.messages[1].role == .assistant)
        #expect(session.messages[1].content.text == "Hello back")
    }

    @Test @MainActor func sendSetsIsGeneratingDuringRequest() async throws {
        let ai = SwiftAI(provider: MockProvider(responseContent: "Done"))
        let session = ConversationSession()

        try await session.send("Test", using: ai)

        #expect(!session.isGenerating)
    }

    @Test @MainActor func multiTurnConversation() async throws {
        let ai = SwiftAI(provider: MockProvider(responseContent: "Reply"))
        let session = ConversationSession()

        try await session.send("First", using: ai)
        try await session.send("Second", using: ai)

        #expect(session.messages.count == 4)
        #expect(session.messages[0].content.text == "First")
        #expect(session.messages[2].content.text == "Second")
    }

    @Test @MainActor func resetClearsMessages() async throws {
        let ai = SwiftAI(provider: MockProvider(responseContent: "Reply"))
        let session = ConversationSession()

        try await session.send("Hello", using: ai)
        session.reset()

        #expect(session.messages.isEmpty)
        #expect(!session.isGenerating)
    }

    @Test @MainActor func systemPromptMergedIntoOptions() async throws {
        let ai = SwiftAI(provider: MockProvider(responseContent: "Reply"))
        let session = ConversationSession(systemPrompt: "Be concise")

        try await session.send("Test", using: ai)

        #expect(session.messages.count == 2)
    }

    @Test @MainActor func estimatedTokenCountReflectsContent() async throws {
        let ai = SwiftAI(provider: MockProvider(responseContent: "Short"))
        let session = ConversationSession()

        #expect(session.estimatedTokenCount == 0)
        try await session.send("Hello world test message", using: ai)
        #expect(session.estimatedTokenCount > 0)
    }

    @Test @MainActor func trimToFitTokenWindowRemovesOldMessages() async throws {
        let ai = SwiftAI(provider: MockProvider(responseContent: String(repeating: "word ", count: 200)))
        let session = ConversationSession(maxTokenEstimate: 100)

        for i in 0..<10 {
            try await session.send("Message \(i) with some padding text", using: ai)
        }

        // Should have trimmed older messages to stay within window
        #expect(session.messages.count < 20)
    }

    @Test @MainActor func cancelGenerationSetsStateCorrectly() {
        let session = ConversationSession()
        session.cancelGeneration()
        #expect(!session.isGenerating)
    }

    @Test @MainActor func sendWithProviderError() async throws {
        let ai = SwiftAI(provider: MockProvider(
            shouldError: .invalidRequest(reason: "Bad input")
        ))
        let session = ConversationSession()

        await #expect(throws: SwiftAIError.self) {
            try await session.send("Bad", using: ai)
        }

        // User message was added, but no assistant message
        #expect(session.messages.count == 1)
        #expect(!session.isGenerating)
    }

    @Test @MainActor func streamingAppendsAssistantMessage() async throws {
        let ai = SwiftAI(provider: MockProvider(responseContent: "Streamed response"))
        let session = ConversationSession()

        let stream = session.sendStreaming("Hello", using: ai)
        for try await _ in stream {}

        // Yield to MainActor to let the deferred cleanup block execute
        for _ in 0..<10 {
            await Task.yield()
            if session.messages.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(session.messages.count == 2)
        #expect(session.messages[1].role == .assistant)
    }
}
