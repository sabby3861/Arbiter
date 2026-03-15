// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
import SwiftUI
@testable import Arbiter

@Suite("View Compilation")
struct ViewCompilationTests {
    @MainActor
    @Test("ArbiterChatView initializes with AI instance")
    func chatViewInit() {
        let provider = MockProvider()
        let ai = Arbiter(provider: provider)
        let _ = ArbiterChatView(ai: ai)
    }

    @MainActor
    @Test("ArbiterChatView initializes with system prompt")
    func chatViewWithSystemPrompt() {
        let provider = MockProvider()
        let ai = Arbiter(provider: provider)
        let _ = ArbiterChatView(ai: ai, systemPrompt: "You are a helpful assistant.")
    }

    @MainActor
    @Test("ProviderPicker initializes with Arbiter instance")
    func providerPickerInit() {
        let ai = Arbiter { config in
            config.cloud(MockProvider(id: .anthropic))
            config.cloud(MockProvider(id: .openAI))
        }
        let _ = ProviderPicker(ai: ai) { _ in }
    }

    @MainActor
    @Test("UsageDashboard initializes with analytics")
    func usageDashboardInit() {
        let analytics = UsageAnalytics()
        let _ = UsageDashboard(analytics: analytics)
    }

    @MainActor
    @Test("RoutingDebugView initializes with SmartRouter")
    func routingDebugViewInit() {
        let router = SmartRouter()
        let _ = RoutingDebugView(router: router)
    }

    @Test("RoutingDebugEntry captures routing decision")
    func routingDebugEntry() {
        let decision = RoutingDecision(
            selectedProvider: .anthropic,
            reason: "Best match",
            alternativeProviders: [.openAI]
        )
        let entry = RoutingDebugEntry(requestSummary: "Chat: Hello", decision: decision)

        #expect(entry.requestSummary == "Chat: Hello")
        #expect(entry.decision.selectedProvider == .anthropic)
    }

    @Test("Configuration supports middleware")
    func configurationMiddleware() {
        let _ = Arbiter { config in
            config.cloud(MockProvider())
            config.middleware(LoggingMiddleware())
            config.middleware(RequestSanitiserMiddleware())
        }
    }

    @Test("Arbiter exposes smartRouter for RoutingDebugView")
    func smartRouterExposed() {
        let ai = Arbiter(provider: MockProvider())
        let _ = ai.smartRouter
    }

    @Test("Arbiter exposes registeredProviders for ProviderPicker")
    func registeredProvidersExposed() {
        let ai = Arbiter { config in
            config.cloud(MockProvider(id: .anthropic))
            config.cloud(MockProvider(id: .openAI))
        }
        #expect(ai.registeredProviders.count == 2)
    }

    @MainActor
    @Test("Lifecycle modifier takes Arbiter instance")
    func lifecycleModifier() {
        let ai = Arbiter(provider: MockProvider())
        let _ = Text("Test").swiftAILifecycle(ai)
    }
}
