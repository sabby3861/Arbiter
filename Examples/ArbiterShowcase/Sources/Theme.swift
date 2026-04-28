// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

enum Theme {
    static func providerColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "anthropic": return Color(red: 0.85, green: 0.45, blue: 0.2)
        case "openai": return Color(red: 0.2, green: 0.7, blue: 0.4)
        case "gemini": return Color(red: 0.3, green: 0.5, blue: 0.9)
        case "ollama": return Color(red: 0.6, green: 0.3, blue: 0.8)
        default: return .gray
        }
    }

    #if canImport(UIKit)
    static let cardBackground = Color(uiColor: .secondarySystemBackground)
    #else
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    #endif

    static let cornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 20

    struct CardStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(Theme.cardPadding)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        }
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(Theme.CardStyle())
    }

    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
