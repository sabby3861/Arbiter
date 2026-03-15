// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Validates AI responses before returning them to the caller.
///
/// Detects empty, refused, truncated, or low-quality responses and
/// can trigger automatic retry with the same or different provider.
///
/// Disabled by default. Enable via configuration:
/// ```swift
/// let ai = Arbiter {
///     $0.cloud(.anthropic(from: .keychain))
///     $0.responseValidation(.enabled)
/// }
/// ```
public struct ResponseValidator: Sendable {

    private static let refusalPatterns: [String] = [
        "i cannot",
        "i can't",
        "i'm unable to",
        "i am unable to",
        "as an ai",
        "i don't have the ability",
        "i'm not able to",
        "i am not able to",
        "sorry, but i can't",
        "i'm sorry, but i cannot",
    ]

    private static let sentenceEndingCharacters: Set<Character> = [
        ".", "!", "?", "\"", "»", "」",
    ]

    private static let minimumContentLength = 10

    public init() {}

    public func validate(
        _ response: AIResponse,
        for request: AIRequest,
        analysis: RequestAnalysis? = nil
    ) -> ValidationResult {
        let trimmed = response.content
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return .empty
        }

        if let refusalReason = detectRefusal(in: trimmed) {
            return .refused(reason: refusalReason)
        }

        if response.finishReason == .maxTokens {
            let lastChar = trimmed.last
            let endsWithPunctuation = lastChar.map {
                Self.sentenceEndingCharacters.contains($0)
            } ?? false

            if !endsWithPunctuation {
                return .truncated
            }
        }

        let isClassification = analysis?.detectedTask == .classification
        if !isClassification && trimmed.count < Self.minimumContentLength {
            return .retryRecommended(
                reason: "Response too short (\(trimmed.count) characters)"
            )
        }

        return .valid
    }
}

private extension ResponseValidator {
    func detectRefusal(in content: String) -> String? {
        let prefix = String(content.prefix(200)).lowercased()
        for pattern in Self.refusalPatterns {
            if prefix.contains(pattern) {
                return pattern
            }
        }
        return nil
    }
}

public enum ValidationResult: Sendable, Equatable {
    case valid
    case empty
    case refused(reason: String)
    case truncated
    case retryRecommended(reason: String)
}

public enum ResponseValidationPolicy: Sendable {
    case disabled
    case enabled
    case custom(ResponseValidator)
}
