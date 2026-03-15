// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
import Foundation
@testable import Arbiter

private actor Counter {
    var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

@Suite("RetryEngine")
struct RetryEngineTests {
    @Test("Succeeds on first attempt without retry")
    func immediateSuccess() async throws {
        let engine = RetryEngine(maxRetries: 3)
        let counter = Counter()

        let result = try await engine.execute {
            await counter.increment()
            return "success"
        }

        #expect(result == "success")
        let count = await counter.value
        #expect(count == 1)
    }

    @Test("Retries on transient failure then succeeds")
    func retryThenSuccess() async throws {
        let engine = RetryEngine(maxRetries: 3, baseDelay: .milliseconds(10))
        let counter = Counter()

        let result: String = try await engine.execute {
            let count = await counter.increment()
            if count < 3 {
                throw ArbiterError.networkError(underlying: URLError(.timedOut))
            }
            return "recovered"
        }

        #expect(result == "recovered")
        let count = await counter.value
        #expect(count == 3)
    }

    @Test("Does not retry on permanent errors")
    func permanentErrorNoRetry() async throws {
        let engine = RetryEngine(maxRetries: 3, baseDelay: .milliseconds(10))
        let counter = Counter()

        do {
            let _: String = try await engine.execute {
                await counter.increment()
                throw ArbiterError.authenticationFailed(.anthropic)
            }
            Issue.record("Expected error to be thrown")
        } catch let error as ArbiterError {
            if case .authenticationFailed = error {
                let count = await counter.value
                #expect(count == 1)
            } else {
                Issue.record("Expected authenticationFailed error")
            }
        }
    }

    @Test("Respects max retry limit")
    func exhaustsRetries() async throws {
        let engine = RetryEngine(maxRetries: 2, baseDelay: .milliseconds(10))
        let counter = Counter()

        do {
            let _: String = try await engine.execute {
                await counter.increment()
                throw ArbiterError.networkError(underlying: URLError(.timedOut))
            }
            Issue.record("Expected error to be thrown")
        } catch {
            let count = await counter.value
            #expect(count == 3)
        }
    }

    @Test("Network timeout is retryable")
    func networkTimeoutRetryable() {
        let engine = RetryEngine()
        #expect(engine.isRetryable(ArbiterError.networkError(underlying: URLError(.timedOut))))
    }

    @Test("Rate limit is retryable")
    func rateLimitRetryable() {
        let engine = RetryEngine()
        #expect(engine.isRetryable(ArbiterError.rateLimited(.openAI, retryAfter: .seconds(5))))
    }

    @Test("HTTP 429 is retryable")
    func http429Retryable() {
        let engine = RetryEngine()
        #expect(engine.isRetryable(ArbiterError.httpError(statusCode: 429, body: "")))
    }

    @Test("HTTP 503 is retryable")
    func http503Retryable() {
        let engine = RetryEngine()
        #expect(engine.isRetryable(ArbiterError.httpError(statusCode: 503, body: "")))
    }

    @Test("HTTP 400 is not retryable")
    func http400NotRetryable() {
        let engine = RetryEngine()
        #expect(!engine.isRetryable(ArbiterError.httpError(statusCode: 400, body: "")))
    }

    @Test("Auth failure is not retryable")
    func authNotRetryable() {
        let engine = RetryEngine()
        #expect(!engine.isRetryable(ArbiterError.authenticationFailed(.anthropic)))
    }

    @Test("Invalid request is not retryable")
    func invalidRequestNotRetryable() {
        let engine = RetryEngine()
        #expect(!engine.isRetryable(ArbiterError.invalidRequest(reason: "bad")))
    }

    @Test("Backoff delay increases exponentially")
    func exponentialBackoff() {
        let engine = RetryEngine(baseDelay: .seconds(1), maxDelay: .seconds(60))
        let error = ArbiterError.networkError(underlying: URLError(.timedOut))

        let delay0 = engine.retryDelay(for: error, attempt: 0)
        let delay1 = engine.retryDelay(for: error, attempt: 1)
        let delay2 = engine.retryDelay(for: error, attempt: 2)

        let seconds0 = Double(delay0.components.seconds) + Double(delay0.components.attoseconds) / 1e18
        let seconds1 = Double(delay1.components.seconds) + Double(delay1.components.attoseconds) / 1e18
        let seconds2 = Double(delay2.components.seconds) + Double(delay2.components.attoseconds) / 1e18

        #expect(seconds0 >= 1.0)
        #expect(seconds1 >= 2.0)
        #expect(seconds2 >= 4.0)
    }

    @Test("Rate limit uses Retry-After header")
    func retryAfterHeader() {
        let engine = RetryEngine()
        let error = ArbiterError.rateLimited(.anthropic, retryAfter: .seconds(30))

        let delay = engine.retryDelay(for: error, attempt: 0)
        #expect(delay == .seconds(30))
    }
}
