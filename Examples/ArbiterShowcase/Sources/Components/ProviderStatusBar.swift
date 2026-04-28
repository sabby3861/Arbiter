// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

struct ProviderStatusBar: View {
    @Environment(AppState.self) private var appState

    private let allProviders = ["Anthropic", "OpenAI", "Gemini"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allProviders, id: \.self) { name in
                    ProviderBadge(
                        name: name,
                        isActive: appState.configuredProviders.contains(name)
                    )
                }
            }
            .padding(.horizontal)
        }
    }
}
