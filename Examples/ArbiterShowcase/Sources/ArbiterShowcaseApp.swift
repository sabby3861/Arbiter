// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import os

private let logger = Logger(subsystem: "com.arbiter.showcase", category: "App")

@main
struct ArbiterShowcaseApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            if appState.isConfigured {
                MainTabView()
                    .environment(appState)
            } else {
                SetupView()
            }
        }
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            ChatTab()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            RoutingTab()
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
            StructuredTab()
                .tabItem { Label("Typed", systemImage: "chevron.left.forwardslash.chevron.right") }
            ConversationTab()
                .tabItem { Label("Session", systemImage: "text.bubble") }
            StreamingTab()
                .tabItem { Label("Stream", systemImage: "waveform") }
            BudgetTab()
                .tabItem { Label("Budget", systemImage: "chart.pie") }
            LogTab()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
        }
    }
}

private struct SetupView: View {
    private let requiredKeys = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY"]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("Arbiter Showcase")
                .font(.largeTitle.bold())

            Text("Configure at least one API key to get started")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(requiredKeys, id: \.self) { key in
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .cardStyle()

            Text("Xcode → Product → Scheme → Edit Scheme → Run → Environment Variables")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .padding()
    }
}
