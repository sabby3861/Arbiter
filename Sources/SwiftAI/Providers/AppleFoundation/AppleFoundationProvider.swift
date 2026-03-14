// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "AppleFoundationProvider")

#if canImport(FoundationModels)
import FoundationModels

/// On-device AI provider using Apple Foundation Models (Apple Intelligence).
///
/// Free, private, and fast for simple tasks like chat, summarization, and classification.
/// Requires Apple Intelligence to be enabled on a supported device.
/// ```swift
/// let ai = SwiftAI {
///     $0.system(AppleFoundationProvider())
/// }
/// ```
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public struct AppleFoundationProvider: AIProvider, Sendable {
    public let id: ProviderID = .appleFoundation

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .summarization, .translation, .structuredOutput],
            maxContextTokens: 4_096,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .fast,
            privacyLevel: .onDevice
        )
    }

    public var isAvailable: Bool {
        get async {
            await AvailabilityChecker.isAppleFoundationAvailable()
        }
    }

    public init() {}

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        try Task.checkCancellation()

        guard await isAvailable else {
            let reason = await AvailabilityChecker.unavailableReason()
            throw SwiftAIError.providerUnavailable(.appleFoundation, reason: reason)
        }

        let session = LanguageModelSession()
        let prompt = buildPrompt(from: request)

        do {
            let response = try await session.respond(to: prompt)

            return AIResponse(
                id: "apple-fm-\(UUID().uuidString)",
                content: response.content,
                model: "apple-foundation",
                provider: .appleFoundation,
                finishReason: .complete
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Apple FM generation failed: \(error.localizedDescription)")
            throw SwiftAIError.providerUnavailable(.appleFoundation, reason: error.localizedDescription)
        }
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(for: request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private extension AppleFoundationProvider {
    func buildPrompt(from request: AIRequest) -> String {
        var parts: [String] = []
        if let systemPrompt = request.systemPrompt {
            parts.append(systemPrompt)
        }
        for message in request.messages {
            if let text = message.content.text {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    func performStream(
        for request: AIRequest,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()

        guard await isAvailable else {
            let reason = await AvailabilityChecker.unavailableReason()
            throw SwiftAIError.providerUnavailable(.appleFoundation, reason: reason)
        }

        let session = LanguageModelSession()
        let prompt = buildPrompt(from: request)

        let responseStream = session.streamResponse(to: prompt)
        var accumulated = ""

        do {
            for try await partial in responseStream {
                try Task.checkCancellation()
                let delta = String(partial.content.dropFirst(accumulated.count))
                accumulated = partial.content

                continuation.yield(AIStreamChunk(
                    delta: delta,
                    accumulatedContent: accumulated,
                    isComplete: false,
                    provider: .appleFoundation
                ))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Apple FM stream failed: \(error.localizedDescription)")
            throw SwiftAIError.providerUnavailable(.appleFoundation, reason: error.localizedDescription)
        }

        continuation.yield(AIStreamChunk(
            delta: "",
            accumulatedContent: accumulated,
            isComplete: true,
            finishReason: .complete,
            provider: .appleFoundation
        ))
    }
}

#else

/// Stub Apple Foundation Models provider when FoundationModels framework is not available.
///
/// Reports as unavailable so the router skips it gracefully.
/// Requires iOS 26+ / macOS 26+ with Apple Intelligence enabled.
public struct AppleFoundationProvider: AIProvider, Sendable {
    public let id: ProviderID = .appleFoundation

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .summarization, .translation, .structuredOutput],
            maxContextTokens: 4_096,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .fast,
            privacyLevel: .onDevice
        )
    }

    public var isAvailable: Bool {
        get async { false }
    }

    public init() {
        logger.debug("Apple Foundation Models stub initialized — FoundationModels framework not linked")
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        throw SwiftAIError.providerUnavailable(
            .appleFoundation,
            reason: "Apple Foundation Models requires iOS 26+ / macOS 26+ with Apple Intelligence enabled."
        )
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: SwiftAIError.providerUnavailable(
                .appleFoundation,
                reason: "Apple Foundation Models requires iOS 26+ / macOS 26+ with Apple Intelligence enabled."
            ))
        }
    }
}

#endif
