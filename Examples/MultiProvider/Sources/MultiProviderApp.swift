// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import Arbiter
import os

private let logger = Logger(subsystem: "com.arbiter.examples", category: "MultiProvider")

@main
struct MultiProviderApp: App {
    private let ai: Arbiter

    init() {
        logger.info("Launching MultiProvider example")
        self.ai = Self.buildRuntime()
    }

    var body: some Scene {
        WindowGroup {
            MultiProviderRootView(ai: ai)
        }
    }

    private static func buildRuntime() -> Arbiter {
        Arbiter { config in
            // Deprecated hardcoded-key inits used for demo only; use keychain in production.
            config.cloud(AnthropicProvider(apiKey: "YOUR_ANTHROPIC_KEY")) // swiftlint:disable:this deprecated
            config.cloud(OpenAIProvider(apiKey: "YOUR_OPENAI_KEY")) // swiftlint:disable:this deprecated
            config.local(OllamaProvider())
            config.routing(RoutingPolicy(strategy: .costOptimized))
            config.spendingLimit(5.00, action: .fallbackToCheaper)
            config.middleware(LoggingMiddleware(logLevel: .standard))
            config.middleware(
                RequestSanitiserMiddleware(
                    maxPromptLength: 50_000,
                    sanitiseInjections: true,
                    requestsPerMinute: 30
                )
            )
        }
    }
}

struct MultiProviderRootView: View {
    let ai: Arbiter
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            chatTab
            debugTab
        }
    }

    private var chatTab: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProviderPicker(ai: ai) { selected in
                    logger.info("User selected provider: \(selected.rawValue)")
                }
                ArbiterChatView(ai: ai)
            }
            .navigationTitle("Chat")
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
}
