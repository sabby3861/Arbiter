// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// A unified request to any AI provider
public struct AIRequest: Sendable {
    public var messages: [Message]
    public var model: String?
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?
    public var systemPrompt: String?
    public var tools: [ToolDefinition]?
    public var responseFormat: ResponseFormat?

    public init(
        messages: [Message],
        model: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        systemPrompt: String? = nil,
        tools: [ToolDefinition]? = nil,
        responseFormat: ResponseFormat? = nil
    ) {
        self.messages = messages
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.responseFormat = responseFormat
    }

    /// Start building a chat request with a single user message
    public static func chat(_ text: String) -> AIRequest {
        AIRequest(messages: [.user(text)])
    }

    /// Add a system prompt
    public func withSystem(_ prompt: String) -> AIRequest {
        var copy = self
        copy.systemPrompt = prompt
        return copy
    }

    /// Set maximum tokens to generate
    public func withMaxTokens(_ tokens: Int) -> AIRequest {
        var copy = self
        copy.maxTokens = tokens
        return copy
    }

    /// Set the model to use
    public func withModel(_ model: String) -> AIRequest {
        var copy = self
        copy.model = model
        return copy
    }

    /// Set the sampling temperature
    public func withTemperature(_ temperature: Double) -> AIRequest {
        var copy = self
        copy.temperature = temperature
        return copy
    }

    /// Set the top-p sampling parameter
    public func withTopP(_ topP: Double) -> AIRequest {
        var copy = self
        copy.topP = topP
        return copy
    }

    /// Add tool definitions for function calling
    public func withTools(_ tools: [ToolDefinition]) -> AIRequest {
        var copy = self
        copy.tools = tools
        return copy
    }

    /// Set the desired response format
    public func withResponseFormat(_ format: ResponseFormat) -> AIRequest {
        var copy = self
        copy.responseFormat = format
        return copy
    }
}

/// The desired format for the AI response
public enum ResponseFormat: Sendable, Equatable {
    case text
    case json
    case structured(schema: String)
}
