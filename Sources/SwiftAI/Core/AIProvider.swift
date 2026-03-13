// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// The unified protocol every AI provider conforms to
public protocol AIProvider: Sendable {
    /// Unique identifier for this provider
    var id: ProviderID { get }

    /// What this provider can do
    var capabilities: ProviderCapabilities { get }

    /// Check if provider is currently available (has network, model loaded, etc.)
    var isAvailable: Bool { get async }

    /// Generate a complete response
    func generate(_ request: AIRequest) async throws -> AIResponse

    /// Stream a response token by token
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error>
}
