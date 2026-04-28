// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import Arbiter
import os

private let logger = Logger(subsystem: "com.arbiter.showcase", category: "StreamingTab")

struct StreamingTab: View {
    @Environment(AppState.self) private var appState
    @State private var outputText = ""
    @State private var isStreaming = false
    @State private var chunkCount = 0
    @State private var speed: Double = 0
    @State private var elapsedSeconds: Double = 0
    @State private var providerName = ""
    @State private var selectedPrompt: String?
    @State private var cursorVisible = true
    @State private var errorMessage: String?

    private let prompts: [(label: String, text: String)] = [
        ("Haiku about Swift", "Write a haiku about the Swift programming language"),
        ("Explain recursion", "Explain recursion in simple terms with an example"),
        ("Robot story", "Write a very short story about a robot discovering music"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    promptChips
                    outputCard
                    if let errorMessage { errorView(errorMessage) }
                    metricsRow
                    if !providerName.isEmpty { providerBadge }
                    streamButton
                }
                .padding()
            }
            .navigationTitle("Streaming")
            .inlineTitle()
        }
    }

    private var promptChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(prompts, id: \.label) { prompt in
                    ScenarioChip(label: prompt.label, isSelected: selectedPrompt == prompt.label) {
                        selectedPrompt = prompt.label
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var outputCard: some View {
        VStack(alignment: .leading) {
            let display = isStreaming ? outputText + (cursorVisible ? "\u{258C}" : " ") : outputText
            Text(display.isEmpty ? "Select a prompt and tap Stream..." : display)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(display.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(minHeight: 200, alignment: .topLeading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(.secondary.opacity(0.15)))
        .task(id: isStreaming) {
            guard isStreaming else {
                cursorVisible = true
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                cursorVisible.toggle()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: cursorVisible)
    }

    private func errorView(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(.red)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var metricsRow: some View {
        HStack(spacing: 12) {
            MetricCard(title: "Tokens", value: "\(chunkCount)", icon: "number", color: .blue)
            MetricCard(title: "Speed", value: String(format: "%.0f t/s", speed), icon: "gauge.high", color: .green)
            MetricCard(title: "Time", value: String(format: "%.2fs", elapsedSeconds), icon: "clock", color: .orange)
        }
        .animation(.spring(duration: 0.35), value: chunkCount)
    }

    private var providerBadge: some View {
        ProviderBadge(name: providerName, isActive: true)
    }

    private var streamButton: some View {
        Button {
            Task { await stream() }
        } label: {
            HStack {
                if isStreaming { ProgressView().tint(.white) }
                else { Image(systemName: "waveform") }
                Text(isStreaming ? "Streaming..." : (outputText.isEmpty ? "Stream" : "Stream Again"))
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isStreaming || selectedPrompt == nil ? .gray : .blue, in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isStreaming || selectedPrompt == nil)
    }

    private func stream() async {
        guard let selected = prompts.first(where: { $0.label == selectedPrompt }) else { return }

        outputText = ""
        chunkCount = 0
        speed = 0
        elapsedSeconds = 0
        providerName = ""
        errorMessage = nil
        isStreaming = true
        defer { isStreaming = false }

        let clock = ContinuousClock()
        let start = clock.now
        var actualTokens: Int?

        do {
            for try await chunk in appState.ai.stream(selected.text) {
                outputText += chunk.delta
                if !chunk.delta.isEmpty { chunkCount += 1 }
                providerName = chunk.provider.displayName

                if let usage = chunk.usage {
                    actualTokens = usage.totalTokens
                }

                let elapsed = clock.now - start
                let secs = elapsed.seconds
                elapsedSeconds = secs
                if secs > 0 { speed = Double(chunkCount) / secs }
            }

            if let tokens = actualTokens { chunkCount = tokens }

            let cost = Double(chunkCount) * 0.00001
            appState.recordUsage(provider: providerName, tokens: chunkCount, cost: cost, latency: elapsedSeconds)
            appState.addLog(LogEntry(
                icon: "waveform", title: "Streaming Complete",
                detail: "\(chunkCount) tokens via \(providerName) in \(String(format: "%.1fs", elapsedSeconds))", color: .green
            ))
            logger.info("Streamed \(chunkCount) tokens via \(providerName)")
        } catch {
            errorMessage = error.localizedDescription
            appState.addLog(LogEntry(
                icon: "exclamationmark.triangle", title: "Streaming Error",
                detail: error.localizedDescription, color: .red
            ))
            logger.error("Streaming error: \(error.localizedDescription)")
        }
    }
}

private extension Duration {
    var seconds: Double {
        let c = self.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
