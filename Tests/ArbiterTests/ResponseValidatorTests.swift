// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
@testable import Arbiter

@Suite("ResponseValidator")
struct ResponseValidatorTests {
    let validator = ResponseValidator()

    @Test("Valid response passes through")
    func validResponse() {
        let response = AIResponse(
            id: "test", content: "Paris is the capital of France.",
            model: "test", provider: .anthropic,
            finishReason: .complete
        )
        let request = AIRequest.chat("What is the capital of France?")
        let result = validator.validate(response, for: request)
        #expect(result == .valid)
    }

    @Test("Empty response detected")
    func emptyResponse() {
        let response = AIResponse(
            id: "test", content: "   ",
            model: "test", provider: .anthropic
        )
        let request = AIRequest.chat("Hello")
        let result = validator.validate(response, for: request)
        #expect(result == .empty)
    }

    @Test("Whitespace-only response detected as empty")
    func whitespaceOnlyResponse() {
        let response = AIResponse(
            id: "test", content: "\n\t  \n  ",
            model: "test", provider: .anthropic
        )
        let request = AIRequest.chat("Hello")
        let result = validator.validate(response, for: request)
        #expect(result == .empty)
    }

    @Test("Refused response detected at start of content")
    func refusedAtStart() {
        let response = AIResponse(
            id: "test",
            content: "I cannot help with that request.",
            model: "test", provider: .anthropic
        )
        let request = AIRequest.chat("Do something")
        let result = validator.validate(response, for: request)
        if case .refused = result {
            // expected
        } else {
            Issue.record("Expected .refused, got \(result)")
        }
    }

    @Test("Refusal pattern mid-paragraph does NOT trigger refused")
    func refusalMidParagraph() {
        let longPrefix = String(repeating: "The committee decided that ", count: 8)
        let response = AIResponse(
            id: "test",
            content: "\(longPrefix)they cannot proceed with the merger due to regulatory concerns. The full analysis shows...",
            model: "test", provider: .anthropic
        )
        let request = AIRequest.chat("Summarize the report")
        let result = validator.validate(response, for: request)
        #expect(result == .valid)
    }

    @Test("Truncated response detected on maxTokens without punctuation")
    func truncatedDetected() {
        let response = AIResponse(
            id: "test",
            content: "The analysis shows that the market is trending toward",
            model: "test", provider: .anthropic,
            finishReason: .maxTokens
        )
        let request = AIRequest.chat("Analyze the market")
        let result = validator.validate(response, for: request)
        #expect(result == .truncated)
    }

    @Test("maxTokens with proper ending is valid, not truncated")
    func maxTokensWithPunctuation() {
        let response = AIResponse(
            id: "test",
            content: "The market is trending upward.",
            model: "test", provider: .anthropic,
            finishReason: .maxTokens
        )
        let request = AIRequest.chat("Analyze the market")
        let result = validator.validate(response, for: request)
        #expect(result == .valid)
    }

    @Test("maxTokens ending with exclamation is valid")
    func maxTokensWithExclamation() {
        let response = AIResponse(
            id: "test",
            content: "This is amazing!",
            model: "test", provider: .anthropic,
            finishReason: .maxTokens
        )
        let request = AIRequest.chat("React to this")
        let result = validator.validate(response, for: request)
        #expect(result == .valid)
    }

    @Test("maxTokens ending with question mark is valid")
    func maxTokensWithQuestion() {
        let response = AIResponse(
            id: "test",
            content: "What do you think?",
            model: "test", provider: .anthropic,
            finishReason: .maxTokens
        )
        let request = AIRequest.chat("Continue")
        let result = validator.validate(response, for: request)
        #expect(result == .valid)
    }

