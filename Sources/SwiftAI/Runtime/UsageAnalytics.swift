// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "UsageAnalytics")

/// Tracks usage metrics across all providers for observability and cost management.
///
/// Persists data to UserDefaults for cross-session continuity. Bind `snapshot()`
/// to SwiftUI views via `UsageSnapshot`.
///
/// ```swift
/// let analytics = UsageAnalytics()
/// await analytics.recordRequest(provider: .anthropic, tokens: usage, cost: 0.002, latency: 1.2)
/// let snapshot = await analytics.snapshot()
/// ```
public actor UsageAnalytics {
    private var records: [UsageRecord] = []
    private let defaults: UserDefaults
    private let persistenceKey = "com.swiftai.usage_analytics"

    public init() {
        let store = UserDefaults(suiteName: "com.swiftai.analytics") ?? .standard
        self.defaults = store
        if let data = store.data(forKey: "com.swiftai.usage_analytics") {
            self.records = (try? JSONDecoder().decode([UsageRecord].self, from: data)) ?? []
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Record a completed request
    public func recordRequest(
        provider: ProviderID,
        tokens: TokenUsage,
        cost: Double,
        latency: Double
    ) {
        let record = UsageRecord(
            date: Date(),
            provider: provider,
            inputTokens: tokens.inputTokens,
            outputTokens: tokens.outputTokens,
            cost: cost,
            latencySeconds: latency
        )
        records.append(record)
        persist()
        logger.debug("Recorded \(provider.rawValue): \(tokens.totalTokens) tokens, $\(cost, privacy: .public)")
    }

    /// Get a usage summary since a given date
    public func summary(since: Date) -> UsageSummary {
        let filtered = records.filter { $0.date >= since }
        return buildSummary(from: filtered)
    }

    /// Get a snapshot suitable for SwiftUI binding
    public func snapshot() -> UsageSnapshot {
        let allTime = buildSummary(from: records)

        let calendar = Calendar.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        let currentMonth = buildSummary(from: records.filter { $0.date >= startOfMonth })

        let previousMonthStart = calendar.date(byAdding: .month, value: -1, to: startOfMonth) ?? Date()
        let previousMonth = buildSummary(from: records.filter {
            $0.date >= previousMonthStart && $0.date < startOfMonth
        })

        return UsageSnapshot(
            allTime: allTime,
            currentMonth: currentMonth,
            previousMonth: previousMonth
        )
    }

    /// Remove all recorded analytics data
    public func reset() {
        records.removeAll()
        persist()
        logger.info("Usage analytics reset")
    }

    /// Total number of recorded requests
    public var totalRequests: Int { records.count }
}

private extension UsageAnalytics {
    func buildSummary(from records: [UsageRecord]) -> UsageSummary {
        var requestsByProvider: [ProviderID: Int] = [:]
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCost: Double = 0
        var totalLatency: Double = 0

        for record in records {
            requestsByProvider[record.provider, default: 0] += 1
            totalInputTokens += record.inputTokens
            totalOutputTokens += record.outputTokens
            totalCost += record.cost
            totalLatency += record.latencySeconds
        }

        let averageLatency = records.isEmpty ? 0 : totalLatency / Double(records.count)

        return UsageSummary(
            totalRequests: records.count,
            requestsByProvider: requestsByProvider,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCost: totalCost,
            averageLatencySeconds: averageLatency
        )
    }

    func persist() {
        do {
            let data = try JSONEncoder().encode(records)
            defaults.set(data, forKey: persistenceKey)
        } catch {
            logger.error("Failed to persist usage analytics: \(error.localizedDescription)")
        }
    }

}

private struct UsageRecord: Codable, Sendable {
    let date: Date
    let provider: ProviderID
    let inputTokens: Int
    let outputTokens: Int
    let cost: Double
    let latencySeconds: Double
}

/// Aggregated usage statistics over a time period
public struct UsageSummary: Sendable, Equatable {
    public let totalRequests: Int
    public let requestsByProvider: [ProviderID: Int]
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCost: Double
    public let averageLatencySeconds: Double

    public var totalTokens: Int { totalInputTokens + totalOutputTokens }
}

/// Observable snapshot of usage analytics for SwiftUI binding
@Observable
public final class UsageSnapshot: Sendable {
    public let allTime: UsageSummary
    public let currentMonth: UsageSummary
    public let previousMonth: UsageSummary

    init(allTime: UsageSummary, currentMonth: UsageSummary, previousMonth: UsageSummary) {
        self.allTime = allTime
        self.currentMonth = currentMonth
        self.previousMonth = previousMonth
    }
}
