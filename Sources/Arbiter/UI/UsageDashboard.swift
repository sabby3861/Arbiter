// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

/// Dashboard showing usage statistics across AI providers.
///
/// Displays total requests, tokens used, estimated cost, and
/// per-provider breakdown with a simple bar chart.
///
/// ```swift
/// UsageDashboard(analytics: analytics)
/// ```
public struct UsageDashboard: View {
    private let analytics: UsageAnalytics
    @State private var snapshot: UsageSnapshot?

    public init(analytics: UsageAnalytics) {
        self.analytics = analytics
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let snapshot {
                    overviewSection(snapshot.currentMonth)
                    providerBreakdown(snapshot.currentMonth)
                    comparisonSection(
                        current: snapshot.currentMonth,
                        previous: snapshot.previousMonth
                    )
                } else {
                    ProgressView("Loading analytics...")
                }
            }
            .padding()
        }
        .task { await loadSnapshot() }
    }

    private func overviewSection(_ summary: UsageSummary) -> some View {
        VStack(spacing: 12) {
            Text("This Month")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 12) {
                StatCard(title: "Requests", value: "\(summary.totalRequests)")
                StatCard(title: "Tokens", value: formatNumber(summary.totalTokens))
                StatCard(title: "Est. Cost", value: formatCost(summary.totalCost))
                StatCard(title: "Avg Latency", value: formatLatency(summary.averageLatencySeconds))
            }
        }
    }

    private func providerBreakdown(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Provider Usage")
                .font(.headline)

            let maxCount = summary.requestsByProvider.values.max() ?? 1

            ForEach(
                summary.requestsByProvider.sorted(by: { $0.value > $1.value }),
                id: \.key
            ) { provider, count in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider.displayName)
                            .font(.subheadline)
                        Spacer()
                        Text("\(count) requests")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor(for: provider))
                            .frame(
                                width: geometry.size.width * CGFloat(count) / CGFloat(maxCount)
                            )
                    }
                    .frame(height: 8)
                }
            }
        }
    }

    private func comparisonSection(current: UsageSummary, previous: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("vs Last Month")
                .font(.headline)

            HStack(spacing: 16) {
                ComparisonStat(
                    label: "Requests",
                    current: current.totalRequests,
                    previous: previous.totalRequests
                )
                ComparisonStat(
                    label: "Cost",
                    current: current.totalCost,
                    previous: previous.totalCost,
                    formatter: formatCost
                )
            }
        }
    }

    private func loadSnapshot() async {
        snapshot = await analytics.snapshot()
    }

    private func barColor(for provider: ProviderID) -> Color {
        switch provider.tier {
        case .cloud: .blue
        case .localServer: .orange
        case .onDevice: .green
        case .system: .purple
        }
    }

    private func formatNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private func formatCost(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private func formatLatency(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        return String(format: "%.1fs", seconds)
    }
}

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(DashboardColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private enum DashboardColors {
    static var cardBackground: Color {
        #if os(iOS) || os(visionOS)
        Color(uiColor: .systemGray6)
        #elseif os(macOS)
        Color.gray.opacity(0.15)
        #else
        Color.gray.opacity(0.15)
        #endif
    }
}

private struct ComparisonStat: View {
    let label: String
    let currentValue: String
    let previousValue: String
    let changePercent: Double

    init(label: String, current: Int, previous: Int) {
        self.label = label
        self.currentValue = "\(current)"
        self.previousValue = "\(previous)"
        self.changePercent = previous == 0 ? 0 : Double(current - previous) / Double(previous) * 100
    }

    init(label: String, current: Double, previous: Double, formatter: (Double) -> String) {
        self.label = label
        self.currentValue = formatter(current)
        self.previousValue = formatter(previous)
        self.changePercent = previous == 0 ? 0 : (current - previous) / previous * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(currentValue)
                .font(.headline)
            HStack(spacing: 2) {
                Image(systemName: changePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text(String(format: "%.0f%%", abs(changePercent)))
            }
            .font(.caption2)
            .foregroundStyle(changePercent > 0 ? .red : .green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

