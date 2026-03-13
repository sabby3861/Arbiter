// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("SwiftAI Core")
struct SwiftAITests {
    @Test func singleProviderInit() async throws {
        let mock = MockProvider()
        let ai = SwiftAI(provider: mock)
        let response = try await ai.generate("Hello")

        #expect(response.content == "Mock response")
        #expect(response.provider == .anthropic)
        #expect(response.finishReason == .complete)
    }

    @Test func multiProviderInit() async throws {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic, responseContent: "Anthropic response"))
            $0.cloud(MockProvider(id: .openAI, responseContent: "OpenAI response"))
            $0.routing(.firstAvailable)
        }

        let response = try await ai.generate("Hello")
        #expect(response.content == "Anthropic response")
        #expect(response.provider == .anthropic)
    }

    @Test func specificProviderRouting() async throws {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic, responseContent: "Anthropic"))
            $0.cloud(MockProvider(id: .openAI, responseContent: "OpenAI"))
        }

        let options = RequestOptions(provider: .openAI)
        let response = try await ai.generate("Hello", options: options)
        #expect(response.content == "OpenAI")
    }

    @Test func unavailableProviderThrows() async throws {
        let ai = SwiftAI(provider: MockProvider(available: false))

        await #expect(throws: SwiftAIError.self) {
            try await ai.generate("Hello")
        }
    }

    @Test func chatWithMessageHistory() async throws {
        let mock = MockProvider(responseContent: "Chat response")
        let ai = SwiftAI(provider: mock)

        let messages: [Message] = [
            .user("What is Swift?"),
            .assistant("Swift is a programming language."),
            .user("Tell me more."),
        ]

        let response = try await ai.chat(messages)
        #expect(response.content == "Chat response")
    }

    @Test func streamResponse() async throws {
        let mock = MockProvider(responseContent: "Hello world from stream")
        let ai = SwiftAI(provider: mock)

        var chunks: [AIStreamChunk] = []
        let stream = ai.stream("Hello")
        for try await chunk in stream {
            chunks.append(chunk)
        }

        #expect(!chunks.isEmpty)
        let lastChunk = try #require(chunks.last)
        #expect(lastChunk.isComplete)
        #expect(lastChunk.accumulatedContent == "Hello world from stream")
    }

    @Test func privacyRoutingBlocksCloud() async throws {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic))
        }

        let options = RequestOptions(privacyRequired: true)
        await #expect(throws: SwiftAIError.self) {
            try await ai.generate("Secret data", options: options)
        }
    }

    @Test func privacyRoutingUsesLocalProvider() async throws {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic, responseContent: "Cloud"))
            $0.local(MockLocalProvider())
        }

        let options = RequestOptions(privacyRequired: true)
        let response = try await ai.generate("Secret data", options: options)
        #expect(response.provider == .mlx)
    }

    @Test func preferLocalRouting() async throws {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic, responseContent: "Cloud"))
            $0.local(MockLocalProvider())
            $0.routing(.preferLocal)
        }

        let response = try await ai.generate("Hello")
        #expect(response.provider == .mlx)
    }

    @Test func preferCloudRouting() async throws {
        let ai = SwiftAI {
            $0.local(MockLocalProvider())
            $0.cloud(MockProvider(id: .openAI, responseContent: "Cloud"))
            $0.routing(.preferCloud)
        }

        let response = try await ai.generate("Hello")
        #expect(response.provider == .openAI)
    }

    @Test func allProvidersFailed() async throws {
        let ai = SwiftAI {
            $0.cloud(MockProvider(id: .anthropic, available: false))
            $0.cloud(MockProvider(id: .openAI, available: false))
        }

        await #expect(throws: SwiftAIError.self) {
            try await ai.generate("Hello")
        }
    }

    @Test func providerErrorPropagates() async throws {
        let ai = SwiftAI(provider: MockProvider(
            shouldError: .invalidRequest(reason: "Bad prompt")
        ))

        await #expect(throws: SwiftAIError.self) {
            try await ai.generate("Hello")
        }
    }

    @Test func streamErrorPropagates() async throws {
        let ai = SwiftAI(provider: MockProvider(
            shouldError: .authenticationFailed(.anthropic)
        ))

        var caughtError = false
        let stream = ai.stream("Hello")
        do {
            for try await _ in stream {}
        } catch is SwiftAIError {
            caughtError = true
        }
        #expect(caughtError)
    }

    @Test func requestOptionsPassthrough() async throws {
        let mock = MockProvider(responseContent: "Response")
        let ai = SwiftAI(provider: mock)

        let options = RequestOptions(
            maxTokens: 500,
            temperature: 0.7,
            systemPrompt: "Be helpful"
        )
        let response = try await ai.generate("Hello", options: options)
        #expect(response.content == "Response")
    }
}

