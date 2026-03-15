// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Errors that can occur when using Arbiter
public enum ArbiterError: Error, Sendable {
    case providerUnavailable(ProviderID, reason: String)
    case authenticationFailed(ProviderID)
    case rateLimited(ProviderID, retryAfter: Duration?)
    case networkError(underlying: any Error & Sendable)
    case timeout(ProviderID, duration: Duration)
    case modelNotFound(String)
    case invalidRequest(reason: String)
    case contentFiltered(reason: String)
    case allProvidersFailed(attempts: [(ProviderID, any Error & Sendable)])
    case budgetExceeded(spent: Double, limit: Double)
    case dailyLimitExceeded(count: Int, limit: Int)
    case deviceNotCapable(reason: String)
    case decodingFailed(context: String)
    case httpError(statusCode: Int, body: String)
    case keychainError(status: Int32)
}

extension ArbiterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .providerUnavailable(let provider, let reason):
            "\(provider.displayName) is unavailable: \(reason)"
        case .authenticationFailed(let provider):
            "Authentication failed for \(provider.displayName)"
        case .rateLimited(let provider, let retryAfter):
            if let retryAfter {
                "\(provider.displayName) rate limited. Retry after \(retryAfter)"
            } else {
                "\(provider.displayName) rate limited"
            }
        case .networkError(let underlying):
            "Network error: \(underlying.localizedDescription)"
        case .timeout(let provider, let duration):
            "\(provider.displayName) request timed out after \(duration)"
        case .modelNotFound(let model):
            "Model '\(model)' not found"
        case .invalidRequest(let reason):
            "Invalid request: \(reason)"
        case .contentFiltered(let reason):
            "Content filtered: \(reason)"
        case .allProvidersFailed(let attempts):
            "All \(attempts.count) provider(s) failed"
        case .budgetExceeded(let spent, let limit):
            "Budget exceeded: spent $\(String(format: "%.4f", spent)) of $\(String(format: "%.4f", limit)) limit"
        case .dailyLimitExceeded(let count, let limit):
            "Daily request limit exceeded: \(count) of \(limit) requests used"
        case .deviceNotCapable(let reason):
            "Device not capable: \(reason)"
        case .decodingFailed(let context):
            "Failed to decode response: \(context)"
        case .httpError(let statusCode, _):
            "HTTP error \(statusCode)"
        case .keychainError(let status):
            "Keychain error: \(status)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .providerUnavailable:
            "Check your network connection or try a different provider."
        case .authenticationFailed:
            "Verify your API key is correct and has not expired."
        case .rateLimited(_, let retryAfter):
            if let retryAfter {
                "Wait \(retryAfter) before retrying."
            } else {
                "Wait a moment before retrying."
            }
        case .networkError:
            "Check your internet connection and try again."
        case .timeout:
            "Try again or use a provider with lower latency."
        case .modelNotFound:
            "Check the model name and ensure it is available for your provider."
        case .invalidRequest:
            "Review your request parameters."
        case .contentFiltered:
            "Modify your prompt to comply with content policies."
        case .allProvidersFailed:
            "Check provider configurations and network connectivity."
        case .budgetExceeded:
            "Increase your spending limit or switch to a free/local provider."
        case .dailyLimitExceeded:
            "Wait until tomorrow or increase your daily request limit."
        case .deviceNotCapable:
            "Use a cloud provider instead, or upgrade your device."
        case .decodingFailed:
            "This may indicate an API change. Update Arbiter to the latest version."
        case .httpError:
            "Check the API documentation for this status code."
        case .keychainError:
            "Check Keychain access permissions for your app."
        }
    }
}
