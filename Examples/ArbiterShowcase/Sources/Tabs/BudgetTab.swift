// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import Arbiter
import os

private let logger = Logger(subsystem: "com.arbiter.showcase", category: "BudgetTab")

struct BudgetTab: View {
    @Environment(AppState.self) private var appState
    @State private var estimateText = ""
    @State private var estimates: [CostEstimate] = []
    @State private var isEstimating = false

    private let displayBudget = 1.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    budgetRing
                    if hasStats { providerBreakdown }
                    else { emptyStatsPlaceholder }
                    costEstimatorSection
                }
                .padding()
            }
            .navigationTitle("Budget")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        appState.resetStats()
                        appState.addLog(LogEntry(
                            icon: "chart.pie", title: "Stats Reset",
                            detail: "All provider stats cleared", color: .yellow
                        ))
                    }
                }
            }
        }
    }

    private var hasStats: Bool {
        !appState.providerStats.isEmpty
    }

    private var budgetRing: some View {
        let spent = appState.totalSpend
        let progress = min(spent / displayBudget, 1.0)
        let ringColor: Color = progress < 0.5 ? .green : (progress < 0.8 ? .yellow : .red)

        return ZStack {
            Circle()
                .stroke(.gray.opacity(0.2), lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.5), value: progress)
            VStack(spacing: 2) {
                Text(String(format: "$%.4f", spent))
                    .font(.title2.bold().monospacedDigit())
                Text("spent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 160, height: 160)
        .padding(.top, 8)
    }

    private var providerBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Provider Breakdown", icon: "chart.bar")
            ForEach(sortedProviders, id: \.key) { name, stat in
                providerStatCard(name: name, stat: stat)
            }
        }
    }

    private var sortedProviders: [(key: String, value: AppState.ProviderStat)] {
        appState.providerStats.sorted { $0.value.totalCost > $1.value.totalCost }
    }

    private func providerStatCard(name: String, stat: AppState.ProviderStat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(Theme.providerColor(name))
                    .frame(width: 10, height: 10)
                Text(name)
                    .font(.subheadline.bold())
                Spacer()
            }
            HStack(spacing: 16) {
                statLabel("\(stat.requests) requests")
                statLabel("\(stat.tokens.formatted()) tokens")
            }
            HStack(spacing: 16) {
                statLabel(String(format: "$%.4f", stat.totalCost))
                statLabel(String(format: "avg %.1fs", stat.averageLatency))
            }
        }
        .cardStyle()
    }

    private func statLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var emptyStatsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.pie")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Use other tabs to see cost data here")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var costEstimatorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Cost Estimator", icon: "dollarsign.circle")
            HStack(spacing: 12) {
                TextField("Enter a prompt to estimate cost...", text: $estimateText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                Button {
                    Task { await estimateCost() }
                } label: {
                    Text("Estimate")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(estimateText.isEmpty || isEstimating ? .gray : .blue, in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(estimateText.isEmpty || isEstimating)
            }

            if !estimates.isEmpty {
                VStack(spacing: 8) {
                    ForEach(estimates) { estimate in
                        HStack {
                            Circle()
                                .fill(Theme.providerColor(estimate.provider.displayName))
                                .frame(width: 8, height: 8)
                            Text(estimate.provider.displayName)
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "$%.6f", estimate.estimatedCost))
                                .font(.subheadline.monospacedDigit())
                            if estimate.wouldBeSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    private func estimateCost() async {
        let text = estimateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isEstimating = true
        defer { isEstimating = false }

        estimates = await appState.ai.estimateCost(text)
        appState.addLog(LogEntry(
            icon: "chart.pie", title: "Cost Estimate",
            detail: "\(estimates.count) provider estimates", color: .yellow
        ))
        logger.info("Cost estimation for \(estimates.count) providers")
    }
}