@Suite("Concurrency")
struct ConcurrencyTests {
    @Test func concurrentGenerateCalls() async throws {
        let mock = MockProvider(responseContent: "Response")
        let ai = SwiftAI(provider: mock)

        try await withThrowingTaskGroup(of: AIResponse.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await ai.generate("Message \(i)")
                }
            }

            var responseCount = 0
            for try await response in group {
                #expect(response.content == "Response")
                responseCount += 1
            }
            #expect(responseCount == 10)
        }
    }

    @Test func taskCancellationPropagates() async throws {
        let slowProvider = SlowMockProvider(delay: .seconds(10))
        let ai = SwiftAI(provider: slowProvider)

        let task = Task {
            try await ai.generate("This should be cancelled")
        }

        // Give the task a moment to start, then cancel it
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            Issue.record("Expected cancellation, got success")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    @Test func streamCancellationStopsYielding() async throws {
        let mock = MockProvider(responseContent: "word1 word2 word3 word4 word5")
        let ai = SwiftAI(provider: mock)

        var receivedChunks = 0
        let stream = ai.stream("Hello")

        for try await _ in stream {
            receivedChunks += 1
            if receivedChunks >= 2 {
                break
            }
        }

        #expect(receivedChunks >= 2)
    }

    @Test func concurrentProviderAvailabilityChecks() async throws {
        let ai = SwiftAI {
            $0.cloud(SlowMockProvider(delay: .milliseconds(100), available: false))
            $0.cloud(SlowMockProvider(delay: .milliseconds(100), available: false))
            $0.cloud(MockProvider(id: .gemini, responseContent: "Gemini"))
        }

        let response = try await ai.generate("Hello")
        #expect(response.content == "Gemini")
    }

    @Test func spendingGuardAtomicReservation() async throws {
        let guard_ = SpendingGuard(budgetLimit: 1.0)

        // Two concurrent reservations that individually fit but together exceed budget
        await withThrowingTaskGroup(of: Void.self) { group in
            var successCount = 0
            var failCount = 0

            for _ in 0..<20 {
                group.addTask {
                    _ = try await guard_.reserveBudget(estimatedCost: 0.1)
                }
            }

            while let result = await group.nextResult() {
                switch result {
                case .success: successCount += 1
                case .failure: failCount += 1
                }
            }

            // Budget is 1.0, each reservation is 0.1, so exactly 10 should succeed
            #expect(successCount == 10)
            #expect(failCount == 10)
        }
    }

    @Test func spendingGuardReservationReleaseOnCancel() async throws {
        let guard_ = SpendingGuard(budgetLimit: 0.5)

        let reservation = try #require(try await guard_.reserveBudget(estimatedCost: 0.3))
        #expect(await guard_.remainingBudget == 0.2)

        // Simulate request cancellation — release reserved amount
        await guard_.finalizeReservation(reservation, actualCost: 0)
        #expect(await guard_.currentSpend == 0.0)
        #expect(await guard_.remainingBudget == 0.5)
    }
}

/// A mock provider that introduces artificial delay for testing cancellation and concurrency
struct SlowMockProvider: AIProvider, Sendable {
    let id: ProviderID = .anthropic
    let delay: Duration
    let available: Bool

    let capabilities = ProviderCapabilities(
        supportedTasks: [.chat],
        maxContextTokens: 100_000,
        supportsStreaming: false,
        supportsToolCalling: false,
        supportsImageInput: false,
        costPerMillionInputTokens: 1.0,
        costPerMillionOutputTokens: 5.0,
        estimatedLatency: .slow,
        privacyLevel: .thirdPartyCloud
    )

    init(delay: Duration = .seconds(1), available: Bool = true) {
        self.delay = delay
        self.available = available
    }

    var isAvailable: Bool {
        get async {
            try? await Task.sleep(for: delay)
            return available
        }
    }

    func generate(_ request: AIRequest) async throws -> AIResponse {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        return AIResponse(
            id: "slow-\(UUID().uuidString)",
            content: "Slow response",
            model: "slow-model",
            provider: .anthropic
        )
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(AIStreamChunk(
                delta: "Slow",
                accumulatedContent: "Slow",
                isComplete: true,
                provider: .anthropic
            ))
            continuation.finish()
        }
    }
}
