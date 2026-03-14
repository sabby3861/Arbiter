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
public final class ConversationSession: Identifiable {
    /// Stable identifier for this conversation
    public let id: UUID = UUID()

    /// When this session was created
    public let createdAt: Date = Date()

    /// All messages in the conversation
    public private(set) var messages: [Message] = []

    /// Whether the session is currently waiting for a response
    public private(set) var isGenerating: Bool = false

    /// The system prompt for this conversation
    public var systemPrompt: String?

    private let maxTokenEstimate: Int
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
        guard !isGenerating else {
            throw SwiftAIError.invalidRequest(reason: "A request is already in progress. Wait for it to complete or cancel it first.")
        }

        let userMessage = Message.user(text)
        messages.append(userMessage)
        isGenerating = true

        do {
            trimToFitTokenWindow()
            try Task.checkCancellation()

            let response = try await withTaskCancellationHandler {
                try await ai.chat(messages, options: mergeOptions(options))
            } onCancel: {
                // URLSession will cancel the underlying network request
            }

            let assistantMessage = Message.assistant(response.content)
            messages.append(assistantMessage)
            isGenerating = false
        } catch {
            // Remove the orphaned user message if no assistant reply was generated
            if messages.last?.role == .user {
                messages.removeLast()
            }
            isGenerating = false
            throw error
        }
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
        guard !isGenerating else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: SwiftAIError.invalidRequest(
                    reason: "A request is already in progress. Wait for it to complete or cancel it first."
                ))
            }
        }

        activeStreamTask?.cancel()

        let userMessage = Message.user(text)
        messages.append(userMessage)
        isGenerating = true
        trimToFitTokenWindow()

        let currentMessages = messages
        let mergedOptions = mergeOptions(options)

        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                var lastContent = ""

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

                // Finalize state on the main actor synchronously within
                // this task, avoiding the fire-and-forget race that a
                // defer + detached Task { @MainActor } would cause.
                await MainActor.run { [self] in
                    if !lastContent.isEmpty {
                        self.messages.append(Message.assistant(lastContent))
                    } else if self.messages.last?.role == .user {
                        // No content received — remove the orphaned user message
                        self.messages.removeLast()
                    }
                    self.isGenerating = false
                    self.activeStreamTask = nil
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
        TokenEstimator.estimateTokens(for: messages)
    }

    func trimToFitTokenWindow() {
        // Keep at least the most recent message (user's latest input)
        while messages.count > 1 && estimateTokens(for: messages) > maxTokenEstimate {
            // Find the oldest non-system message that isn't the last message
            let removable = messages.dropLast().firstIndex(where: { $0.role != .system })
            guard let index = removable else { break }
            messages.remove(at: index)
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
