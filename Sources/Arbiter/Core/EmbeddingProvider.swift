// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// A provider that can turn text into embedding vectors.
///
/// Kept separate from `AIProvider` because the two capabilities do not travel
/// together: an embedding endpoint takes no messages, tools or sampling
/// controls, and several providers offer one without the other. A provider that
/// does both conforms to both.
public protocol EmbeddingProvider: Sendable {
    /// Which provider this is, for routing and cost attribution.
    var id: ProviderID { get }

    /// Embed one or more texts in a single request.
    ///
    /// - Parameters:
    ///   - texts: The inputs to embed. Order is preserved in the result.
    ///   - model: The embedding model to use, or `nil` for the provider default.
    ///   - dimensions: Truncate vectors to this many dimensions, where the
    ///     provider supports it. `nil` leaves the model's native size.
    /// - Returns: One vector per input, in the same order.
    func embed(
        _ texts: [String],
        model: String?,
        dimensions: Int?
    ) async throws -> EmbeddingResponse
}

public extension EmbeddingProvider {
    /// Embed a single string with the provider's default model.
    func embed(_ text: String) async throws -> [Float] {
        let response = try await embed([text], model: nil, dimensions: nil)
        guard let first = response.embeddings.first else {
            throw ArbiterError.decodingFailed(context: "Embedding response contained no vectors")
        }
        return first
    }
}

/// The result of an embedding request.
public struct EmbeddingResponse: Sendable, Equatable {
    /// One vector per input text, in request order.
    public let embeddings: [[Float]]
    /// The model that produced the vectors, as the provider reported it.
    public let model: String
    /// Tokens billed for the request.
    ///
    /// Embedding endpoints bill input only, so `outputTokens` is zero.
    public let usage: TokenUsage?

    public init(embeddings: [[Float]], model: String, usage: TokenUsage? = nil) {
        self.embeddings = embeddings
        self.model = model
        self.usage = usage
    }
}
