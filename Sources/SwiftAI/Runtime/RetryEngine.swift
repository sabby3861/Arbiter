// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "RetryEngine")

/// Smart retry logic with exponential backoff and jitter.
///
/// Retries transient failures (timeouts, rate limits, server errors) while
/// immediately propagating permanent failures (bad request, auth, not found).
struct RetryEngine: Sendable {
    let maxRetries: Int
    let baseDelay: Duration
    let maxDelay: Duration

    init(maxRetries: Int = 3, baseDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(30)) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    func execute<T: Sendable>(
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?

        for attempt in 0...maxRetries {
            do {
                try Task.checkCancellation()
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error

                guard attempt < maxRetries, isRetryable(error) else {
                    throw error
                }

                let delay = retryDelay(for: error, attempt: attempt)
                logger.debug("Retry \(attempt + 1)/\(self.maxRetries) after \(delay)")
                try await Task.sleep(for: delay)
            }
        }

        throw lastError ?? SwiftAIError.invalidRequest(reason: "Retry engine exhausted with no error")
    }

    func isRetryable(_ error: any Error) -> Bool {
        if let swiftAIError = error as? SwiftAIError {
            switch swiftAIError {
            case .networkError, .timeout, .rateLimited:
                return true
            case .httpError(let statusCode, _):
                return statusCode == 429 || statusCode == 500 || statusCode == 502 || statusCode == 503
            case .authenticationFailed, .invalidRequest, .modelNotFound, .contentFiltered,
                 .budgetExceeded, .dailyLimitExceeded, .deviceNotCapable, .decodingFailed,
                 .keychainError, .providerUnavailable, .allProvidersFailed:
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }

        return false
    }

    func retryDelay(for error: any Error, attempt: Int) -> Duration {
        if let swiftAIError = error as? SwiftAIError,
           case .rateLimited(_, let retryAfter) = swiftAIError,
           let retryAfter {
            return retryAfter
        }

        let exponentialSeconds = Double(baseDelay.components.seconds)
            + Double(baseDelay.components.attoseconds) / 1e18
        let backoff = exponentialSeconds * pow(2.0, Double(attempt))

        let maxSeconds = Double(maxDelay.components.seconds)
            + Double(maxDelay.components.attoseconds) / 1e18
        let capped = min(backoff, maxSeconds)

        let jitter = Double.random(in: 0...0.5) * capped
        return .milliseconds(Int((capped + jitter) * 1000))
    }
}
