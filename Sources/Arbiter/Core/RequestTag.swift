// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Tags that classify the privacy sensitivity of a request.
///
/// Used by the router to enforce privacy policies:
/// ```swift
/// let response = try await ai.generate("Summarise my health report",
///     options: .init(tags: [.health]))
/// ```
public struct RequestTag: Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// General-purpose private data — forces on-device routing
    public static let `private` = RequestTag("private")

    /// Health-related data — forces on-device routing
    public static let health = RequestTag("health")

    /// Financial data — forces on-device routing
    public static let financial = RequestTag("financial")

    /// Personal information — forces on-device routing
    public static let personal = RequestTag("personal")
}
