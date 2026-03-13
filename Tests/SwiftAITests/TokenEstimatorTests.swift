// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("TokenEstimator")
struct TokenEstimatorTests {

    @Test func estimateTokensForShortString() {
        let tokens = TokenEstimator.estimateTokens(for: "Hello world")
        #expect(tokens >= 1)
        #expect(tokens == Int(Double("Hello world".count) * 0.25))
    }

    @Test func estimateTokensForEmptyStringReturnsMinimumOne() {
        let tokens = TokenEstimator.estimateTokens(for: "")
        #expect(tokens == 1)
    }

    @Test func estimateTokensForMessages() {
        let messages: [Message] = [
            .user("Hello"),
            .assistant("Hi there, how can I help?"),
        ]
        let tokens = TokenEstimator.estimateTokens(for: messages)
        #expect(tokens > 0)
    }

    @Test func estimateTokensForEmptyMessagesReturnsZero() {
        let tokens = TokenEstimator.estimateTokens(for: [Message]())
        #expect(tokens == 0)
    }

    @Test func consistencyBetweenStringAndMessageEstimation() {
        let text = "This is a test message for estimation"
        let stringTokens = TokenEstimator.estimateTokens(for: text)
        let messageTokens = TokenEstimator.estimateTokens(for: [Message.user(text)])
        #expect(stringTokens == messageTokens)
    }
}
