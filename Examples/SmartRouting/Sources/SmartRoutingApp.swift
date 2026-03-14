// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import SwiftAI
import os

private let logger = Logger(subsystem: "com.swiftai.examples", category: "SmartRouting")

@main
struct SmartRoutingApp: App {
    var body: some Scene {
        WindowGroup {
            SmartRoutingRootView()
        }
    }
}

struct SmartRoutingRootView: View {
    @State private var offlineMode = false
    @State private var budgetExceeded = false
    @State private var privacyMode = false
    @State private var selectedTab = 0
    @State private var analytics = UsageAnalytics()
    @State private var ai: SwiftAI = buildRuntime(
        offline: false,
        lowBudget: false,
        privacy: false
    )

    var body: some View {
        TabView(selection: $selectedTab) {
            chatTab
            debugTab
            usageTab
        }
        .onChange(of: offlineMode) { _, _ in rebuildRuntime() }
        .onChange(of: budgetExceeded) { _, _ in rebuildRuntime() }
        .onChange(of: privacyMode) { _, _ in rebuildRuntime() }
    }

    private var chatTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                simulationControls
                SwiftAIChatView(ai: ai)
            }
            .navigationTitle("Smart Routing")
        }
        .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
        .tag(0)
    }

    private var debugTab: some View {
        NavigationStack {
            RoutingDebugView(router: ai.smartRouter)
        }
        .tabItem { Label("Debug", systemImage: "ant") }
        .tag(1)
    }

    private var usageTab: some View {
        NavigationStack {
            UsageDashboard(analytics: analytics)
                .navigationTitle("Usage")
        }
        .tabItem { Label("Usage", systemImage: "chart.bar") }
        .tag(2)
    }

    private var simulationControls: some View {
        VStack(spacing: 8) {
            Text("Simulation Controls")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                togglePill(
                    label: "Offline",
                    icon: "wifi.slash",
                    isOn: $offlineMode
                )
                togglePill(
                    label: "Budget Hit",
                    icon: "dollarsign.circle",
                    isOn: $budgetExceeded
                )
                togglePill(
                    label: "Privacy",
                    icon: "lock.shield",
                    isOn: $privacyMode
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func togglePill(
        label: String,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label(label, systemImage: icon)
                .font(.caption)
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .tint(isOn.wrappedValue ? .orange : .secondary)
    }

    private func rebuildRuntime() {
        ai = buildRuntime(
            offline: offlineMode,
            lowBudget: budgetExceeded,
            privacy: privacyMode
        )
    }
}

private func buildRuntime(
    offline: Bool,
    lowBudget: Bool,
    privacy: Bool
) -> SwiftAI {
    SwiftAI { config in
        if !offline {
            // Deprecated hardcoded-key inits used for demo only; use keychain in production.
            config.cloud(AnthropicProvider(apiKey: "YOUR_ANTHROPIC_KEY")) // swiftlint:disable:this deprecated
            config.cloud(OpenAIProvider(apiKey: "YOUR_OPENAI_KEY")) // swiftlint:disable:this deprecated
        }

        #if canImport(MLX)
        config.local(MLXProvider(.auto))
        #endif

        config.local(OllamaProvider())

        if privacy {
            config.routing(.preferLocal)
            config.privacy(.localOnly)
        } else {
            config.routing(.smart)
        }

        let budget: Double = lowBudget ? 0.01 : 10.00
        config.spendingLimit(budget, action: .fallbackToCheaper)

        config.middleware(LoggingMiddleware(logLevel: .verbose))
    }
}
