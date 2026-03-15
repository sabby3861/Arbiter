// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
import Foundation
@testable import SwiftAI

@Suite("ProviderPerformanceTracker")
struct ProviderPerformanceTrackerTests {
    @Test("Fresh tracker returns 0 adjustment")
    func freshTrackerReturnsZero() async {
        let tracker = ProviderPerformanceTracker(
            defaults: UserDefaults(suiteName: "test.perf.\(UUID().uuidString)")!
        )
        let adjustment = await tracker.scoreAdjustment(for: .anthropic, task: .conversation)
        #expect(adjustment == 0)
    }

    @Test("High success rate gives positive adjustment")
    func highSuccessRatePositive() async {
        let tracker = ProviderPerformanceTracker(
            defaults: UserDefaults(suiteName: "test.perf.\(UUID().uuidString)")!
        )

        for _ in 0..<15 {
            await tracker.recordOutcome(
                provider: .anthropic,
                task: .conversation,
                latencySeconds: 0.5,
                succeeded: true,
                tokenCount: 100
            )
        }

        let adjustment = await tracker.scoreAdjustment(for: .anthropic, task: .conversation)
        #expect(adjustment > 0)
    }

    @Test("Low success rate gives negative adjustment")
    func lowSuccessRateNegative() async {
        let tracker = ProviderPerformanceTracker(
            defaults: UserDefaults(suiteName: "test.perf.\(UUID().uuidString)")!
        )

        for i in 0..<15 {
            await tracker.recordOutcome(
                provider: .anthropic,
                task: .conversation,
                latencySeconds: 0.5,
                succeeded: i < 5,
                tokenCount: 100
            )
        }

        let adjustment = await tracker.scoreAdjustment(for: .anthropic, task: .conversation)
        #expect(adjustment < 0)
    }

    @Test("Minimum sample size of 10 before adjustments activate")
    func minimumSampleSize() async {
        let tracker = ProviderPerformanceTracker(
            defaults: UserDefaults(suiteName: "test.perf.\(UUID().uuidString)")!
        )

        for _ in 0..<9 {
            await tracker.recordOutcome(
                provider: .anthropic,
                task: .conversation,
                latencySeconds: 0.5,
                succeeded: true,
                tokenCount: 100
            )
        }

        let adjustment = await tracker.scoreAdjustment(for: .anthropic, task: .conversation)
        #expect(adjustment == 0)
    }

    @Test("Data persists across tracker instances")
    func persistenceAcrossInstances() async {
        let suiteName = "test.perf.\(UUID().uuidString)"

        let tracker1 = ProviderPerformanceTracker(
            defaults: UserDefaults(suiteName: suiteName)!
        )

        for _ in 0..<12 {
            await tracker1.recordOutcome(
                provider: .openAI,
                task: .codeGeneration,
                latencySeconds: 1.0,
                succeeded: true,
                tokenCount: 200
            )
        }

        let tracker2 = ProviderPerformanceTracker(
            defaults: UserDefaults(suiteName: suiteName)!
        )

        let summary = await tracker2.summary(for: .openAI)
        #expect(summary.requestCount == 12)
    }

    @Test("Provider performance summary is accurate")
    func summaryAccuracy() async {
        let tracker = ProviderPerformanceTracker(
            defaults: UserDefaults(suiteName: "test.perf.\(UUID().uuidString)")!
        )

        for _ in 0..<10 {
            await tracker.recordOutcome(
                provider: .anthropic,
                task: .codeGeneration,
                latencySeconds: 1.0,
                succeeded: true,
                tokenCount: 100
            )
        }

        let summary = await tracker.summary(for: .anthropic)
        #expect(summary.requestCount == 10)
        #expect(summary.successRate == 1.0)
        #expect(summary.averageLatencySeconds == 1.0)
    }
}
