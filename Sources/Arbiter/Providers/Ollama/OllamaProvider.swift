// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "OllamaProvider")

/// Ollama local server provider.
///
/// Connects to a locally-running Ollama instance. No API key required.
/// ```swift
/// let ai = Arbiter {
///     $0.local(OllamaProvider())
/// }
/// ```
public struct OllamaProvider: AIProvider, Sendable {
    public let id: ProviderID = .ollama

    private static let defaultBaseURL: URL = {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = 11434
        return components.url ?? URL(filePath: "/")
    }()

    private let baseURL: URL
    private let defaultModel: String
    private let mapper: OllamaMapper
    private let session: URLSession

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .completion, .codeGeneration, .summarization,
                             .translation, .structuredOutput, .imageUnderstanding,
                             .embedding],
            maxContextTokens: 128_000,
            supportsStreaming: true,
            supportsToolCalling: true,
            supportsImageInput: true,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .fast,
            privacyLevel: .onDevice
        )
    }

    /// Checks if the Ollama server is reachable
    public var isAvailable: Bool {
        get async {
            let healthURL = baseURL.appendingPathComponent("api/tags")
            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 3

            do {
                let (_, response) = try await session.data(for: request)
                let httpResponse = response as? HTTPURLResponse
                return httpResponse.map { (200...299).contains($0.statusCode) } ?? false
            } catch {
                logger.debug("Ollama server not reachable: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Create an Ollama provider
    /// - Parameters:
    ///   - baseURL: Ollama server URL (defaults to http://localhost:11434)
    ///   - defaultModel: Model to use when none specified (defaults to "llama3.2")
    public init(baseURL: URL? = nil, defaultModel: String = "llama3.2") {
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.defaultModel = defaultModel
        self.mapper = OllamaMapper(defaultModel: defaultModel)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        try Task.checkCancellation()

        let chatURL = baseURL.appendingPathComponent("api/chat")
        var urlRequest = URLRequest(url: chatURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try mapper.buildChatBody(request, stream: false)

        let responseData: Data
        let httpResponse: HTTPURLResponse
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ArbiterError.networkError(underlying: URLError(.badServerResponse))
            }
            responseData = data
            httpResponse = http
        } catch let error as ArbiterError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            logger.error("Ollama request failed: \(urlError.localizedDescription)")
            throw ArbiterError.providerUnavailable(.ollama, reason: "Server not reachable")
        } catch {
            throw ArbiterError.networkError(underlying: URLError(.unknown))
        }

        try validateHTTPResponse(httpResponse, body: responseData)
        return try mapper.parseResponse(responseData)
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
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

    /// List models installed on the Ollama server, via `GET /api/tags`.
    public func listModels() async throws -> [String] {
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: URLRequest(url: tagsURL))
        } catch let urlError as URLError {
            throw ArbiterError.providerUnavailable(.ollama, reason: "Server not reachable: \(urlError.localizedDescription)")
        } catch {
            throw ArbiterError.networkError(underlying: URLError(.unknown))
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ArbiterError.providerUnavailable(.ollama, reason: "Failed to list models")
        }

        return Self.parseModelList(data)
    }

    /// Read the model names out of an `/api/tags` body.
    ///
    /// A body that is not the documented shape lists nothing rather than
    /// failing: the endpoints themselves report a missing model precisely, so an
    /// empty listing is the harmless answer here.
    static func parseModelList(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { $0["name"] as? String }
    }
}

// MARK: - Embeddings

extension OllamaProvider: EmbeddingProvider {
    /// Embed texts via `POST /api/embed`.
    ///
    /// - Parameters:
    ///   - texts: Inputs to embed; the result preserves this order.
    ///   - model: An embedding model the server has pulled — `all-minilm` and
    ///     `nomic-embed-text` are the ones Ollama's own docs use. Required: a
    ///     chat model cannot embed, so the provider's `defaultModel` is not a
    ///     usable stand-in and there is no server-side default to fall back to.
    ///   - dimensions: Truncate to this many dimensions, where the model
    ///     supports it.
    /// - Throws: ``ArbiterError/invalidRequest(reason:)`` when `model` is `nil`
    ///   or `texts` is empty; ``ArbiterError/modelNotFound(_:)`` when the server
    ///   has not pulled the model.
    ///
    /// Verified 3 September 2026 against
    /// https://raw.githubusercontent.com/ollama/ollama/main/docs/api.md, and the
    /// two model names against https://ollama.com/library/nomic-embed-text and
    /// the `all-minilm` examples in that same api.md.
    public func embed(
        _ texts: [String],
        model: String? = nil,
        dimensions: Int? = nil
    ) async throws -> EmbeddingResponse {
        guard !texts.isEmpty else {
            throw ArbiterError.invalidRequest(reason: "Embedding request contained no input")
        }
        guard let model else {
            throw ArbiterError.invalidRequest(
                reason: "Ollama has no default embedding model: name one you have pulled, "
                    + "such as \"nomic-embed-text\" or \"all-minilm\""
            )
        }
        try Task.checkCancellation()

        let body = Self.buildEmbeddingBody(model: model, texts: texts, dimensions: dimensions)

        let embedURL = baseURL.appendingPathComponent("api/embed")
        var urlRequest = URLRequest(url: embedURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            throw ArbiterError.providerUnavailable(
                .ollama, reason: "Server not reachable: \(urlError.localizedDescription)"
            )
        } catch {
            throw ArbiterError.networkError(underlying: URLError(.unknown))
        }

        guard let http = response as? HTTPURLResponse else {
            throw ArbiterError.networkError(underlying: URLError(.badServerResponse))
        }
        try validateHTTPResponse(http, body: data)
        return try Self.parseEmbeddingResponse(data, requestedModel: model, inputCount: texts.count)
    }

