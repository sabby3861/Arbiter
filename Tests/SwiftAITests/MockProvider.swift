// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
@testable import SwiftAI

/// A mock AI provider for testing
struct MockProvider: AIProvider, Sendable {
    let id: ProviderID
    let capabilities: ProviderCapabilities
    let available: Bool
    let responseContent: String
    let responseModel: String
    let shouldError: SwiftAIError?

    init(
        id: ProviderID = .anthropic,
        available: Bool = true,
        responseContent: String = "Mock response",
        responseModel: String = "mock-model",
        shouldError: SwiftAIError? = nil,
        capabilities: ProviderCapabilities? = nil
    ) {
        self.id = id
        self.available = available
        self.responseContent = responseContent
        self.responseModel = responseModel
        self.shouldError = shouldError
        self.capabilities = capabilities ?? ProviderCapabilities(
            supportedTasks: [.chat, .completion],
            maxContextTokens: 100_000,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: 1.0,
            costPerMillionOutputTokens: 5.0,
            estimatedLatency: .fast,
            privacyLevel: .thirdPartyCloud
        )
    }

    var isAvailable: Bool {
        get async { available }
    }

    func generate(_ request: AIRequest) async throws -> AIResponse {
        if let error = shouldError { throw error }

        return AIResponse(
            id: "mock-\(UUID().uuidString)",
            content: responseContent,
            model: responseModel,
            provider: id,
            usage: TokenUsage(inputTokens: 10, outputTokens: 20),
            finishReason: .complete
        )
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        let content = responseContent
        let providerID = id
        let streamError = shouldError

        return AsyncThrowingStream { continuation in
            let task = Task {
                if let error = streamError {
                    continuation.finish(throwing: error)
                    return
                }

                let words = content.split(separator: " ")
                var accumulated = ""

                for (index, word) in words.enumerated() {
                    let delta = (index == 0 ? "" : " ") + word
                    accumulated += delta

                    continuation.yield(AIStreamChunk(
                        delta: String(delta),
                        accumulatedContent: accumulated,
                        isComplete: false,
                        provider: providerID
                    ))
                }

                continuation.yield(AIStreamChunk(
                    delta: "",
                    accumulatedContent: accumulated,
                    isComplete: true,
                    usage: TokenUsage(inputTokens: 10, outputTokens: words.count),
                    provider: providerID
                ))

                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// A mock provider that simulates on-device privacy
struct MockLocalProvider: AIProvider, Sendable {
    let id: ProviderID = .mlx

    let capabilities = ProviderCapabilities(
        supportedTasks: [.chat, .completion],
        maxContextTokens: 8_000,
        supportsStreaming: true,
        supportsToolCalling: false,
        supportsImageInput: false,
        costPerMillionInputTokens: nil,
        costPerMillionOutputTokens: nil,
        estimatedLatency: .fast,
        privacyLevel: .onDevice
    )

    var isAvailable: Bool {
        get async { true }
    }

    func generate(_ request: AIRequest) async throws -> AIResponse {
        AIResponse(
            id: "local-\(UUID().uuidString)",
            content: "Local response",
            model: "mlx-local",
            provider: .mlx
        )
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(AIStreamChunk(
                delta: "Local response",
                accumulatedContent: "Local response",
                isComplete: true,
                provider: .mlx
            ))
            continuation.finish()
        }
    }
}
