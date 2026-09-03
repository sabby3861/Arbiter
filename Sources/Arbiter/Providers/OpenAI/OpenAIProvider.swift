// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "OpenAIProvider")

/// OpenAI-compatible API provider (works with OpenAI, Azure, Groq, Together, Perplexity)
public struct OpenAIProvider: AIProvider, Sendable {
    public let id: ProviderID = .openAI

    private static let defaultBaseURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.openai.com"
        return components.url ?? URL(filePath: "/")
    }()

    private let apiKey: String
    private let baseURL: URL
    private let organization: String?
    private let defaultModel: OpenAIModel
    private let mapper: OpenAIMapper
    private let responsesMapper: OpenAIResponsesMapper
    private let session: URLSession

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .completion, .codeGeneration, .summarization,
                             .translation, .structuredOutput, .imageUnderstanding,
                             .embedding],
            maxContextTokens: defaultModel.contextWindow,
            supportsStreaming: defaultModel.supportsStreaming,
            supportsToolCalling: true,
            supportsImageInput: true,
            costPerMillionInputTokens: defaultModel.costPerMillionInput,
            costPerMillionOutputTokens: defaultModel.costPerMillionOutput,
            estimatedLatency: .moderate,
            privacyLevel: .thirdPartyCloud
        )
    }

    public var isAvailable: Bool {
        get async { !apiKey.isEmpty }
    }

    /// Create from Keychain
    public init(
        keyStorage provider: ProviderID = .openAI,
        baseURL: URL? = nil,
        organization: String? = nil,
        defaultModel: OpenAIModel = .gpt4o
    ) throws {
        let key = try SecureKeyStorage.retrieve(forProvider: provider)
        self.init(resolvedKey: key, baseURL: baseURL, organization: organization, defaultModel: defaultModel)
    }

    /// Create with a raw API key string
    @available(*, deprecated, message: "Use init(keyStorage:) with SecureKeyStorage for production apps")
    public init(
        apiKey: String,
        baseURL: URL? = nil,
        organization: String? = nil,
        defaultModel: OpenAIModel = .gpt4o
    ) {
        self.init(resolvedKey: apiKey, baseURL: baseURL, organization: organization, defaultModel: defaultModel)
    }

    init(resolvedKey: String, baseURL: URL?, organization: String? = nil, defaultModel: OpenAIModel = .gpt4o) {
        self.apiKey = resolvedKey
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.organization = organization
        self.defaultModel = defaultModel
        self.mapper = OpenAIMapper(defaultModel: defaultModel)
        self.responsesMapper = OpenAIResponsesMapper(defaultModel: defaultModel)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        try Task.checkCancellation()
        let urlRequest = try buildURLRequest(for: request, stream: false)

        let (responseData, httpResponse) = try await performDataRequest(urlRequest)
        try validateHTTPResponse(httpResponse, body: responseData)
        return switch Self.api(for: request) {
        case .chatCompletions: try mapper.parseResponse(responseData)
        case .responses: try responsesMapper.parseResponse(responseData)
        }
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        // The Responses transport uses a different SSE event scheme, which
        // Arbiter does not parse yet, so a `.responses` request is completed in
        // one call and delivered as a single chunk. The content is the same;
        // only the incremental delivery is missing.
        guard Self.api(for: request) == .chatCompletions else {
            return singleChunkStream(for: request)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(for: request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// MARK: - Embeddings

extension OpenAIProvider: EmbeddingProvider {
    /// Embed texts via `POST /v1/embeddings`.
    ///
    /// - Parameters:
    ///   - texts: Inputs to embed; the result preserves this order.
    ///   - model: An embedding model ID, or `nil` for `defaultEmbeddingModel`.
    ///     Chat models cannot embed, so this is separate from `defaultModel`.
    ///   - dimensions: Truncate to this many dimensions. Only the
    ///     `text-embedding-3` models accept it.
    public func embed(
        _ texts: [String],
        model: String? = nil,
        dimensions: Int? = nil
    ) async throws -> EmbeddingResponse {
        guard !texts.isEmpty else {
            throw ArbiterError.invalidRequest(reason: "Embedding request contained no input")
        }
        try Task.checkCancellation()

        let modelID = model ?? Self.defaultEmbeddingModel
        var body: [String: Any] = ["model": modelID, "input": texts]
        if let dimensions {
            body["dimensions"] = dimensions
        }

        var urlRequest = authorizedRequest(path: "v1/embeddings")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performDataRequest(urlRequest)
        try validateHTTPResponse(response, body: data)
        return try Self.parseEmbeddingResponse(data, requestedModel: modelID, inputCount: texts.count)
    }

    /// The embedding model used when the caller names none: the cheapest of the
    /// current generation, at $0.02 per million tokens.
    public static let defaultEmbeddingModel = "text-embedding-3-small"

    static func parseEmbeddingResponse(
        _ data: Data,
        requestedModel: String,
        inputCount: Int
    ) throws -> EmbeddingResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw ArbiterError.decodingFailed(context: "Embedding response has no data array")
        }

        // The API documents that vectors come back in input order, but it also
        // returns an explicit `index` — sorting by it makes the guarantee local
        // rather than assumed.
        let ordered = items.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        let vectors: [[Float]] = ordered.compactMap { item in
            (item["embedding"] as? [Double]).map { $0.map(Float.init) }
        }
        guard vectors.count == inputCount else {
            throw ArbiterError.decodingFailed(
                context: "Embedding response returned \(vectors.count) vectors for \(inputCount) inputs"
            )
        }

        var usage: TokenUsage?
        if let rawUsage = json["usage"] as? [String: Any],
           let promptTokens = rawUsage["prompt_tokens"] as? Int {
            // Embedding endpoints bill input only.
            usage = TokenUsage(inputTokens: promptTokens, outputTokens: 0)
        }

        return EmbeddingResponse(
            embeddings: vectors,
            model: json["model"] as? String ?? requestedModel,
            usage: usage
        )
    }
}

extension OpenAIProvider {
    /// Which transport this request asked for.
    ///
    /// Chat Completions unless the caller opted in, because that is the shape
    /// OpenAI-compatible hosts implement.
    static func api(for request: AIRequest) -> OpenAIAPI {
        (request.providerOptions[.openAI] as? OpenAIOptions)?.api ?? .chatCompletions
    }
}

private extension OpenAIProvider {
    func performStream(
        for request: AIRequest,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        let urlRequest = try buildURLRequest(for: request, stream: true)
        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArbiterError.networkError(underlying: URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw mapHTTPError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        try await parseSSEStream(bytes: bytes, continuation: continuation)
    }

    func parseSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        var state = OpenAIStreamState()

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            guard trimmedLine.hasPrefix("data: ") else { continue }
            let eventData = String(trimmedLine.dropFirst(6))

            if let chunk = mapper.parseStreamEvent(eventData, state: &state) {
                continuation.yield(chunk)
                if chunk.isComplete { return }
            }
        }

        // The body ended without a `[DONE]` marker or a usage chunk — some
        // OpenAI-compatible hosts just close the connection. Since neither the
        // finish_reason chunk nor a content chunk is marked complete, the turn
        // would otherwise finish with no terminating chunk at all, stranding
        // the accumulated usage, finish reason and tool calls.
        state.completeOpenToolCalls()
        continuation.yield(mapper.finalChunk(state: state))
    }

    /// Complete the request in one call and deliver it as a single chunk.
    ///
    /// Used for the Responses transport, whose SSE scheme Arbiter does not
    /// parse yet.
    func singleChunkStream(for request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.generate(request)
                    continuation.yield(AIStreamChunk(
                        delta: response.content,
                        accumulatedContent: response.content,
                        isComplete: true,
                        usage: response.usage,
                        finishReason: response.finishReason,
                        toolCalls: response.toolCalls.isEmpty ? nil : response.toolCalls,
                        provider: .openAI
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Issue a request and normalise transport failures into `ArbiterError`.
    func performDataRequest(_ urlRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ArbiterError.networkError(underlying: URLError(.badServerResponse))
            }
            return (data, http)
        } catch let error as ArbiterError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            logger.error("Network request failed: \(urlError.localizedDescription)")
            throw ArbiterError.networkError(underlying: urlError)
        } catch {
            throw ArbiterError.networkError(underlying: URLError(.unknown))
        }
    }

    /// A POST to `path` carrying the credentials every endpoint needs.
    ///
    /// Shared so a header added for one endpoint cannot drift away from the
    /// others.
    func authorizedRequest(path: String) -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let organization {
            urlRequest.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
        }
        return urlRequest
    }

    func buildURLRequest(for request: AIRequest, stream: Bool) throws -> URLRequest {
        let api = Self.api(for: request)
        var urlRequest = authorizedRequest(
            path: api == .responses ? "v1/responses" : "v1/chat/completions"
        )
        if stream {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        urlRequest.httpBody = switch api {
        case .chatCompletions: try mapper.buildRequestBody(request, stream: stream)
        case .responses: try responsesMapper.buildRequestBody(request, stream: stream)
        }
        return urlRequest
    }

    func validateHTTPResponse(_ response: HTTPURLResponse, body: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let bodyString = String(data: body, encoding: .utf8) ?? ""
            throw mapHTTPError(statusCode: response.statusCode, body: bodyString)
        }
    }

    func mapHTTPError(statusCode: Int, body: String) -> ArbiterError {
        logger.warning("HTTP error \(statusCode) from OpenAI API")
        switch statusCode {
        case 401: return .authenticationFailed(.openAI)
        case 429: return .rateLimited(.openAI, retryAfter: nil)
        case 400: return .invalidRequest(reason: extractErrorMessage(from: body))
        case 404: return .modelNotFound(extractErrorMessage(from: body))
        default: return .httpError(statusCode: statusCode, body: redactKeys(body))
        }
    }

    func extractErrorMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return body.isEmpty ? "Unknown error" : String(body.prefix(500))
        }
        return message
    }

    func redactKeys(_ text: String) -> String {
        let pattern = #"(sk-[a-zA-Z0-9]{2})[a-zA-Z0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1[REDACTED]")
    }
}
