// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "PrivacyGuard")

/// Prevents accidental data leakage by enforcing privacy routing rules.
///
/// ```swift
/// let ai = Arbiter {
///     $0.cloud(.anthropic(from: .keychain))
///     $0.local(OllamaProvider())
///     $0.privacy(.strict)
/// }
/// ```
public struct PrivacyGuard: Sendable {
    public var privateTags: Set<RequestTag>
    public var forceLocalOnly: Bool
    public var requireCloudConsent: Bool
    public var detectPII: Bool

    public init(
        privateTags: Set<RequestTag> = [.private, .health, .financial, .personal],
        forceLocalOnly: Bool = false,
        requireCloudConsent: Bool = false,
        detectPII: Bool = false
    ) {
        self.privateTags = privateTags
        self.forceLocalOnly = forceLocalOnly
        self.requireCloudConsent = requireCloudConsent
        self.detectPII = detectPII
    }

    public static let standard = PrivacyGuard()

    public static let strict = PrivacyGuard(
        forceLocalOnly: false,
        requireCloudConsent: true,
        detectPII: true
    )

    public static let localOnly = PrivacyGuard(forceLocalOnly: true)

    /// Whether the request should be forced to local/on-device providers.
    func shouldForceLocal(for request: AIRequest) -> Bool {
        if forceLocalOnly { return true }

        let requestTags = request.tags
        if !requestTags.isEmpty && !requestTags.isDisjoint(with: privateTags) {
            logger.debug("Privacy tags matched — forcing local routing")
            return true
        }

        if detectPII && containsPII(in: request) {
            logger.debug("PII detected in request — forcing local routing")
            return true
        }

        return false
    }
}

extension PrivacyGuard {
    private static let compiledPIIPatterns: [NSRegularExpression] = {
        let patterns = [
            #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#,
            #"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#,
            #"\b\d{3}-\d{2}-\d{4}\b"#,
            #"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    func containsPII(in request: AIRequest) -> Bool {
        let allText = extractText(from: request)
        guard !allText.isEmpty else { return false }

        let range = NSRange(allText.startIndex..., in: allText)
        return Self.compiledPIIPatterns.contains { regex in
            regex.firstMatch(in: allText, range: range) != nil
        }
    }

    private func extractText(from request: AIRequest) -> String {
        var parts = request.messages.compactMap { $0.content.text }
        if let system = request.systemPrompt { parts.append(system) }
        return parts.joined(separator: " ")
    }
}
