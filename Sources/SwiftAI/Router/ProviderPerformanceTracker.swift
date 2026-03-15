// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "PerformanceTracker")

/// Tracks real-world provider performance to improve routing decisions.
///
/// Records latency, success rate, and quality signals per provider.
/// The SmartRouter uses this data to prefer providers that perform
/// well for the current device and network conditions.
public actor ProviderPerformanceTracker {
    private var records: [RecordKey: PerformanceRecord] = [:]
    private let defaults: UserDefaults
    private let minimumSampleSize = 10

    public init() {
        let store = UserDefaults(suiteName: "com.swiftai.performance") ?? .standard
        self.defaults = store
        self.records = Self.loadRecords(from: store)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.records = Self.loadRecords(from: defaults)
    }

    func recordOutcome(
        provider: ProviderID,
        task: DetectedTask,
        latencySeconds: Double,
        succeeded: Bool,
        tokenCount: Int
    ) {
        let key = RecordKey(provider: provider, task: task)
        var record = records[key] ?? PerformanceRecord()
        record.totalRequests += 1
        if succeeded {
            record.successfulRequests += 1
        }
        record.totalLatencySeconds += latencySeconds
        record.totalTokens += tokenCount
        records[key] = record
        persist()
    }

    func scoreAdjustment(for provider: ProviderID, task: DetectedTask) -> Double {
        let key = RecordKey(provider: provider, task: task)
        guard let record = records[key], record.totalRequests >= minimumSampleSize else {
            return 0
        }

        let successAdjustment = successRateAdjustment(record.successRate)
        let latencyAdjustment = latencyScoreAdjustment(
            providerAverage: record.averageLatencySeconds,
            globalAverage: globalAverageLatency()
        )

        return min(max(successAdjustment + latencyAdjustment, -20), 20)
    }

    func summary(for provider: ProviderID) -> ProviderPerformance {
        var taskBreakdown: [DetectedTask: TaskPerformance] = [:]
        var totalRequests = 0
        var totalSuccesses = 0
        var totalLatency = 0.0

        for (key, record) in records where key.provider == provider {
            totalRequests += record.totalRequests
            totalSuccesses += record.successfulRequests
            totalLatency += record.totalLatencySeconds

            taskBreakdown[key.task] = TaskPerformance(
                successRate: record.successRate,
                averageLatencySeconds: record.averageLatencySeconds,
                requestCount: record.totalRequests
            )
        }

        let overallSuccessRate = totalRequests > 0
            ? Double(totalSuccesses) / Double(totalRequests) : 0
        let overallLatency = totalRequests > 0
            ? totalLatency / Double(totalRequests) : 0

        return ProviderPerformance(
            successRate: overallSuccessRate,
            averageLatencySeconds: overallLatency,
            requestCount: totalRequests,
            taskBreakdown: taskBreakdown
        )
    }

    func reset() {
        records.removeAll()
        persist()
    }
}

private extension ProviderPerformanceTracker {
    func successRateAdjustment(_ rate: Double) -> Double {
        switch rate {
        case 0.95...: return 10
        case 0.90..<0.95: return 5
        case 0.80..<0.90: return 0
        case 0.70..<0.80: return -10
        default: return -20
        }
    }

    func latencyScoreAdjustment(providerAverage: Double, globalAverage: Double) -> Double {
        guard globalAverage > 0 else { return 0 }
        let ratio = providerAverage / globalAverage
        if ratio > 2.0 { return -10 }
        if ratio > 1.0 { return -5 }
        return 5
    }

    func globalAverageLatency() -> Double {
        var totalLatency = 0.0
        var totalRequests = 0
        for record in records.values {
            totalLatency += record.totalLatencySeconds
            totalRequests += record.totalRequests
        }
        return totalRequests > 0 ? totalLatency / Double(totalRequests) : 0
    }

    func persist() {
        var encoded: [[String: Any]] = []
        for (key, record) in records {
            encoded.append([
                "provider": key.provider.rawValue,
                "task": key.task.rawValue,
                "totalRequests": record.totalRequests,
                "successfulRequests": record.successfulRequests,
                "totalLatencySeconds": record.totalLatencySeconds,
                "totalTokens": record.totalTokens,
            ])
        }
        defaults.set(encoded, forKey: "performance_records")
    }

    static func loadRecords(from defaults: UserDefaults) -> [RecordKey: PerformanceRecord] {
        guard let saved = defaults.array(forKey: "performance_records") as? [[String: Any]] else {
            return [:]
        }
        var loaded: [RecordKey: PerformanceRecord] = [:]
        for entry in saved {
            guard let providerRaw = entry["provider"] as? String,
                  let provider = ProviderID(rawValue: providerRaw),
                  let taskRaw = entry["task"] as? String,
                  let task = DetectedTask(rawValue: taskRaw),
                  let totalRequests = entry["totalRequests"] as? Int,
                  let successfulRequests = entry["successfulRequests"] as? Int,
                  let totalLatency = entry["totalLatencySeconds"] as? Double,
                  let totalTokens = entry["totalTokens"] as? Int else {
                continue
            }
            let key = RecordKey(provider: provider, task: task)
            loaded[key] = PerformanceRecord(
                totalRequests: totalRequests,
                successfulRequests: successfulRequests,
                totalLatencySeconds: totalLatency,
                totalTokens: totalTokens
            )
        }
        return loaded
    }
}

private struct RecordKey: Hashable, Sendable {
    let provider: ProviderID
    let task: DetectedTask
}

private struct PerformanceRecord: Sendable {
    var totalRequests: Int = 0
    var successfulRequests: Int = 0
    var totalLatencySeconds: Double = 0
    var totalTokens: Int = 0

    var successRate: Double {
        totalRequests > 0 ? Double(successfulRequests) / Double(totalRequests) : 0
    }

    var averageLatencySeconds: Double {
        totalRequests > 0 ? totalLatencySeconds / Double(totalRequests) : 0
    }
}

public struct ProviderPerformance: Sendable {
    public let successRate: Double
    public let averageLatencySeconds: Double
    public let requestCount: Int
    public let taskBreakdown: [DetectedTask: TaskPerformance]
}

public struct TaskPerformance: Sendable {
    public let successRate: Double
    public let averageLatencySeconds: Double
    public let requestCount: Int
}
