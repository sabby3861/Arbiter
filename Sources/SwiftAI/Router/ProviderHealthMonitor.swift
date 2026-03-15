// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "HealthMonitor")

/// Periodically checks provider availability and caches the results
/// to avoid repeated expensive availability checks during routing.
public actor ProviderHealthMonitor {
    private var healthCache: [ProviderID: HealthStatus] = [:]
    private let checkInterval: Duration
    private var monitorTask: Task<Void, Never>?
    private var providers: [any AIProvider] = []

    public init(checkInterval: Duration = .seconds(300)) {
        self.checkInterval = checkInterval
    }

    func start(providers: [any AIProvider]) {
        self.providers = providers
        monitorTask?.cancel()
        let interval = checkInterval
        monitorTask = Task { [self] in
            while !Task.isCancelled {
                await self.refreshAll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func isHealthy(_ providerID: ProviderID) -> Bool? {
        guard let status = healthCache[providerID] else { return nil }
        let elapsed = Date().timeIntervalSince(status.checkedAt)
        let ttl = Double(checkInterval.components.seconds)
            + Double(checkInterval.components.attoseconds) / 1e18
        if elapsed > ttl * 2 {
            return nil
        }
        return status.isAvailable
    }

    func scoreAdjustment(for providerID: ProviderID) -> Double {
        guard let healthy = isHealthy(providerID) else { return 0 }
        return healthy ? 5 : -30
    }

    func refreshAll() async {
        for provider in providers {
            let available = await provider.isAvailable
            healthCache[provider.id] = HealthStatus(
                isAvailable: available,
                checkedAt: Date()
            )
            logger.debug("Health check \(provider.id.rawValue): \(available ? "healthy" : "unhealthy")")
        }
    }
}

private struct HealthStatus: Sendable {
    let isAvailable: Bool
    let checkedAt: Date
}

/// Configuration for health monitoring
public enum HealthCheckConfig: Sendable {
    case disabled
    case enabled(interval: Duration)
}
