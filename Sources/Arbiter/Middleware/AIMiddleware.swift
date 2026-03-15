// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// A middleware that can intercept and transform AI requests and responses.
///
/// Middleware runs in a pipeline: each middleware processes the request before
/// it reaches the provider, and can also transform the response on the way back.
///
/// ```swift
/// let ai = Arbiter {
///     $0.cloud(.anthropic(from: .keychain))
///     $0.middleware(LoggingMiddleware(logLevel: .standard))
///     $0.middleware(RequestSanitiserMiddleware())
/// }
/// ```
public protocol AIMiddleware: Sendable {
    /// Process a request before it reaches the provider.
    /// Return the (possibly modified) request, or throw to reject it.
    func process(_ request: AIRequest) async throws -> AIRequest

    /// Process a response before it reaches the caller.
    /// Return the (possibly modified) response.
    func process(_ response: AIResponse) async throws -> AIResponse
}

/// Default implementations — middleware only needs to override what it cares about
public extension AIMiddleware {
    func process(_ request: AIRequest) async throws -> AIRequest { request }
    func process(_ response: AIResponse) async throws -> AIResponse { response }
}
