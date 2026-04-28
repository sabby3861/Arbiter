// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

struct ProviderBadge: View {
    let name: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Theme.providerColor(name) : .gray.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
