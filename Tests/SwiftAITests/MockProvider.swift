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

/// A mock provider that tracks calls and can fail a configurable number of times.
final class TrackingMockProvider: AIProvider, @unchecked Sendable {
    let id: ProviderID
    let capabilities: ProviderCapabilities
    private let _callCount = LockedValue(0)
    private let failCount: Int
    private let responseContent: String

    var callCount: Int { _callCount.value }

    init(
        id: ProviderID = .anthropic,
        failCount: Int = 0,
        responseContent: String = "Tracking response"
    ) {
        self.id = id
        self.failCount = failCount
        self.responseContent = responseContent
        self.capabilities = ProviderCapabilities(
            supportedTasks: [.chat], maxContextTokens: 100_000,
            supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
            costPerMillionInputTokens: 1.0, costPerMillionOutputTokens: 5.0,
            estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
        )
    }

    var isAvailable: Bool { get async { true } }

    func generate(_ request: AIRequest) async throws -> AIResponse {
        let count = _callCount.increment()
        if count <= failCount {
            throw SwiftAIError.networkError(underlying: URLError(.timedOut))
        }
        return AIResponse(
            id: "track-\(UUID().uuidString)",
            content: responseContent,
            model: "track-model",
            provider: id,
            usage: TokenUsage(inputTokens: 10, outputTokens: 20),
            finishReason: .complete
        )
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        let content = responseContent
        let providerID = id
        let count = _callCount.increment()
        let shouldFail = count <= failCount

        return AsyncThrowingStream { continuation in
            if shouldFail {
                continuation.finish(throwing: SwiftAIError.networkError(underlying: URLError(.timedOut)))
                return
            }
            continuation.yield(AIStreamChunk(
                delta: content, accumulatedContent: content, isComplete: true,
                usage: TokenUsage(inputTokens: 10, outputTokens: 5), provider: providerID
            ))
            continuation.finish()
        }
    }
}

/// Thread-safe locked value for test mocks.
private final class LockedValue<T: Sendable>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) { self._value = value }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment() -> Int where T == Int {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
        return _value
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
