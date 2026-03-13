// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Observation

/// Manages multi-turn conversation state with token window management.
///
/// Designed for SwiftUI binding — all mutations happen on the main actor.
/// ```swift
/// @State private var session = ConversationSession(maxTokenEstimate: 100_000)
///
/// ForEach(session.messages) { message in
///     MessageBubble(message)
/// }
/// ```
@MainActor
@Observable
public final class ConversationSession {
    /// All messages in the conversation
    public private(set) var messages: [Message] = []

    /// Whether the session is currently waiting for a response
    public private(set) var isGenerating: Bool = false

    /// The system prompt for this conversation
    public var systemPrompt: String?

    private let maxTokenEstimate: Int
    private let tokensPerCharacterEstimate: Double = 0.25
    private var activeStreamTask: Task<Void, Never>?

    /// Create a conversation session
    /// - Parameters:
    ///   - maxTokenEstimate: Approximate token budget for the conversation window
    ///   - systemPrompt: Optional system prompt to include with every request
    public init(maxTokenEstimate: Int = 100_000, systemPrompt: String? = nil) {
        self.maxTokenEstimate = maxTokenEstimate
        self.systemPrompt = systemPrompt
    }

    /// Add a user message and generate a response using the given AI instance
    public func send(_ text: String, using ai: SwiftAI, options: RequestOptions? = nil) async throws {
        let userMessage = Message.user(text)
        messages.append(userMessage)
        isGenerating = true

        defer { isGenerating = false }

        trimToFitTokenWindow()

        try Task.checkCancellation()

        let response = try await withTaskCancellationHandler {
            try await ai.chat(messages, options: mergeOptions(options))
        } onCancel: {
            // URLSession will cancel the underlying network request
        }

        let assistantMessage = Message.assistant(response.content)
        messages.append(assistantMessage)
    }

    /// Add a user message and stream the response
    ///
    /// The stream automatically appends the final assistant message and resets
    /// `isGenerating` on completion, error, or cancellation.
    public func sendStreaming(
        _ text: String,
        using ai: SwiftAI,
        options: RequestOptions? = nil
    ) -> AsyncThrowingStream<AIStreamChunk, Error> {
        activeStreamTask?.cancel()

        let userMessage = Message.user(text)
        messages.append(userMessage)
        isGenerating = true
        trimToFitTokenWindow()

        let currentMessages = messages
        let mergedOptions = mergeOptions(options)

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                var lastContent = ""
                defer {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if !lastContent.isEmpty {
                            self.messages.append(Message.assistant(lastContent))
                        }
                        self.isGenerating = false
                        self.activeStreamTask = nil
                    }
                }

                do {
                    let stream = ai.chatStream(currentMessages, options: mergedOptions)
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        lastContent = chunk.accumulatedContent
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            self.activeStreamTask = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Cancel any in-progress streaming generation
    public func cancelGeneration() {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        isGenerating = false
    }

    /// Clear all messages in the conversation
    public func reset() {
        cancelGeneration()
        messages.removeAll()
    }

    /// Estimated token count for the current conversation
    public var estimatedTokenCount: Int {
        estimateTokens(for: messages)
    }
}

private extension ConversationSession {
    func estimateTokens(for messages: [Message]) -> Int {
        let characterCount = messages.reduce(0) { total, message in
            total + (message.content.text?.count ?? 0)
        }
        return Int(Double(characterCount) * tokensPerCharacterEstimate)
    }

    func trimToFitTokenWindow() {
        while messages.count > 2 && estimateTokens(for: messages) > maxTokenEstimate {
            if let firstNonSystemIndex = messages.firstIndex(where: { $0.role != .system }) {
                messages.remove(at: firstNonSystemIndex)
            } else {
                break
            }
        }
    }

    func mergeOptions(_ options: RequestOptions?) -> RequestOptions {
        var merged = options ?? RequestOptions()
        if merged.systemPrompt == nil {
            merged.systemPrompt = systemPrompt
        }
        return merged
    }
}
