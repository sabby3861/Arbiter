// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "AppleFoundationErrors")

/// Arbiter's mirror of `LanguageModelSession.GenerationError` and `ToolCallError`.
///
/// Classification happens at the bridge (which can see the real enum); translation to
/// `ArbiterError` happens here, so the mapping table is unit tested on any platform.
/// The payload is always a plain description string: `GenerationError.Refusal.explanation`
/// is `async throws` and *performs a generation*, so it is never awaited during error
/// handling — the refusal's `Context.debugDescription` is used instead.
enum FMErrorKind: Sendable, Equatable {
    case contextWindowExceeded(String)
    case assetsUnavailable(String)
    case guardrailViolation(String)
    case unsupportedGuide(String)
    case unsupportedLanguage(String)
    case decodingFailure(String)
    case rateLimited(String)
    case concurrentRequests(String)
    case refusal(String)
    case toolCallFailed(toolName: String, description: String)
    case unknown(String)
}

enum FMErrorMapper {
    /// - Parameter contextLimit: the model's context size, reported with an overflow so
    ///   callers can trim rather than guess. Read from `SystemLanguageModel.contextSize`.
    static func arbiterError(for kind: FMErrorKind, contextLimit: Int) -> ArbiterError {
        switch kind {
        case .contextWindowExceeded:
            return .contextWindowExceeded(.appleFoundation, limit: contextLimit)

        case .assetsUnavailable(let description):
            return .providerUnavailable(.appleFoundation, reason: description)

        case .guardrailViolation(let description):
            return .contentFiltered(reason: description)

        case .unsupportedGuide(let description):
            return .invalidRequest(reason: "Unsupported generation guide: \(description)")

        case .unsupportedLanguage(let description):
            // `locale:` is a locale identifier, and the framework reports only a debug
            // description — so it is logged rather than misreported as one.
            logger.notice("Apple FM rejected the request's language: \(description, privacy: .public)")
            return .unsupportedLanguage(.appleFoundation, locale: nil)

        case .decodingFailure(let description):
            return .decodingFailed(context: description)

        case .rateLimited:
            return .rateLimited(.appleFoundation, retryAfter: nil)

        case .concurrentRequests:
            return .busy(.appleFoundation)

        case .refusal(let explanation):
            return .refused(.appleFoundation, explanation: explanation)

        case .toolCallFailed(let toolName, let description):
            return .invalidRequest(reason: "Tool '\(toolName)' failed: \(description)")

        case .unknown(let description):
            logger.warning("Unrecognised Apple FM error: \(description, privacy: .public)")
            return .providerUnavailable(.appleFoundation, reason: description)
        }
    }
}
