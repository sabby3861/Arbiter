// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
import Foundation
@testable import Arbiter

@Suite("UsageAnalytics")
struct UsageAnalyticsTests {
    private func makeAnalytics() -> UsageAnalytics {
        let suiteName = "com.arbiter.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return UsageAnalytics(defaults: defaults)
    }

    @Test("Records requests and tracks count")
    func recordRequest() async {
        let analytics = makeAnalytics()
        let tokens = TokenUsage(inputTokens: 100, outputTokens: 50)

        await analytics.recordRequest(provider: .anthropic, tokens: tokens, cost: 0.001, latency: 0.5)
        await analytics.recordRequest(provider: .openAI, tokens: tokens, cost: 0.002, latency: 1.0)

        let total = await analytics.totalRequests
        #expect(total == 2)
    }

    @Test("Summary calculates totals correctly")
    func summaryTotals() async {
        let analytics = makeAnalytics()

        await analytics.recordRequest(
            provider: .anthropic,
            tokens: TokenUsage(inputTokens: 100, outputTokens: 50),
            cost: 0.001,
            latency: 0.5
        )
        await analytics.recordRequest(
            provider: .openAI,
            tokens: TokenUsage(inputTokens: 200, outputTokens: 100),
            cost: 0.003,
            latency: 1.5
        )

        let summary = await analytics.summary(since: Date.distantPast)

        #expect(summary.totalRequests == 2)
        #expect(summary.totalInputTokens == 300)
        #expect(summary.totalOutputTokens == 150)
        #expect(summary.totalTokens == 450)
        #expect(abs(summary.totalCost - 0.004) < 0.0001)
        #expect(abs(summary.averageLatencySeconds - 1.0) < 0.01)
    }

    @Test("Summary groups by provider")
    func summaryByProvider() async {
        let analytics = makeAnalytics()
        let tokens = TokenUsage(inputTokens: 100, outputTokens: 50)

        await analytics.recordRequest(provider: .anthropic, tokens: tokens, cost: 0.001, latency: 0.5)
        await analytics.recordRequest(provider: .anthropic, tokens: tokens, cost: 0.001, latency: 0.5)
        await analytics.recordRequest(provider: .openAI, tokens: tokens, cost: 0.002, latency: 1.0)

        let summary = await analytics.summary(since: Date.distantPast)

        #expect(summary.requestsByProvider[.anthropic] == 2)
        #expect(summary.requestsByProvider[.openAI] == 1)
    }

    @Test("Summary filters by date")
    func summaryDateFilter() async {
        let analytics = makeAnalytics()
        let tokens = TokenUsage(inputTokens: 100, outputTokens: 50)

        await analytics.recordRequest(provider: .anthropic, tokens: tokens, cost: 0.001, latency: 0.5)

        let futureDate = Date().addingTimeInterval(3600)
        let summary = await analytics.summary(since: futureDate)

        #expect(summary.totalRequests == 0)
    }

    @Test("Snapshot provides current and previous month data")
    func snapshot() async {
        let analytics = makeAnalytics()
        let tokens = TokenUsage(inputTokens: 100, outputTokens: 50)

        await analytics.recordRequest(provider: .anthropic, tokens: tokens, cost: 0.001, latency: 0.5)

        let snapshot = await analytics.snapshot()

        #expect(snapshot.currentMonth.totalRequests == 1)
        #expect(snapshot.allTime.totalRequests == 1)
    }

    @Test("Reset clears all data")
    func reset() async {
        let analytics = makeAnalytics()
        let tokens = TokenUsage(inputTokens: 100, outputTokens: 50)

        await analytics.recordRequest(provider: .anthropic, tokens: tokens, cost: 0.001, latency: 0.5)
        await analytics.reset()

        let total = await analytics.totalRequests
        #expect(total == 0)
    }
}
