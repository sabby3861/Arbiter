// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "FallbackChain")

/// Manages automatic provider failover when the primary provider fails.
///
/// When a provider returns a transient error (network, rate limit, timeout),
/// the chain selects the next alternative and retries transparently. Permanent
/// errors (auth, bad request) are propagated immediately without fallback.
actor FallbackChain {
    private let retryEngine: RetryEngine
    let maxFallbacks: Int
    let retryDelay: Duration

    init(maxFallbacks: Int = 3, retryDelay: Duration = .milliseconds(200)) {
        self.maxFallbacks = maxFallbacks
        self.retryDelay = retryDelay
        self.retryEngine = RetryEngine(maxRetries: 1, baseDelay: retryDelay)
    }

    /// Execute a request with automatic provider fallback.
    ///
    /// Tries providers in the order specified by the routing decision.
    /// Each individual provider call gets a single retry via `RetryEngine`
    /// before moving to the next provider in the chain.
    func execute(
        providers: [any AIProvider],
        providerOrder: [ProviderID],
        operation: @Sendable (any AIProvider) async throws -> AIResponse
    ) async throws -> AIResponse {
        var attempts: [(ProviderID, any Error & Sendable)] = []
        let candidates = providerOrder.prefix(maxFallbacks + 1)

        for providerID in candidates {
            guard let provider = providers.first(where: { $0.id == providerID }) else {
                continue
            }

            do {
                try Task.checkCancellation()
                let response = try await retryEngine.execute {
                    try await operation(provider)
                }
                if !attempts.isEmpty {
                    logger.info("Fallback succeeded on \(providerID.rawValue) after \(attempts.count) failure(s)")
                }
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ArbiterError {
                logger.warning("Provider \(providerID.rawValue) failed: \(error.localizedDescription)")
                attempts.append((providerID, error))

                guard retryEngine.isRetryable(error) else {
                    throw error
                }

                if providerID != candidates.last {
                    try? await Task.sleep(for: retryDelay)
                }
            } catch {
                logger.warning("Provider \(providerID.rawValue) failed: \(error.localizedDescription)")
                attempts.append((providerID, UncategorizedError(message: error.localizedDescription)))
            }
        }

        throw ArbiterError.allProvidersFailed(attempts: attempts)
    }
}

/// Wraps a non-Sendable error description for use in Sendable contexts
private struct UncategorizedError: Error, Sendable {
    let message: String
    var localizedDescription: String { message }
}