    @Test("Very short response triggers retryRecommended")
    func shortResponse() {
        let response = AIResponse(
            id: "test", content: "OK",
            model: "test", provider: .anthropic,
            finishReason: .complete
        )
        let request = AIRequest.chat("Write a detailed analysis")
        let result = validator.validate(response, for: request)
        if case .retryRecommended = result {
            // expected
        } else {
            Issue.record("Expected .retryRecommended, got \(result)")
        }
    }

    @Test("Short classification response is valid")
    func shortClassificationValid() {
        let response = AIResponse(
            id: "test", content: "Positive",
            model: "test", provider: .anthropic,
            finishReason: .complete
        )
        let request = AIRequest.chat("Is this positive or negative?")
        let analysis = RequestAnalysis(
            complexity: .trivial,
            detectedTask: .classification,
            estimatedInputTokens: 10,
            estimatedOutputTokens: 30,
            requiresReasoning: false,
            costEstimates: [:]
        )
        let result = validator.validate(response, for: request, analysis: analysis)
        #expect(result == .valid)
    }

    @Test("Multiple refusal patterns detected")
    func multipleRefusalPatterns() {
        let patterns = [
            "I'm unable to assist with that.",
            "As an AI, I don't have personal opinions.",
            "I am not able to process that request.",
            "Sorry, but I can't do that.",
            "I'm sorry, but I cannot fulfill this request.",
        ]
        for content in patterns {
            let response = AIResponse(
                id: "test", content: content,
                model: "test", provider: .anthropic
            )
            let request = AIRequest.chat("Test")
            let result = validator.validate(response, for: request)
            if case .refused = result {
                // expected
            } else {
                Issue.record("Expected .refused for '\(content)', got \(result)")
            }
        }
    }

    @Test("Completely empty string detected as empty")
    func completelyEmptyString() {
        let response = AIResponse(
            id: "test", content: "",
            model: "test", provider: .anthropic
        )
        let request = AIRequest.chat("Hello")
        let result = validator.validate(response, for: request)
        #expect(result == .empty)
    }

    @Test("Exactly 10 character response is valid, not retryRecommended")
    func boundaryTenCharacters() {
        let response = AIResponse(
            id: "test", content: "1234567890",
            model: "test", provider: .anthropic,
            finishReason: .complete
        )
        let request = AIRequest.chat("Do something")
        let result = validator.validate(response, for: request)
        #expect(result == .valid)
    }

    @Test("Nine character response triggers retryRecommended")
    func boundaryNineCharacters() {
        let response = AIResponse(
            id: "test", content: "123456789",
            model: "test", provider: .anthropic,
            finishReason: .complete
        )
        let request = AIRequest.chat("Do something")
        let result = validator.validate(response, for: request)
        if case .retryRecommended = result {
            // expected
        } else {
            Issue.record("Expected .retryRecommended, got \(result)")
        }
    }

    @Test("Nil finishReason with valid content passes")
    func nilFinishReasonValid() {
        let response = AIResponse(
            id: "test",
            content: "This is a perfectly fine response.",
            model: "test", provider: .anthropic,
            finishReason: nil
        )
        let request = AIRequest.chat("Hello")
        let result = validator.validate(response, for: request)
        #expect(result == .valid)
    }

    @Test("Refusal at character 201 does NOT trigger refused")
    func refusalBeyondPrefixBoundary() {
        let padding = String(repeating: "a", count: 195)
        let response = AIResponse(
            id: "test",
            content: "\(padding) I cannot help with that.",
            model: "test", provider: .anthropic
        )
        let request = AIRequest.chat("Test")
        let result = validator.validate(response, for: request)
        #expect(result == .valid)
    }

    @Test("Truncated response with trailing whitespace before check")
    func truncatedWithTrailingWhitespace() {
        let response = AIResponse(
            id: "test",
            content: "The analysis shows trending toward   ",
            model: "test", provider: .anthropic,
            finishReason: .maxTokens
        )
        let request = AIRequest.chat("Analyze")
        let result = validator.validate(response, for: request)
        #expect(result == .truncated)
    }
}
