// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

/// A picker that lists configured AI providers with their availability status.
///
/// Shows provider name, tier badge (Cloud/Local/System), and status indicator.
/// Selecting a provider overrides smart routing for the current session.
///
/// ```swift
/// ProviderPicker(ai: ai) { selected in
///     options.provider = selected
/// }
/// ```
public struct ProviderPicker: View {
    private let ai: SwiftAI
    private let onSelect: (ProviderID) -> Void
    @State private var availability: [ProviderID: Bool] = [:]
    @State private var selectedProvider: ProviderID?

    public init(ai: SwiftAI, onSelect: @escaping (ProviderID) -> Void) {
        self.ai = ai
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            ForEach(ai.registeredProviders, id: \.id) { provider in
                providerRow(provider)
            }
        }
        .task { await checkAvailability() }
    }

    private func providerRow(_ provider: any AIProvider) -> some View {
        Button {
            selectedProvider = provider.id
            onSelect(provider.id)
        } label: {
            HStack(spacing: 12) {
                statusIndicator(for: provider.id)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.id.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(tierLabel(provider.id.tier))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                tierBadge(provider.id.tier)

                if selectedProvider == provider.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusIndicator(for id: ProviderID) -> some View {
        Circle()
            .fill(statusColor(for: id))
            .frame(width: 10, height: 10)
    }

    private func statusColor(for id: ProviderID) -> Color {
        guard let isAvailable = availability[id] else {
            return .gray
        }
        return isAvailable ? .green : .red
    }

    private func tierBadge(_ tier: ProviderTier) -> some View {
        Text(tierLabel(tier))
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tierColor(tier).opacity(0.15))
            .foregroundStyle(tierColor(tier))
            .clipShape(Capsule())
    }

    private func tierLabel(_ tier: ProviderTier) -> String {
        switch tier {
        case .cloud: "Cloud"
        case .localServer: "Local"
        case .onDevice: "On-Device"
        case .system: "System"
        }
    }

    private func tierColor(_ tier: ProviderTier) -> Color {
        switch tier {
        case .cloud: .blue
        case .localServer: .orange
        case .onDevice: .green
        case .system: .purple
        }
    }

    private func checkAvailability() async {
        await withTaskGroup(of: (ProviderID, Bool).self) { group in
            for provider in ai.registeredProviders {
                group.addTask { (provider.id, await provider.isAvailable) }
            }
            for await (id, isAvailable) in group {
                availability[id] = isAvailable
            }
        }
    }
}
