// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "OllamaProvider")

/// Ollama local server provider.
///
/// Connects to a locally-running Ollama instance. No API key required.
/// ```swift
/// let ai = SwiftAI {
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
            supportedTasks: [.chat, .completion, .codeGeneration, .summarization, .translation],
            maxContextTokens: 128_000,
            supportsStreaming: true,
            supportsToolCalling: false,
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
                throw SwiftAIError.networkError(underlying: URLError(.badServerResponse))
            }
            responseData = data
            httpResponse = http
        } catch let error as SwiftAIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            logger.error("Ollama request failed: \(urlError.localizedDescription)")
            throw SwiftAIError.providerUnavailable(.ollama, reason: "Server not reachable")
        } catch {
            throw SwiftAIError.networkError(underlying: URLError(.unknown))
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

    /// List models installed on the Ollama server
    public func listModels() async throws -> [String] {
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: URLRequest(url: tagsURL))
        } catch let urlError as URLError {
            throw SwiftAIError.providerUnavailable(.ollama, reason: "Server not reachable: \(urlError.localizedDescription)")
        } catch {
            throw SwiftAIError.networkError(underlying: URLError(.unknown))
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SwiftAIError.providerUnavailable(.ollama, reason: "Failed to list models")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }

        return models.compactMap { $0["name"] as? String }
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
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SwiftAIError.providerUnavailable(.ollama, reason: "Stream request failed")
        }

        // Ollama uses NDJSON: each line is a complete JSON object
        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            if let chunk = mapper.parseStreamLine(trimmedLine, accumulated: &accumulated) {
                continuation.yield(chunk)
            }
        }
    }

    func validateHTTPResponse(_ response: HTTPURLResponse, body: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let bodyString = String(data: body, encoding: .utf8) ?? ""
            logger.warning("Ollama HTTP error \(response.statusCode)")
            throw SwiftAIError.httpError(statusCode: response.statusCode, body: bodyString)
        }
    }
}
