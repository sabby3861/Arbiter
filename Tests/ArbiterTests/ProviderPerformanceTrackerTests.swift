// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
import Foundation
@testable import Arbiter

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

    /// The router tests build their trackers with `.inMemory()` so a routing assertion
    /// cannot be decided by records an earlier run left behind. What that needs from the
    /// tracker is that it still *scores* — an inert tracker would make those tests pass
    /// for the wrong reason — and that its records reach no other instance.
    ///
    /// Deliberately not asserted here: that nothing lands in the shared
    /// `com.arbiter.performance` suite. Reading that suite is a race — the tests that
    /// build a production `Arbiter` write to it while this runs — so the assertion would
    /// be flaky in the direction of a false pass. `persist()`'s `guard let defaults`
    /// is what carries that property, and both nil-defaults entry points are internal.
    @Test("An in-memory tracker scores normally and does not outlive its instance")
    func inMemoryTrackerRecordsButDoesNotPersist() async {
        let tracker = ProviderPerformanceTracker.inMemory()
        for _ in 0..<15 {
            await tracker.recordOutcome(
                provider: .anthropic, task: .conversation,
                latencySeconds: 0.5, succeeded: true, tokenCount: 100
            )
        }

        // Identical to the persisted tracker's behaviour: the records are real and the
        // minimum sample size is met, so an adjustment is produced.
        #expect(await tracker.summary(for: .anthropic).requestCount == 15)
        #expect(await tracker.scoreAdjustment(for: .anthropic, task: .conversation) > 0)

        let fresh = ProviderPerformanceTracker.inMemory()
        #expect(await fresh.summary(for: .anthropic).requestCount == 0)
        #expect(await fresh.scoreAdjustment(for: .anthropic, task: .conversation) == 0)
    }
}
