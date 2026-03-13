// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Where to load the API key from
public enum KeySource: Sendable {
    case keychain
}

/// Factory for creating providers from secure key sources
public struct ProviderFactory: Sendable {
    private let factory: @Sendable () throws -> any AIProvider

    private init(_ factory: @escaping @Sendable () throws -> any AIProvider) {
        self.factory = factory
    }

    func createProvider() throws -> any AIProvider {
        try factory()
    }

    /// Create an Anthropic provider from secure key storage
    public static func anthropic(
        from source: KeySource,
        model: AnthropicModel = .claude4Sonnet
    ) -> ProviderFactory {
        ProviderFactory {
            try AnthropicProvider(keyStorage: .anthropic, defaultModel: model)
        }
    }

    /// Create an OpenAI provider from secure key storage
    public static func openAI(
        from source: KeySource,
        baseURL: URL? = nil,
        organization: String? = nil,
        model: OpenAIModel = .gpt4o
    ) -> ProviderFactory {
        ProviderFactory {
            try OpenAIProvider(keyStorage: .openAI, baseURL: baseURL, organization: organization, defaultModel: model)
        }
    }

    /// Create a Gemini provider from secure key storage
    public static func gemini(
        from source: KeySource,
        model: GeminiModel = .flash25
    ) -> ProviderFactory {
        ProviderFactory {
            try GeminiProvider(keyStorage: .gemini, defaultModel: model)
        }
    }

    /// Create an Ollama provider (no API key needed)
    public static func ollama(
        baseURL: URL? = nil,
        model: String = "llama3.2"
    ) -> ProviderFactory {
        ProviderFactory {
            OllamaProvider(baseURL: baseURL, defaultModel: model)
        }
    }
}
