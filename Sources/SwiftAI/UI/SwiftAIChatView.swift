// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

/// A complete, drop-in chat interface for SwiftAI.
///
/// Provides message bubbles, streaming animation, provider badges,
/// loading states, error handling with retry, and dark mode support.
///
/// ```swift
/// SwiftAIChatView(ai: ai)
/// SwiftAIChatView(ai: ai, systemPrompt: "You are a helpful assistant.")
/// ```
public struct SwiftAIChatView: View {
    private let ai: SwiftAI
    private let systemPrompt: String?
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var lastError: (any Error)?
    @State private var streamingText = ""
    @State private var isStreaming = false
    @State private var streamingProvider: ProviderID?
    @State private var activeTask: Task<Void, Never>?
    @State private var lastFailedMessage: String?

    public init(ai: SwiftAI) {
        self.ai = ai
        self.systemPrompt = nil
    }

    public init(ai: SwiftAI, systemPrompt: String) {
        self.ai = ai
        self.systemPrompt = systemPrompt
    }

    public var body: some View {
        VStack(spacing: 0) {
            messageList
            if let error = lastError {
                errorBanner(error)
            }
            inputBar
            poweredByIndicator
        }
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }

                    if isStreaming {
                        streamingBubble
                            .id("streaming")
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: streamingText) { _, _ in
                scrollToBottom(proxy: proxy, anchor: .bottom)
            }
        }
    }

    private var streamingBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(streamingText.isEmpty ? "..." : streamingText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(ChatColors.bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.primary)

                if let provider = streamingProvider {
                    Text("via \(provider.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 14)
                }
            }
            Spacer(minLength: 40)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(ChatColors.inputBackground)
                )
                .disabled(isStreaming)

            sendButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var sendButton: some View {
        if isStreaming {
            Button {
                cancelGeneration()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
        } else {
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(trimmedInput.isEmpty ? .gray : .blue)
            }
            .disabled(trimmedInput.isEmpty)
        }
    }

    private var poweredByIndicator: some View {
        Group {
            if let provider = streamingProvider ?? messages.last(where: { $0.role == .assistant })?.provider {
                Text("Powered by \(provider.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .padding(.bottom, 4)
            }
        }
    }

    private func errorBanner(_ error: any Error) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(error.localizedDescription)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button("Retry") {
                lastError = nil
                sendMessage()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            Button {
                lastError = nil
                lastFailedMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(ChatColors.inputBackground)
    }

    private func sendMessage() {
        let text = lastFailedMessage ?? trimmedInput
        guard !text.isEmpty else { return }
        lastFailedMessage = nil
        inputText = ""
        lastError = nil

        messages.append(ChatMessage(role: .user, text: text, provider: nil))

        activeTask = Task {
            isStreaming = true
            streamingText = ""
            streamingProvider = nil

            do {
                var conversationMessages = messages.map { chatMsg -> Message in
                    chatMsg.role == .user ? .user(chatMsg.text) : .assistant(chatMsg.text)
                }
                if let systemPrompt {
                    conversationMessages.insert(.system(systemPrompt), at: 0)
                }

                let stream = ai.chatStream(conversationMessages)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    streamingText = chunk.accumulatedContent
                    streamingProvider = chunk.provider
                }

                if !streamingText.isEmpty {
                    messages.append(ChatMessage(
                        role: .assistant,
                        text: streamingText,
                        provider: streamingProvider
                    ))
                }
            } catch is CancellationError {
                // User cancelled
            } catch {
                lastError = error
                lastFailedMessage = text
                if messages.last?.role == .user {
                    messages.removeLast()
                }
            }

            isStreaming = false
            streamingText = ""
        }
    }

    private func cancelGeneration() {
        activeTask?.cancel()
        activeTask = nil
        isStreaming = false
        streamingText = ""
    }

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, anchor: UnitPoint = .bottom) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isStreaming {
                proxy.scrollTo("streaming", anchor: anchor)
            } else if let lastMessage = messages.last {
                proxy.scrollTo(lastMessage.id, anchor: anchor)
            }
        }
    }
}

/// Internal message type that tracks which provider responded
private struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let provider: ProviderID?
}

private struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 40)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: 40)
            }
        }
    }

    private var userBubble: some View {
        Text(message.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.blue)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(ChatColors.bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.primary)

            if let provider = message.provider {
                Text("via \(provider.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
        }
    }
}

private enum ChatColors {
    static var bubbleBackground: Color {
        #if os(iOS) || os(visionOS)
        Color(uiColor: .systemGray5)
        #elseif os(macOS)
        Color.gray.opacity(0.3)
        #else
        Color.gray.opacity(0.3)
        #endif
    }

    static var inputBackground: Color {
        #if os(iOS) || os(visionOS)
        Color(uiColor: .systemGray6)
        #elseif os(macOS)
        Color.gray.opacity(0.15)
        #else
        Color.gray.opacity(0.15)
        #endif
    }
}
