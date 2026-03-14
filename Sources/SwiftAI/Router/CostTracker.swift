// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "CostTracker")

/// Tracks API spending per provider with UserDefaults persistence.
public actor CostTracker {
    private var spendByProvider: [ProviderID: Double] = [:]
    private var dailyRequestCount: Int = 0
    private var lastResetDay: String
    private let defaults: UserDefaults

    public init() {
        let store = UserDefaults(suiteName: "com.swiftai.costs") ?? .standard
        self.defaults = store
        if let saved = store.dictionary(forKey: "spend_by_provider") as? [String: Double] {
            for (key, value) in saved {
                if let id = ProviderID(rawValue: key) {
                    spendByProvider[id] = value
                }
            }
        }
        let today = Self.dayFormatter.string(from: Date())
        let savedDay = store.string(forKey: "daily_count_date") ?? today
        self.lastResetDay = savedDay
        self.dailyRequestCount = (savedDay == today) ? store.integer(forKey: "daily_count") : 0
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.lastResetDay = Self.dayFormatter.string(from: Date())
    }

    /// Record usage after a successful request
    public func recordUsage(provider: ProviderID, usage: TokenUsage, cost: Double) {
        resetDayIfNeeded()
        spendByProvider[provider, default: 0] += cost
        dailyRequestCount += 1
        persist()
        logger.debug("Recorded $\(cost, privacy: .public) for \(provider.rawValue)")
    }

    /// Estimate cost before sending a request
    public func estimateRequestCost(
        request: AIRequest,
        capabilities: ProviderCapabilities
    ) -> Double {
        let estimatedInputTokens = TokenEstimator.estimateTokens(for: request.messages)
        let estimatedOutputTokens = request.maxTokens ?? 1024

        let inputCost = (capabilities.costPerMillionInputTokens ?? 0) / 1_000_000
            * Double(estimatedInputTokens)
        let outputCost = (capabilities.costPerMillionOutputTokens ?? 0) / 1_000_000
            * Double(estimatedOutputTokens)
        return inputCost + outputCost
    }

    /// Total spend across all providers
    public var totalSpend: Double {
        spendByProvider.values.reduce(0, +)
    }

    /// Spend for a specific provider
    public func spend(for provider: ProviderID) -> Double {
        spendByProvider[provider, default: 0]
    }

    /// Number of requests made today
    public var todayRequestCount: Int {
        resetDayIfNeeded()
        return dailyRequestCount
    }

    /// Reset all tracked spending
    public func reset() {
        spendByProvider.removeAll()
        dailyRequestCount = 0
        persist()
        logger.info("Cost tracker reset")
    }
}

private extension CostTracker {
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var currentDayKey: String {
        Self.dayFormatter.string(from: Date())
    }

    func resetDayIfNeeded() {
        let today = currentDayKey
        if lastResetDay != today {
            dailyRequestCount = 0
            lastResetDay = today
        }
    }

    func persist() {
        let encoded = spendByProvider.reduce(into: [String: Double]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
        defaults.set(encoded, forKey: "spend_by_provider")
        defaults.set(dailyRequestCount, forKey: "daily_count")
        defaults.set(currentDayKey, forKey: "daily_count_date")
    }
}
