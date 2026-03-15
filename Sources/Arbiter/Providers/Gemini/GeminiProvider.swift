// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "GeminiProvider")

/// Google Gemini API provider
public struct GeminiProvider: AIProvider, Sendable {
    public let id: ProviderID = .gemini

    private static let defaultBaseURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "generativelanguage.googleapis.com"
        return components.url ?? URL(filePath: "/")
    }()

    private let apiKey: String
    private let baseURL: URL
    private let defaultModel: GeminiModel
    private let mapper: GeminiMapper
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
        get async { !apiKey.isEmpty }
    }

    /// Create from Keychain
    public init(
        keyStorage provider: ProviderID = .gemini,
        defaultModel: GeminiModel = .flash25
    ) throws {
        let key = try SecureKeyStorage.retrieve(forProvider: provider)
        self.init(resolvedKey: key, baseURL: nil, defaultModel: defaultModel)
    }

    /// Create with a raw API key string
    @available(*, deprecated, message: "Use init(keyStorage:) with SecureKeyStorage for production apps")
    public init(
        apiKey: String,
        baseURL: URL? = nil,
        defaultModel: GeminiModel = .flash25
    ) {
        self.init(resolvedKey: apiKey, baseURL: baseURL, defaultModel: defaultModel)
    }

    private init(resolvedKey: String, baseURL: URL?, defaultModel: GeminiModel) {
        self.apiKey = resolvedKey
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.defaultModel = defaultModel
        self.mapper = GeminiMapper(defaultModel: defaultModel)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        try Task.checkCancellation()

        let modelName = request.model ?? defaultModel.rawValue
        let urlRequest = try buildURLRequest(modelName: modelName, stream: false, body: mapper.buildRequestBody(request))

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
            logger.error("Gemini request failed: \(urlError.localizedDescription)")
            throw ArbiterError.networkError(underlying: urlError)
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
}

private extension GeminiProvider {
    func performStream(
        for request: AIRequest,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        let modelName = request.model ?? defaultModel.rawValue
        let body = try mapper.buildRequestBody(request)
        let urlRequest = try buildURLRequest(modelName: modelName, stream: true, body: body)

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArbiterError.networkError(underlying: URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw mapHTTPError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            guard trimmedLine.hasPrefix("data: ") else { continue }
            let eventData = String(trimmedLine.dropFirst(6))

            if let chunk = mapper.parseStreamEvent(eventData, accumulated: &accumulated) {
                continuation.yield(chunk)
            }
        }
    }

    func buildURLRequest(modelName: String, stream: Bool, body: Data) throws -> URLRequest {
        let action = stream ? "streamGenerateContent" : "generateContent"
        let safeName = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelName
        let path = "/v1/models/\(safeName):\(action)"

        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.path = path

        if stream {
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        }

        guard let requestURL = components.url else {
            throw ArbiterError.invalidRequest(reason: "Failed to build Gemini URL for model: \(modelName)")
        }

        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = body
        return urlRequest
    }

    func validateHTTPResponse(_ response: HTTPURLResponse, body: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let bodyString = String(data: body, encoding: .utf8) ?? ""
            throw mapHTTPError(statusCode: response.statusCode, body: bodyString)
        }
    }

    func mapHTTPError(statusCode: Int, body: String) -> ArbiterError {
        logger.warning("HTTP error \(statusCode) from Gemini API")
        switch statusCode {
        case 401, 403: return .authenticationFailed(.gemini)
        case 429: return .rateLimited(.gemini, retryAfter: nil)
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
        let pattern = #"key=[^\s&\"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "key=[REDACTED]")
    }
}
