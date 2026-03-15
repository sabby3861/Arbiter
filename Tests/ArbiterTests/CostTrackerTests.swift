// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("CostTracker")
struct CostTrackerTests {
    func freshTracker() -> CostTracker {
        let suiteName = "com.arbiter.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return CostTracker(defaults: defaults)
    }

    @Test func initialSpendIsZero() async {
        let tracker = freshTracker()
        let spend = await tracker.totalSpend
        #expect(spend == 0)
    }

    @Test func recordUsageAccumulatesSpend() async {
        let tracker = freshTracker()
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50)

        await tracker.recordUsage(provider: .anthropic, usage: usage, cost: 0.01)
        await tracker.recordUsage(provider: .anthropic, usage: usage, cost: 0.02)

        let spend = await tracker.totalSpend
        #expect(abs(spend - 0.03) < 0.001)
    }

    @Test func perProviderSpendTracking() async {
        let tracker = freshTracker()
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50)

        await tracker.recordUsage(provider: .anthropic, usage: usage, cost: 0.05)
        await tracker.recordUsage(provider: .openAI, usage: usage, cost: 0.03)

        let anthropicSpend = await tracker.spend(for: .anthropic)
        let openAISpend = await tracker.spend(for: .openAI)

        #expect(abs(anthropicSpend - 0.05) < 0.001)
        #expect(abs(openAISpend - 0.03) < 0.001)
    }

    @Test func resetClearsAllSpend() async {
        let tracker = freshTracker()
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50)

        await tracker.recordUsage(provider: .anthropic, usage: usage, cost: 1.00)
        await tracker.reset()

        let spend = await tracker.totalSpend
        #expect(spend == 0)
    }

    @Test func estimateRequestCostCalculation() async {
        let tracker = freshTracker()
        let request = AIRequest.chat("Hello world").withMaxTokens(1000)

        let caps = ProviderCapabilities(
            supportedTasks: [.chat], maxContextTokens: 200_000,
            supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
            costPerMillionInputTokens: 3.0, costPerMillionOutputTokens: 15.0,
            estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
        )

        let estimate = await tracker.estimateRequestCost(request: request, capabilities: caps)
        #expect(estimate > 0)
    }

    @Test func dailyRequestCountIncrements() async {
        let tracker = freshTracker()
        let usage = TokenUsage(inputTokens: 10, outputTokens: 5)

        await tracker.recordUsage(provider: .anthropic, usage: usage, cost: 0.001)
        await tracker.recordUsage(provider: .anthropic, usage: usage, cost: 0.001)
        await tracker.recordUsage(provider: .openAI, usage: usage, cost: 0.001)

        let count = await tracker.todayRequestCount
        #expect(count == 3)
    }

    @Test func unrecordedProviderReturnsZero() async {
        let tracker = freshTracker()
        let spend = await tracker.spend(for: .gemini)
        #expect(spend == 0)
    }
}
