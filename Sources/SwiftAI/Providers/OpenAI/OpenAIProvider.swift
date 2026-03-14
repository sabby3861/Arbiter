// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "OpenAIProvider")

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
    private let session: URLSession

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .completion, .codeGeneration, .summarization,
                             .translation, .structuredOutput, .imageUnderstanding],
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

    private init(resolvedKey: String, baseURL: URL?, organization: String?, defaultModel: OpenAIModel) {
        self.apiKey = resolvedKey
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.organization = organization
        self.defaultModel = defaultModel
        self.mapper = OpenAIMapper(defaultModel: defaultModel)

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
                throw SwiftAIError.networkError(underlying: URLError(.badServerResponse))
            }
            responseData = data
            httpResponse = http
        } catch let error as SwiftAIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            logger.error("Network request failed: \(urlError.localizedDescription)")
            throw SwiftAIError.networkError(underlying: urlError)
        } catch {
            throw SwiftAIError.networkError(underlying: URLError(.unknown))
        }

        try validateHTTPResponse(httpResponse, body: responseData)
        return try mapper.parseResponse(responseData)
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        // Some models (o1, o1-mini, o3-mini) don't support streaming.
        // Fall back to generate() wrapped as a single-chunk stream.
        guard defaultModel.supportsStreaming else {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let response = try await self.generate(request)
                        continuation.yield(AIStreamChunk(
                            delta: response.content,
                            accumulatedContent: response.content,
                            isComplete: true,
                            usage: response.usage,
                            finishReason: response.finishReason,
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

private extension OpenAIProvider {
    func performStream(
        for request: AIRequest,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        let urlRequest = try buildURLRequest(for: request, stream: true)
        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SwiftAIError.networkError(underlying: URLError(.badServerResponse))
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
        var accumulated = ""

        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data: ") else { continue }
            let eventData = String(line.dropFirst(6))

            if let chunk = mapper.parseStreamEvent(eventData, accumulated: &accumulated) {
                continuation.yield(chunk)
                if chunk.isComplete { return }
            }
        }
    }

    func buildURLRequest(for request: AIRequest, stream: Bool) throws -> URLRequest {
        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: completionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if let organization {
            urlRequest.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
        }
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

    func mapHTTPError(statusCode: Int, body: String) -> SwiftAIError {
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
