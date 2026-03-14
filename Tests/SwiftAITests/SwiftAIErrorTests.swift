// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("SwiftAIError")
struct SwiftAIErrorTests {

    // MARK: - errorDescription coverage for all cases

    @Test func providerUnavailableHasDescription() {
        let error = SwiftAIError.providerUnavailable(.anthropic, reason: "Server down")
        #expect(error.errorDescription?.contains("Anthropic") == true)
        #expect(error.errorDescription?.contains("Server down") == true)
    }

    @Test func authenticationFailedHasDescription() {
        let error = SwiftAIError.authenticationFailed(.openAI)
        #expect(error.errorDescription?.contains("Authentication") == true)
    }

    @Test func rateLimitedWithRetryAfterHasDescription() {
        let error = SwiftAIError.rateLimited(.anthropic, retryAfter: .seconds(30))
        #expect(error.errorDescription?.contains("rate limited") == true)
        #expect(error.errorDescription?.contains("30") == true)
    }

    @Test func rateLimitedWithoutRetryAfterHasDescription() {
        let error = SwiftAIError.rateLimited(.gemini, retryAfter: nil)
        #expect(error.errorDescription?.contains("rate limited") == true)
    }

    @Test func networkErrorHasDescription() {
        let error = SwiftAIError.networkError(underlying: URLError(.notConnectedToInternet))
        #expect(error.errorDescription?.contains("Network") == true)
    }

    @Test func timeoutHasDescription() {
        let error = SwiftAIError.timeout(.openAI, duration: .seconds(30))
        #expect(error.errorDescription?.contains("timed out") == true)
    }

    @Test func modelNotFoundHasDescription() {
        let error = SwiftAIError.modelNotFound("gpt-99")
        #expect(error.errorDescription?.contains("gpt-99") == true)
    }

    @Test func invalidRequestHasDescription() {
        let error = SwiftAIError.invalidRequest(reason: "Empty messages")
        #expect(error.errorDescription?.contains("Empty messages") == true)
    }

    @Test func contentFilteredHasDescription() {
        let error = SwiftAIError.contentFiltered(reason: "Harmful content")
        #expect(error.errorDescription?.contains("filtered") == true)
    }

    @Test func allProvidersFailedHasDescription() {
        let error = SwiftAIError.allProvidersFailed(attempts: [
            (.anthropic, URLError(.timedOut)),
            (.openAI, URLError(.notConnectedToInternet)),
        ])
        #expect(error.errorDescription?.contains("2") == true)
    }

    @Test func budgetExceededHasDescription() {
        let error = SwiftAIError.budgetExceeded(spent: 5.50, limit: 5.00)
        #expect(error.errorDescription?.contains("Budget") == true)
    }

    @Test func deviceNotCapableHasDescription() {
        let error = SwiftAIError.deviceNotCapable(reason: "Insufficient RAM")
        #expect(error.errorDescription?.contains("Insufficient RAM") == true)
    }

    @Test func decodingFailedHasDescription() {
        let error = SwiftAIError.decodingFailed(context: "Missing content field")
        #expect(error.errorDescription?.contains("decode") == true)
    }

    @Test func httpErrorHasDescription() {
        let error = SwiftAIError.httpError(statusCode: 503, body: "Service Unavailable")
        #expect(error.errorDescription?.contains("503") == true)
    }

    @Test func keychainErrorHasDescription() {
        let error = SwiftAIError.keychainError(status: -25300)
        #expect(error.errorDescription?.contains("Keychain") == true)
    }

    // MARK: - recoverySuggestion coverage

    @Test func allCasesHaveRecoverySuggestion() {
        let errors: [SwiftAIError] = [
            .providerUnavailable(.anthropic, reason: "test"),
            .authenticationFailed(.openAI),
            .rateLimited(.anthropic, retryAfter: .seconds(5)),
            .rateLimited(.anthropic, retryAfter: nil),
            .networkError(underlying: URLError(.notConnectedToInternet)),
            .timeout(.openAI, duration: .seconds(30)),
            .modelNotFound("test"),
            .invalidRequest(reason: "test"),
            .contentFiltered(reason: "test"),
            .allProvidersFailed(attempts: []),
            .budgetExceeded(spent: 1, limit: 0.5),
            .deviceNotCapable(reason: "test"),
            .decodingFailed(context: "test"),
            .httpError(statusCode: 500, body: ""),
            .keychainError(status: -1),
        ]

        for error in errors {
            #expect(error.recoverySuggestion != nil, "Missing recoverySuggestion for: \(error)")
            #expect(!error.recoverySuggestion!.isEmpty, "Empty recoverySuggestion for: \(error)")
        }
    }
}
