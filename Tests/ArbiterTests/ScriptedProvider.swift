// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
@testable import Arbiter

/// A provider that replays a scripted sequence of turns and remembers what it was sent.
///
/// The agent loop is a conversation, so testing it needs a provider that answers
/// differently each round and lets the test read back the history it received.
///
/// `@unchecked Sendable` with a lock: the recorded requests and the script cursor are
/// mutable state reached from whatever task the runtime is on, and every access below is
/// taken under `lock`. An actor cannot be used because `AIProvider`'s requirements are
/// nonisolated.
final class ScriptedProvider: AIProvider, @unchecked Sendable {
    let id: ProviderID
    let capabilities: ProviderCapabilities

    private let lock = NSLock()
    private var script: [AIResponse]
    private var cursor = 0
    private var received: [AIRequest] = []

    /// Turns the provider replays, in order. The last one repeats if the loop asks again.
    init(
        id: ProviderID = .anthropic,
        script: [AIResponse],
        capabilities: ProviderCapabilities? = nil
    ) {
        self.id = id
        self.script = script
        self.capabilities = capabilities ?? ProviderCapabilities(
            supportedTasks: [.chat, .completion, .structuredOutput],
            maxContextTokens: 100_000,
            supportsStreaming: true,
            supportsToolCalling: true,
            supportsImageInput: false,
            costPerMillionInputTokens: 1.0,
            costPerMillionOutputTokens: 5.0,
            estimatedLatency: .fast,
            privacyLevel: id.tier == .cloud ? .thirdPartyCloud : .onDevice
        )
    }

    var isAvailable: Bool { get async { true } }

    /// Every request the provider was sent, in order.
    var requests: [AIRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cursor
    }

    func generate(_ request: AIRequest) async throws -> AIResponse {
        next(for: request)
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        let response = next(for: request)
        let providerID = id
        return AsyncThrowingStream { continuation in
            var accumulated = ""
            for word in response.content.split(separator: " ") {
                let delta = accumulated.isEmpty ? String(word) : " \(word)"
                accumulated += delta
                continuation.yield(AIStreamChunk(
                    delta: delta, accumulatedContent: accumulated,
                    isComplete: false, provider: providerID
                ))
            }
            continuation.yield(AIStreamChunk(
                delta: "", accumulatedContent: accumulated, isComplete: true,
                usage: response.usage, finishReason: response.finishReason,
                toolCalls: response.toolCalls.isEmpty ? nil : response.toolCalls,
                provider: providerID
            ))
            continuation.finish()
        }
    }

    private func next(for request: AIRequest) -> AIResponse {
        lock.lock()
        defer { lock.unlock() }
        received.append(request)
        let response = script[min(cursor, script.count - 1)]
        cursor += 1
        return response
    }
}

extension AIResponse {
    /// A turn asking for tools, shaped the way a cloud provider reports one.
    static func toolCallTurn(
        _ calls: [ToolCall],
        text: String = "",
        provider: ProviderID = .anthropic,
        thinking: [ThinkingBlock] = []
    ) -> AIResponse {
        AIResponse(
            id: "scripted-\(UUID().uuidString)",
            content: text,
            model: "scripted-model",
            provider: provider,
            toolCalls: calls,
            usage: TokenUsage(inputTokens: 10, outputTokens: 5),
            finishReason: .toolCall,
            thinking: thinking
        )
    }

    /// A finished answer.
    static func answerTurn(
        _ text: String,
        provider: ProviderID = .anthropic,
        toolCalls: [ToolCall] = [],
        finishReason: FinishReason = .complete
    ) -> AIResponse {
        AIResponse(
            id: "scripted-\(UUID().uuidString)",
            content: text,
            model: "scripted-model",
            provider: provider,
            toolCalls: toolCalls,
            usage: TokenUsage(inputTokens: 10, outputTokens: 5),
            finishReason: finishReason
        )
    }
}

/// Records every call it receives, so a test can prove what did and did not run.
final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var active = 0
    private var peakConcurrency = 0

    /// Names recorded, in completion order. Guarded by `lock`, like every field here,
    /// because the loop calls tools from several tasks at once.
    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var maximumConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakConcurrency
    }

    func begin() {
        lock.lock()
        active += 1
        peakConcurrency = max(peakConcurrency, active)
        lock.unlock()
    }

    func end(_ name: String) {
        lock.lock()
        active -= 1
        entries.append(name)
        lock.unlock()
    }
}
