// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
@testable import SwiftAI

@Suite("TokenBudgetPlanner")
struct TokenBudgetPlannerTests {
    let planner = TokenBudgetPlanner()

    @Test("Short request fits all providers")
    func shortRequestFits() {
        let request = AIRequest.chat("Hello")
        let capabilities = ProviderCapabilities(
            supportedTasks: [.chat],
            maxContextTokens: 100_000,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .fast,
            privacyLevel: .onDevice
        )
        let check = planner.fits(request: request, provider: capabilities)
        if case .fits(let remaining) = check {
            #expect(remaining > 0)
        } else {
            Issue.record("Expected .fits")
        }
    }

    @Test("Long request exceeds small context window")
    func longRequestExceeds() {
        let longText = String(repeating: "word ", count: 50_000)
        let request = AIRequest.chat(longText)
        let capabilities = ProviderCapabilities(
            supportedTasks: [.chat],
            maxContextTokens: 4_096,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .fast,
            privacyLevel: .onDevice
        )
        let check = planner.fits(request: request, provider: capabilities)
        if case .exceeds(let overage, _) = check {
            #expect(overage > 0)
        } else {
            Issue.record("Expected .exceeds")
        }
    }

    @Test("trimToFit preserves system prompt and latest message")
    func trimPreservesSystemAndLatest() {
        let messages: [Message] = [
            .system("You are helpful"),
            .user("First question"),
            .assistant("First answer"),
            .user("Second question"),
            .assistant("Second answer"),
            .user("Latest question"),
        ]
        let trimmed = planner.trimToFit(
            messages: messages,
            maxTokens: 100,
            reserveForOutput: 50
        )
        #expect(trimmed.first?.role == .system)
        #expect(trimmed.last?.role == .user)
        #expect(trimmed.last?.content.text == "Latest question")
    }

    @Test("trimToFit removes oldest messages first")
    func trimRemovesOldest() {
        let longResponse = String(repeating: "This is a long response. ", count: 20)
        let messages: [Message] = [
            .user("Old message 1"),
            .assistant(longResponse),
            .user("Old message 2"),
            .assistant(longResponse),
            .user("Latest"),
        ]
        let trimmed = planner.trimToFit(
            messages: messages,
            maxTokens: 200,
            reserveForOutput: 50
        )
        #expect(trimmed.count < messages.count)
        #expect(trimmed.last?.content.text == "Latest")
    }

    @Test("trimToFit with only system and user returns both")
    func trimMinimalMessages() {
        let messages: [Message] = [
            .system("System prompt"),
            .user("User question"),
        ]
        let trimmed = planner.trimToFit(
            messages: messages,
            maxTokens: 10,
            reserveForOutput: 5
        )
        #expect(trimmed.count == 2)
        #expect(trimmed.first?.role == .system)
        #expect(trimmed.last?.role == .user)
    }

    @Test("fits suggests reducing max tokens when possible")
    func suggestsReduceMaxTokens() {
        let mediumText = String(repeating: "word ", count: 200)
        let request = AIRequest(
            messages: [.user(mediumText)],
            maxTokens: 2000
        )
        let capabilities = ProviderCapabilities(
            supportedTasks: [.chat],
            maxContextTokens: 2048,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .fast,
            privacyLevel: .onDevice
        )
        let check = planner.fits(request: request, provider: capabilities)
        if case .exceeds(_, let suggestion) = check {
            switch suggestion {
            case .reduceMaxTokens, .trimOldMessages:
                break
            }
        } else {
            Issue.record("Expected .exceeds with suggestion")
        }
    }

    @Test("trimToFit with empty messages returns empty")
    func trimEmptyMessages() {
        let trimmed = planner.trimToFit(
            messages: [],
            maxTokens: 100,
            reserveForOutput: 50
        )
        #expect(trimmed.isEmpty)
    }

    @Test("trimToFit keeps recent messages over older ones")
    func trimKeepsRecent() {
        let messages: [Message] = [
            .system("System"),
            .user("Q1"),
            .assistant("A1 with a moderately long response that takes up tokens"),
            .user("Q2"),
            .assistant("A2 with another moderately long response for testing"),
            .user("Q3"),
        ]
        let trimmed = planner.trimToFit(
            messages: messages,
            maxTokens: 200,
            reserveForOutput: 50
        )
        #expect(trimmed.first?.role == .system)
        #expect(trimmed.last?.content.text == "Q3")
        #expect(trimmed.count <= messages.count)
    }

    @Test("trimToFit single message returns it unchanged")
    func trimSingleMessage() {
        let messages: [Message] = [.user("Only message")]
        let trimmed = planner.trimToFit(
            messages: messages,
            maxTokens: 10,
            reserveForOutput: 5
        )
        #expect(trimmed.count == 1)
        #expect(trimmed.first?.content.text == "Only message")
    }

    @Test("trimToFit single system message does not duplicate")
    func trimSingleSystemMessage() {
        let messages: [Message] = [.system("System only")]
        let trimmed = planner.trimToFit(
            messages: messages,
            maxTokens: 10,
            reserveForOutput: 5
        )
        #expect(trimmed.count == 1)
        #expect(trimmed.first?.role == .system)
    }

    @Test("fits with system prompt accounts for system tokens")
    func fitsWithSystemPrompt() {
        let longSystem = String(repeating: "system context ", count: 5000)
        let request = AIRequest(
            messages: [.user("Hello")],
            systemPrompt: longSystem
        )
        let capabilities = ProviderCapabilities(
            supportedTasks: [.chat],
            maxContextTokens: 4_096,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .fast,
            privacyLevel: .onDevice
        )
        let check = planner.fits(request: request, provider: capabilities)
        if case .exceeds(let overage, _) = check {
            #expect(overage > 0)
        } else {
            Issue.record("Expected .exceeds for large system prompt")
        }
    }
}
