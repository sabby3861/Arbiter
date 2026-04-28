// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import Arbiter
import os

private let logger = Logger(subsystem: "com.arbiter.showcase", category: "ChatTab")

struct ChatTab: View {
    @Environment(AppState.self) private var appState
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isGenerating = false
    @State private var routingMode = RoutingMode.smart
    @State private var scrollTarget: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProviderStatusBar()
                    .padding(.vertical, 8)

                routingPicker

                Divider()

                chatContent

                inputBar
            }
            .navigationTitle("Chat")
            .inlineTitle()
        }
    }

    private var routingPicker: some View {
        Picker("Routing", selection: $routingMode) {
            ForEach(RoutingMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 8)
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
                    .background(sendButtonDisabled ? .gray : .blue, in: Circle())
            }
            .disabled(sendButtonDisabled)
            .animation(.spring(duration: 0.2), value: sendButtonDisabled)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var sendButtonDisabled: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating
    }

    private func sendIfReady() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        inputText = ""

        let userMessage = ChatMessage.user(text)
        messages.append(userMessage)
        let placeholder = ChatMessage.loading()
        messages.append(placeholder)
        scrollTarget = placeholder.id

        Task { await generate(prompt: text, placeholderID: placeholder.id) }
    }

    private func generate(prompt: String, placeholderID: UUID) async {
        isGenerating = true
        defer { isGenerating = false }

        let clock = ContinuousClock()
        let start = clock.now

        do {
            let response = try await appState.ai.generate(prompt, options: routingMode.options)
            let elapsed = clock.now - start
            let latencyStr = formatDuration(elapsed)
            let providerName = response.provider.displayName
            let tokenStr = response.usage.map { String($0.totalTokens) }
            let cost = AppState.estimateCost(provider: response.provider, usage: response.usage)

            replacePlaceholder(
                id: placeholderID,
                with: .assistant(response.content, provider: providerName, latency: latencyStr, tokens: tokenStr)
            )

            appState.recordUsage(
                provider: providerName,
                tokens: response.usage?.totalTokens ?? 0,
                cost: cost,
                latency: elapsed.seconds
            )
            appState.addLog(LogEntry(
                icon: "bubble.left.and.text.bubble.right", title: "Chat Response",
                detail: "via \(providerName) · \(latencyStr)", color: .green
            ))
            logger.info("Chat response via \(providerName) in \(latencyStr)")
        } catch {
            replacePlaceholder(id: placeholderID, with: .error(error.localizedDescription))
            appState.addLog(LogEntry(
                icon: "exclamationmark.triangle", title: "Chat Error",
                detail: error.localizedDescription, color: .red
            ))
            logger.error("Chat error: \(error.localizedDescription)")
        }
    }

    private func replacePlaceholder(id: UUID, with message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = message
        scrollTarget = message.id
    }

    private func formatDuration(_ duration: Duration) -> String {
        String(format: "%.1fs", duration.seconds)
    }
}

private enum RoutingMode: String, CaseIterable {
    case smart, costOptimised, quality

    var label: String {
        switch self {
        case .smart: "Smart"
        case .costOptimised: "Cost Optimised"
        case .quality: "Quality"
        }
    }

    var options: RequestOptions {
        switch self {
        case .smart: RequestOptions()
        case .costOptimised: RequestOptions(maxTokens: 512)
        case .quality: RequestOptions(maxTokens: 2048, temperature: 0.3)
        }
    }
}

private extension Duration {
    var seconds: Double {
        let comps = self.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}
