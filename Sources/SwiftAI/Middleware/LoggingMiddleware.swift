// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

/// Structured logging middleware with automatic redaction of sensitive data.
///
/// API keys, bearer tokens, and other credentials are automatically redacted
/// in all log output. Prompt text redaction is opt-in for privacy-sensitive apps.
///
/// ```swift
/// let logging = LoggingMiddleware(logLevel: .standard, redactPrompts: true)
/// ```
public struct LoggingMiddleware: AIMiddleware, Sendable {
    public var logLevel: LogLevel
    public var redactKeys: Bool
    public var redactPrompts: Bool
    public var destination: LogDestination

    private let logger: Logger

    public init(
        logLevel: LogLevel = .standard,
        redactKeys: Bool = true,
        redactPrompts: Bool = false,
        destination: LogDestination = .osLog
    ) {
        self.logLevel = logLevel
        self.redactKeys = redactKeys
        self.redactPrompts = redactPrompts
        self.destination = destination
        self.logger = Logger(subsystem: "com.swiftai", category: "Middleware")
    }

    public func process(_ request: AIRequest) async throws -> AIRequest {
        guard logLevel != .none else { return request }

        let messageCount = request.messages.count
        let model = request.model ?? "default"

        switch logLevel {
        case .none:
            break
        case .minimal:
            log("Request: \(messageCount) message(s), model: \(model)")
        case .standard:
            let tags = request.tags.isEmpty ? "none" : request.tags.map(\.rawValue).joined(separator: ", ")
            log("Request: \(messageCount) message(s), model: \(model), tags: \(tags)")
        case .verbose:
            let promptSummary = redactPrompts
                ? promptRedacted(request)
                : promptPreview(request)
            log("Request: \(messageCount) message(s), model: \(model)\n\(promptSummary)")
        }

        return request
    }

    public func process(_ response: AIResponse) async throws -> AIResponse {
        guard logLevel != .none else { return response }

        switch logLevel {
        case .none:
            break
        case .minimal:
            log("Response: \(response.provider.rawValue)")
        case .standard:
            let tokens = response.usage.map { "\($0.totalTokens) tokens" } ?? "unknown tokens"
            log("Response: \(response.provider.rawValue), \(tokens), reason: \(response.finishReason?.rawValue ?? "unknown")")
        case .verbose:
            let tokens = response.usage.map { "in:\($0.inputTokens) out:\($0.outputTokens)" } ?? "unknown"
            let contentPreview = redactPrompts
                ? "[REDACTED: \(response.content.count) chars]"
                : String(response.content.prefix(200))
            log("Response: \(response.provider.rawValue), model: \(response.model), \(tokens)\nContent: \(contentPreview)")
        }

        return response
    }

    /// Redact known sensitive patterns from a string
    private static let redactLogger = Logger(subsystem: "com.swiftai", category: "Redaction")

    public static func redact(_ text: String) -> String {
        var result = text

        let patterns: [(pattern: String, replacement: String)] = [
            (#"sk-ant-api\w{2}-[\w-]+"#, "sk-ant-***REDACTED***"),
            (#"sk-[a-zA-Z0-9]{32,}"#, "sk-***REDACTED***"),
            (#"Bearer\s+eyJ[a-zA-Z0-9._-]+"#, "Bearer ***REDACTED***"),
            (#"(?i)(api[_-]?key|token|secret|password|authorization)\s*[:=]\s*"?[\w./+=-]+"?"#,
             "$1: ***REDACTED***"),
        ]

        for (pattern, replacement) in patterns {
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern)
            } catch {
                redactLogger.error("Invalid redaction pattern: \(error.localizedDescription)")
                continue
            }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }

        return result
    }
}

private extension LoggingMiddleware {
    func log(_ message: String) {
        let sanitized = redactKeys ? Self.redact(message) : message

        switch destination {
        case .osLog:
            logger.info("\(sanitized, privacy: .public)")
        case .custom(let handler):
            handler(sanitized)
        }
    }

    func promptPreview(_ request: AIRequest) -> String {
        request.messages.map { msg in
            let text = msg.content.text ?? "[non-text content]"
            return "[\(msg.role.rawValue)] \(String(text.prefix(100)))"
        }.joined(separator: "\n")
    }

    func promptRedacted(_ request: AIRequest) -> String {
        request.messages.map { msg in
            let length = msg.content.text?.count ?? 0
            return "[\(msg.role.rawValue)] [REDACTED: \(length) chars]"
        }.joined(separator: "\n")
    }
}

/// Controls how much detail is logged
public enum LogLevel: String, Sendable {
    case none
    case minimal
    case standard
    case verbose
}

/// Where log output is sent
public enum LogDestination: Sendable {
    case osLog
    case custom(@Sendable (String) -> Void)
}
