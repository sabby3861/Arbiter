// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import Arbiter
import os

private let logger = Logger(subsystem: "com.arbiter.showcase", category: "RoutingTab")

struct RoutingTab: View {
    @Environment(AppState.self) private var appState
    @State private var inputText = ""
    @State private var privacyMode = false
    @State private var costSensitive = false
    @State private var selectedScenario: String?
    @State private var analysis: RequestAnalysis?
    @State private var costEstimates: [CostEstimate] = []
    @State private var candidateScores: [CandidateScore] = []
    @State private var routingReason = ""
    @State private var isAnalysing = false
    @State private var response: String?
    @State private var isSending = false

    private let scenarios: [(label: String, prompt: String)] = [
        ("Simple classify", "Classify this text as positive or negative: I love this product"),
        ("Complex analysis", "Analyse the socioeconomic factors contributing to urbanisation in Southeast Asia"),
        ("Private data", "My social security number is 123-45-6789. What format is this?"),
        ("Code gen", "Write a Swift function that sorts an array using merge sort"),
        ("Quick chat", "What's the capital of France?"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    controlsCard
                    scenarioChips
                    inputSection
                    if analysis != nil { resultsSection }
                    if let response { responseCard(response) }
                }
                .padding()
            }
            .navigationTitle("Routing")
            .inlineTitle()
        }
    }

    private var controlsCard: some View {
        VStack(spacing: 12) {
            toggleRow(icon: "lock.shield", label: "Privacy Mode",
                      description: "Force local or privacy-first routing", isOn: $privacyMode)
            Divider()
            toggleRow(icon: "dollarsign.circle", label: "Cost Sensitive",
                      description: "Prefer cheaper providers", isOn: $costSensitive)
        }
        .cardStyle()
        .onChange(of: privacyMode) { _, _ in reanalyseIfNeeded() }
        .onChange(of: costSensitive) { _, _ in reanalyseIfNeeded() }
    }

    private func toggleRow(
        icon: String, label: String, description: String, isOn: Binding<Bool>
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline.weight(.medium))
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
    }

    private var scenarioChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(scenarios, id: \.label) { scenario in
                    ScenarioChip(label: scenario.label, isSelected: selectedScenario == scenario.label) {
                        selectedScenario = scenario.label
                        inputText = scenario.prompt
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var inputSection: some View {
        HStack(spacing: 12) {
            TextField("Enter a prompt to analyse...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            Button {
                Task { await analyse() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(isAnalysing || inputText.isEmpty ? .gray : .blue, in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(isAnalysing || inputText.isEmpty)
        }
        .padding(.horizontal)
    }

    private var resultsSection: some View {
        VStack(spacing: 16) {
            if let analysis { analysisCard(analysis) }
            if !candidateScores.isEmpty { providerScoresCard }
            if !costEstimates.isEmpty { costCard }
            sendButton
        }
    }

    private func analysisCard(_ analysis: RequestAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Request Analysis", icon: "doc.text.magnifyingglass")
            detailRow("Task", value: analysis.detectedTask.rawValue)
            detailRow("Complexity", value: "\(analysis.complexity)")
            detailRow("Est. Input Tokens", value: "~\(analysis.estimatedInputTokens)")
            detailRow("Est. Output Tokens", value: "~\(analysis.estimatedOutputTokens)")
            if !routingReason.isEmpty {
                detailRow("Routing", value: routingReason)
            }
        }
        .cardStyle()
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.medium))
        }
    }

    private var providerScoresCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Provider Scores", icon: "chart.bar")
            ForEach(candidateScores, id: \.provider) { candidate in
                providerScoreRow(candidate)
            }
        }
        .cardStyle()
        .animation(.spring(duration: 0.35), value: candidateScores.map(\.score))
    }

    private func providerScoreRow(_ candidate: CandidateScore) -> some View {
        let maxScore = candidateScores.map(\.score).max() ?? 1
        let barFraction = maxScore > 0 ? candidate.score / maxScore : 0
        let excluded = candidate.score <= 0
        let color = excluded ? .gray : Theme.providerColor(candidate.provider.displayName)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.provider.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(excluded ? .secondary : .primary)
                Spacer()
                Text(excluded ? "excluded" : "\(Int(candidate.score))")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(excluded ? .secondary : .primary)
                if candidate.isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.15))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * barFraction), height: 8)
                }
            }
            .frame(height: 8)
        }
    }

    private var costCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Cost Estimates", icon: "dollarsign.circle")
            ForEach(costEstimates) { estimate in
                costRow(estimate)
            }
        }
        .cardStyle()
    }

    private func costRow(_ estimate: CostEstimate) -> some View {
        HStack {
            Circle()
                .fill(Theme.providerColor(estimate.provider.displayName))
                .frame(width: 8, height: 8)
            Text(estimate.provider.displayName)
                .font(.subheadline)
            Spacer()
            Text(String(format: "$%.4f", estimate.estimatedCost))
                .font(.subheadline.monospacedDigit())
            if estimate.wouldBeSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
    }

    private var sendButton: some View {
        Button {
            Task { await send() }
        } label: {
            HStack {
                if isSending {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "paperplane.fill")
                }
                Text("Send to Provider")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isSending ? .gray : .blue, in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isSending)
        .padding(.horizontal)
    }

    private func responseCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Response", icon: "text.bubble")
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        }
        .cardStyle()
    }

    private func analyse() async {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        isAnalysing = true
        response = nil
        defer { isAnalysing = false }

        let analyser = RequestAnalyser()
        let request = AIRequest.chat(prompt)
        analysis = analyser.analyse(request, providers: appState.ai.registeredProviders)

        let options = currentOptions
        costEstimates = await appState.ai.estimateCost(prompt, options: options)

        let policy = currentPolicy
        let decision = await appState.ai.smartRouter.route(
            request, policy: policy,
            providers: appState.ai.registeredProviders,
            budgetRemaining: nil
        )
        routingReason = decision.reason
        candidateScores = decision.candidateScores

        appState.addLog(LogEntry(
            icon: "arrow.triangle.branch", title: "Routing Analysis",
            detail: "Task: \(analysis?.detectedTask.rawValue ?? "unknown")", color: .blue
        ))
        logger.info("Analysed prompt: \(analysis?.detectedTask.rawValue ?? "unknown")")
    }

    private func send() async {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        isSending = true
        defer { isSending = false }

        do {
            let result = try await appState.ai.generate(prompt, options: currentOptions)
            response = result.content
            let cost = AppState.estimateCost(provider: result.provider, usage: result.usage)
            appState.recordUsage(
                provider: result.provider.displayName,
                tokens: result.usage?.totalTokens ?? 0,
                cost: cost, latency: 0
            )
        } catch {
            response = "Error: \(error.localizedDescription)"
            appState.addLog(LogEntry(
                icon: "exclamationmark.triangle", title: "Routing Send Error",
                detail: error.localizedDescription, color: .red
            ))
        }
    }

    private func reanalyseIfNeeded() {
        guard analysis != nil else { return }
        Task { await analyse() }
    }

    private var currentPolicy: RoutingPolicy {
        if privacyMode { return RoutingPolicy(strategy: .privacyFirst) }
        if costSensitive { return RoutingPolicy(strategy: .costOptimized) }
        return .smart
    }

    private var currentOptions: RequestOptions {
        RequestOptions(privacyRequired: privacyMode)
    }
}
