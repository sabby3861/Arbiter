// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import Arbiter
import os

private let logger = Logger(subsystem: "com.arbiter.showcase", category: "ConversationTab")

struct ConversationTab: View {
    @Environment(AppState.self) private var appState
    @State private var session = ConversationSession(systemPrompt: "You are a helpful assistant. Be concise.")
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var systemPrompt = "You are a helpful assistant. Be concise."
    @State private var isEditingPrompt = false
    @State private var demoTask: Task<Void, Never>?
    @State private var scrollTarget: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                systemPromptSection
                Divider()
                chatContent
                tokenIndicator
                inputBar
            }
            .navigationTitle("Conversation")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { runDemo() } label: {
                        Label("Run Demo", systemImage: "play.circle")
                    }
                    .disabled(isLoading || demoTask != nil)
                }
            }
        }
    }

    private var systemPromptSection: some View {
        DisclosureGroup("System Prompt", isExpanded: $isEditingPrompt) {
            VStack(spacing: 8) {
                TextEditor(text: $systemPrompt)
                    .font(.subheadline)
                    .frame(height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))

                Button("Apply") { applySystemPrompt() }
                    .buttonStyle(.bordered)
                    .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var chatContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    private var tokenIndicator: some View {
        let count = session.estimatedTokenCount
        let max = 100_000
        return VStack(spacing: 4) {
            ProgressView(value: Double(min(count, max)), total: Double(max))
                .tint(count < 50_000 ? .blue : (count < 80_000 ? .yellow : .red))
            Text("~\(count.formatted()) / \(max.formatted()) tokens")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .onSubmit { sendIfReady() }

            Button(action: sendIfReady) {
                Image(systemName: "arrow.up")
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(sendDisabled ? .gray : .blue, in: Circle())
            }
            .disabled(sendDisabled)

            Button { clearConversation() } label: {
                Image(systemName: "trash.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var sendDisabled: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading
    }

    private func sendIfReady() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        inputText = ""
        Task { await sendMessage(text) }
    }

    private func sendMessage(_ text: String) async {
        isLoading = true
        defer { isLoading = false }

        let userMsg = ChatMessage.user(text)
        messages.append(userMsg)
        let placeholder = ChatMessage.loading()
        messages.append(placeholder)
        scrollTarget = placeholder.id

        let clock = ContinuousClock()
        let start = clock.now

        do {
            try await session.send(text, using: appState.ai)
            let elapsed = clock.now - start
            let latencyStr = String(format: "%.1fs", elapsed.seconds)

            let responseText = session.messages.last.flatMap { $0.content.text } ?? "No response"
            let estimatedTokens = max(responseText.count / 4, 50)
            replacePlaceholder(id: placeholder.id, with: .assistant(responseText, provider: nil, latency: latencyStr, tokens: nil))

            appState.recordUsage(
                provider: "Session", tokens: estimatedTokens,
                cost: Double(estimatedTokens) * 0.00001, latency: elapsed.seconds
            )
            appState.addLog(LogEntry(
                icon: "text.bubble", title: "Conversation Turn",
                detail: "Response in \(latencyStr)", color: .teal
            ))
            logger.info("Conversation turn completed in \(latencyStr)")
        } catch {
            replacePlaceholder(id: placeholder.id, with: .error(error.localizedDescription))
            appState.addLog(LogEntry(
                icon: "exclamationmark.triangle", title: "Conversation Error",
                detail: error.localizedDescription, color: .red
            ))
        }
    }

    private func replacePlaceholder(id: UUID, with message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = message
        scrollTarget = message.id
    }

    private func runDemo() {
        appState.addLog(LogEntry(
            icon: "play.circle", title: "Demo Started",
            detail: "4-turn context retention demo", color: .teal
        ))
        demoTask = Task {
            let demoMessages = [
                "My name is Sanjay and I'm a software engineer in London",
                "What's my name and what do I do?",
                "What city am I in?",
                "Suggest a good coffee shop near me",
            ]

            for message in demoMessages {
                guard !Task.isCancelled else { break }
                inputText = message
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                await sendMessage(message)
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(2))
            }
            demoTask = nil
        }
    }

    private func clearConversation() {
        demoTask?.cancel()
        demoTask = nil
        session.reset()
        messages.removeAll()
        inputText = ""
    }

    private func applySystemPrompt() {
        clearConversation()
        session = ConversationSession(systemPrompt: systemPrompt)
        isEditingPrompt = false
    }
}

private extension Duration {
    var seconds: Double {
        let c = self.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