    /// Build the `/api/embed` body.
    ///
    /// `input` takes a string or an array of them; an array is sent even for one
    /// text so the response shape does not change with the input count. The
    /// superseded `/api/embeddings` endpoint spelled this `prompt` and returned
    /// a single `embedding` — this is the current endpoint, not that one.
    static func buildEmbeddingBody(
        model: String,
        texts: [String],
        dimensions: Int?
    ) -> [String: Any] {
        var body: [String: Any] = ["model": model, "input": texts]
        if let dimensions {
            body["dimensions"] = dimensions
        }
        return body
    }

    /// Parse `/api/embed`.
    ///
    /// Unlike OpenAI's endpoint the vectors carry no `index`, so request order
    /// is the only ordering there is — a short or long array is a mismatch this
    /// reports rather than silently pairs up wrong.
    static func parseEmbeddingResponse(
        _ data: Data,
        requestedModel: String,
        inputCount: Int
    ) throws -> EmbeddingResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawVectors = json["embeddings"] as? [[Double]] else {
            throw ArbiterError.decodingFailed(context: "Embedding response has no embeddings array")
        }

        let vectors = rawVectors.map { $0.map(Float.init) }
        guard vectors.count == inputCount else {
            throw ArbiterError.decodingFailed(
                context: "Embedding response returned \(vectors.count) vectors for \(inputCount) inputs"
            )
        }

        // Embedding endpoints bill input only.
        let usage = (json["prompt_eval_count"] as? Int).map {
            TokenUsage(inputTokens: $0, outputTokens: 0)
        }

        return EmbeddingResponse(
            embeddings: vectors,
            model: json["model"] as? String ?? requestedModel,
            usage: usage
        )
    }
}

// MARK: - Errors

extension OllamaProvider {
    /// How much of an error body to read off a failed stream before giving up.
    static let maxErrorBodyBytes = 8192

    /// Map an HTTP failure onto the error a caller can act on.
    ///
    /// A model the server has not pulled comes back as 404 with
    /// `{"error": "model \"x\" not found, try pulling it first"}`, so 404
    /// becomes ``ArbiterError/modelNotFound(_:)``: a caller learns what to pull
    /// instead of reading a status code out of an error body.
    ///
    /// This also reaches the streaming path, which used to report every non-2xx
    /// as `providerUnavailable` — so a stream interrupted by a full queue (503)
    /// or a server slip (500/502) is now retried, where before it was not.
    static func mapHTTPError(statusCode: Int, body: Data) -> ArbiterError {
        logger.warning("Ollama HTTP error \(statusCode)")
        let message = extractErrorMessage(from: body)
        switch statusCode {
        case 400: return .invalidRequest(reason: message)
        case 404: return .modelNotFound(modelName(in: message) ?? message)
        // Ollama queues requests and answers 503 once the queue is full — the
        // one status here worth retrying, and `.overloaded` is the case the
        // retry engine treats that way.
        case 503: return .overloaded(.ollama)
        default: return .httpError(statusCode: statusCode, body: message)
        }
    }

    /// Pull the model name out of Ollama's not-found sentence.
    ///
    /// `ArbiterError.modelNotFound` renders as `Model '<name>' not found`, so
    /// handing it the whole of `model "llama9" not found, try pulling it first`
    /// would read as a sentence quoted inside a sentence. Returns `nil` when the
    /// text is not that shape, and the caller falls back to the full message.
    static func modelName(in message: String) -> String? {
        guard let opening = message.firstIndex(of: "\""),
              case let afterOpening = message.index(after: opening),
              let closing = message[afterOpening...].firstIndex(of: "\"") else {
            return nil
        }
        let name = String(message[afterOpening..<closing])
        return name.isEmpty ? nil : name
    }

    /// Ollama reports failures as `{"error": "..."}`; anything else is passed
    /// through as text, capped so a stray HTML page cannot fill a log line.
    static func extractErrorMessage(from body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = json["error"] as? String {
            return message
        }
        let text = String(data: body, encoding: .utf8) ?? ""
        return text.isEmpty ? "Unknown error" : String(text.prefix(500))
    }
}

private extension OllamaProvider {
    func performStream(
        for request: AIRequest,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        let chatURL = baseURL.appendingPathComponent("api/chat")
        var urlRequest = URLRequest(url: chatURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try mapper.buildChatBody(request, stream: true)

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArbiterError.providerUnavailable(.ollama, reason: "Stream request failed")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            // The error text is in the body, and on a stream the body is the
            // byte sequence — draining it is what tells a missing model from a
            // server that is merely unhappy.
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count >= Self.maxErrorBodyBytes { break }
            }
            throw Self.mapHTTPError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        // Ollama uses NDJSON: each line is a complete JSON object
        var state = OllamaStreamState()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            if let chunk = mapper.parseStreamLine(trimmedLine, state: &state) {
                continuation.yield(chunk)
            }
        }
    }

    func validateHTTPResponse(_ response: HTTPURLResponse, body: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            throw Self.mapHTTPError(statusCode: response.statusCode, body: body)
        }
    }
}
