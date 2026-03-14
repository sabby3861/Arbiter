// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

/// Live feed of routing decisions for debugging and demonstration.
///
/// Each entry shows the timestamp, selected provider, reason, fallbacks,
/// and contributing factors. Color-coded by provider tier.
///
/// ```swift
/// RoutingDebugView(router: router)
/// ```
public struct RoutingDebugView: View {
    private let router: SmartRouter
    @State private var entries: [RoutingDebugEntry] = []

    public init(router: SmartRouter) {
        self.router = router
    }

    public var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Routing Decisions",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Routing decisions will appear here as requests are made.")
                )
            } else {
                ForEach(entries.reversed()) { entry in
                    RoutingEntryRow(entry: entry)
                }
            }
        }
        .navigationTitle("Routing Debug")
        .task { await loadDecisions() }
        .refreshable { await loadDecisions() }
    }

    private func loadDecisions() async {
        entries = await router.recentDecisions
    }
}

private struct RoutingEntryRow: View {
    let entry: RoutingDebugEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                details
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            tierIndicator
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.decision.selectedProvider?.displayName ?? "None")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text(formattedTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(entry.requestSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailRow(label: "Reason", value: entry.decision.reason)
            DetailRow(
                label: "Confidence",
                value: String(format: "%.0f%%", entry.decision.confidenceScore * 100)
            )

            if !entry.decision.alternativeProviders.isEmpty {
                DetailRow(
                    label: "Fallbacks",
                    value: entry.decision.alternativeProviders.map(\.displayName).joined(separator: " → ")
                )
            }

            if !entry.decision.factors.isEmpty {
                Text("Factors")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                ForEach(entry.decision.factors.indices, id: \.self) { index in
                    Text("• \(factorDescription(entry.decision.factors[index]))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 22)
    }

    private var tierIndicator: some View {
        Circle()
            .fill(tierColor)
            .frame(width: 10, height: 10)
    }

    private var tierColor: Color {
        guard let provider = entry.decision.selectedProvider else { return .gray }
        switch provider.tier {
        case .cloud: return .blue
        case .localServer: return .orange
        case .onDevice: return .green
        case .system: return .purple
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }

    private func factorDescription(_ factor: RoutingFactor) -> String {
        switch factor {
        case .connectivity(let available):
            "Network: \(available ? "connected" : "offline")"
        case .capability(let task, let canHandle):
            "\(task.rawValue): \(canHandle ? "supported" : "unsupported")"
        case .cost(let cost):
            "Est. cost: $\(String(format: "%.4f", cost))"
        case .latency(let tier):
            "Latency: \(tier.rawValue)"
        case .privacy(let level, let required):
            "Privacy: \(level.rawValue) (required: \(required.rawValue))"
        case .deviceCapability(let canRun, let reason):
            "Local: \(canRun ? "capable" : reason ?? "not capable")"
        case .thermal(let state, let recommendation):
            "Thermal: \(state) — \(recommendation)"
        case .budget(let remaining, let cost):
            "Budget: $\(String(format: "%.4f", remaining)) remaining (est: $\(String(format: "%.4f", cost)))"
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary)
        }
    }
}
