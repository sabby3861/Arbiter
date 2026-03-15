// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "AnthropicProvider")

/// Anthropic Claude API provider
public struct AnthropicProvider: AIProvider, Sendable {
    public let id: ProviderID = .anthropic

    private static let defaultBaseURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.anthropic.com"
        return components.url ?? URL(filePath: "/")
    }()
    private let apiKey: String
    private let baseURL: URL
    private let defaultModel: AnthropicModel
    private let mapper: AnthropicMapper
    private let session: URLSession

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .completion, .codeGeneration, .summarization,
                             .translation, .structuredOutput, .imageUnderstanding],
            maxContextTokens: defaultModel.contextWindow,
            supportsStreaming: true,
            supportsToolCalling: true,
            supportsImageInput: true,
            costPerMillionInputTokens: defaultModel.costPerMillionInput,
            costPerMillionOutputTokens: defaultModel.costPerMillionOutput,
            estimatedLatency: .moderate,
            privacyLevel: .thirdPartyCloud
        )
    }

    public var isAvailable: Bool {
        get async {
            !apiKey.isEmpty
        }
    }

    /// Create an Anthropic provider with an API key retrieved from secure storage.
    ///
    /// This is the recommended initializer for production apps.
    /// - Parameters:
    ///   - provider: The provider ID to retrieve the key for (defaults to `.anthropic`)
    ///   - baseURL: Custom base URL (defaults to Anthropic's API)
    ///   - defaultModel: Model to use when none is specified in requests
    public init(
        keyStorage provider: ProviderID = .anthropic,
        baseURL: URL? = nil,
        defaultModel: AnthropicModel = .claude4Sonnet
    ) throws {
        let key = try SecureKeyStorage.retrieve(forProvider: provider)
        self.init(resolvedKey: key, baseURL: baseURL, defaultModel: defaultModel)
    }

    /// Create an Anthropic provider with a raw API key string.
    ///
    /// Prefer `init(keyStorage:)` with `SecureKeyStorage` for production apps.
    /// - Parameters:
    ///   - apiKey: Your Anthropic API key
    ///   - baseURL: Custom base URL (defaults to Anthropic's API)
    ///   - defaultModel: Model to use when none is specified in requests
    @available(*, deprecated, message: "Use init(keyStorage:) with SecureKeyStorage for production apps")
    public init(
        apiKey: String,
        baseURL: URL? = nil,
        defaultModel: AnthropicModel = .claude4Sonnet
    ) {
        self.init(resolvedKey: apiKey, baseURL: baseURL, defaultModel: defaultModel)
    }

    private init(
        resolvedKey: String,
        baseURL: URL?,
        defaultModel: AnthropicModel
    ) {
        self.apiKey = resolvedKey
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.defaultModel = defaultModel
        self.mapper = AnthropicMapper(defaultModel: defaultModel)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        try Task.checkCancellation()
        let urlRequest = try buildURLRequest(for: request, stream: false)

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
            logger.error("Network request failed: \(urlError.localizedDescription)")
            throw ArbiterError.networkError(underlying: urlError)
        } catch {
            logger.error("Network request failed: \(error.localizedDescription)")
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
}

private extension AnthropicProvider {
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
            var body = ""
            for try await line in bytes.lines { body += line }
            throw mapHTTPError(statusCode: httpResponse.statusCode, body: body)
        }

        try await parseSSEStream(bytes: bytes, continuation: continuation)
    }

    func parseSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        var accumulated = ""
        var streamInputTokens: Int?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            guard trimmedLine.hasPrefix("data: ") else { continue }
            let eventData = String(trimmedLine.dropFirst(6))

            if let chunk = mapper.parseStreamEvent(
                eventData, accumulated: &accumulated,
                streamInputTokens: &streamInputTokens
            ) {
                continuation.yield(chunk)
            }
        }
    }

    func buildURLRequest(for request: AIRequest, stream: Bool) throws -> URLRequest {
        let messagesURL = baseURL.appendingPathComponent("v1/messages")
        var urlRequest = URLRequest(url: messagesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        if stream {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        urlRequest.httpBody = try mapper.buildRequestBody(request, stream: stream)
        return urlRequest
    }

    func validateHTTPResponse(_ response: HTTPURLResponse, body: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let bodyString = String(data: body, encoding: .utf8) ?? ""
            throw mapHTTPError(statusCode: response.statusCode, body: bodyString)
        }
    }

    func mapHTTPError(statusCode: Int, body: String) -> ArbiterError {
        logger.warning("HTTP error \(statusCode) from Anthropic API")

        switch statusCode {
        case 401:
            return .authenticationFailed(.anthropic)
        case 429:
            return .rateLimited(.anthropic, retryAfter: nil)
        case 400:
            return .invalidRequest(reason: extractErrorMessage(from: body))
        case 404:
            return .modelNotFound(extractErrorMessage(from: body))
        default:
            return .httpError(statusCode: statusCode, body: redactSensitiveContent(body))
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

    func redactSensitiveContent(_ text: String) -> String {
        // Redact anything that looks like an API key
        let apiKeyPattern = #"(sk-ant-|x-api-key["\s:]+)[^\s"',}]+"#
        guard let regex = try? NSRegularExpression(pattern: apiKeyPattern, options: .caseInsensitive) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1[REDACTED]")
    }
}
