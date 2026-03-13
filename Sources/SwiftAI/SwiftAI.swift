// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "SwiftAI")

/// The main entry point for SwiftAI — a unified runtime for multiple AI providers.
///
/// Quick start with a single provider:
/// ```swift
/// let ai = SwiftAI(provider: AnthropicProvider(apiKey: key))
/// let response = try await ai.generate("Hello!")
/// ```
///
/// Multi-provider setup:
/// ```swift
/// let ai = SwiftAI {
///     $0.cloud(AnthropicProvider(apiKey: key))
///     $0.routing(.firstAvailable)
/// }
/// ```
public final class SwiftAI: Sendable {
    private let providers: [any AIProvider]
    private let routingPolicy: RoutingPolicy
    private let spendingGuard: SpendingGuard?

    /// Create SwiftAI with a single provider
    /// - Parameter provider: The AI provider to use
    public init(provider: any AIProvider) {
        self.providers = [provider]
        self.routingPolicy = .firstAvailable
        self.spendingGuard = nil
    }

    /// Create SwiftAI with full configuration
    /// - Parameter configure: A closure to configure providers, routing, and spending limits
    public init(_ configure: (inout Configuration) -> Void) {
        var config = Configuration()
        configure(&config)
        self.providers = config.providers
        self.routingPolicy = config.routingPolicy
        self.spendingGuard = config.spendingGuard
    }

    /// Generate a response from a simple text prompt
    public func generate(_ prompt: String, options: RequestOptions? = nil) async throws -> AIResponse {
        try await performGenerate(messages: [.user(prompt)], options: options)
    }

    /// Stream a response from a simple text prompt
    public func stream(
        _ prompt: String,
        options: RequestOptions? = nil
    ) -> AsyncThrowingStream<AIStreamChunk, Error> {
        streamWithProviderSelection(messages: [.user(prompt)], options: options)
    }

    /// Generate a response from a conversation history
    public func chat(_ messages: [Message], options: RequestOptions? = nil) async throws -> AIResponse {
        try await performGenerate(messages: messages, options: options)
    }

    /// Stream a response from a conversation history
    public func chatStream(
        _ messages: [Message],
        options: RequestOptions? = nil
    ) -> AsyncThrowingStream<AIStreamChunk, Error> {
        streamWithProviderSelection(messages: messages, options: options)
    }
}

private extension SwiftAI {
    func performGenerate(messages: [Message], options: RequestOptions?) async throws -> AIResponse {
        try Task.checkCancellation()

        let request = buildRequest(messages: messages, options: options)
        let provider = try await selectProvider(for: request, options: options)
        let reservation = try await reserveBudget(for: provider)

        do {
            let response = try await withTaskCancellationHandler {
                try await provider.generate(request)
            } onCancel: {
                logger.debug("Generate request cancelled for provider \(provider.id.rawValue)")
            }

            if let reservation, let usage = response.usage {
                let actualCost = estimateCost(usage: usage, provider: provider)
                await spendingGuard?.finalizeReservation(reservation, actualCost: actualCost)
            }

            return response
        } catch {
            if let reservation {
                await spendingGuard?.finalizeReservation(reservation, actualCost: 0)
            }
            throw error
        }
    }

    func selectProvider(for request: AIRequest, options: RequestOptions?) async throws -> any AIProvider {
        try Task.checkCancellation()

        if let preferredID = options?.provider {
            guard let provider = providers.first(where: { $0.id == preferredID }) else {
                throw SwiftAIError.providerUnavailable(preferredID, reason: "Not configured")
            }
            guard await provider.isAvailable else {
                throw SwiftAIError.providerUnavailable(preferredID, reason: "Currently unavailable")
            }
            return provider
        }

        if options?.privacyRequired == true {
            return try await selectPrivateProvider()
        }

        return try await selectByPolicy()
    }

    func selectByPolicy() async throws -> any AIProvider {
        switch routingPolicy {
        case .firstAvailable:
            return try await firstAvailableProvider(from: providers)

        case .preferLocal:
            let localProviders = providers.filter { $0.id.tier == .onDevice || $0.id.tier == .localServer }
            if let local = try? await firstAvailableProvider(from: localProviders) {
                return local
            }
            return try await firstAvailableProvider(from: providers)

        case .preferCloud:
            let cloudProviders = providers.filter { $0.id.tier == .cloud }
            if let cloud = try? await firstAvailableProvider(from: cloudProviders) {
                return cloud
            }
            return try await firstAvailableProvider(from: providers)

        case .specific(let providerID):
            guard let provider = providers.first(where: { $0.id == providerID }) else {
                throw SwiftAIError.providerUnavailable(providerID, reason: "Not configured")
            }
            return provider
        }
    }

    func selectPrivateProvider() async throws -> any AIProvider {
        let privateProviders = providers.filter {
            $0.capabilities.privacyLevel != .thirdPartyCloud
        }
        guard !privateProviders.isEmpty else {
            throw SwiftAIError.invalidRequest(
                reason: "Privacy required but no on-device or private cloud providers configured"
            )
        }
        return try await firstAvailableProvider(from: privateProviders)
    }

    /// Check all candidate providers concurrently and return the first one that's available.
    func firstAvailableProvider(from candidates: [any AIProvider]) async throws -> any AIProvider {
        guard !candidates.isEmpty else {
            throw SwiftAIError.allProvidersFailed(attempts: [])
        }

        // Single provider — skip TaskGroup overhead
        if candidates.count == 1 {
            let provider = candidates[0]
            guard await provider.isAvailable else {
                throw SwiftAIError.providerUnavailable(provider.id, reason: "Not available")
            }
            return provider
        }

        // Multiple providers — check availability concurrently
        return try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            for (index, provider) in candidates.enumerated() {
                group.addTask {
                    let available = await provider.isAvailable
                    return (index, available)
                }
            }

            // Collect results and pick the first available in original order
            var availability = [Int: Bool]()
            for try await (index, isAvailable) in group {
                availability[index] = isAvailable
            }

            for (index, provider) in candidates.enumerated() {
                if availability[index] == true {
                    return provider
                }
            }

            let attempts: [(ProviderID, any Error & Sendable)] = candidates.map { provider in
                (provider.id, SwiftAIError.providerUnavailable(provider.id, reason: "Not available"))
            }
            throw SwiftAIError.allProvidersFailed(attempts: attempts)
        }
    }

    func buildRequest(messages: [Message], options: RequestOptions?) -> AIRequest {
        AIRequest(
            messages: messages,
            model: options?.model,
            maxTokens: options?.maxTokens,
            temperature: options?.temperature,
            systemPrompt: options?.systemPrompt,
            tools: options?.tools,
            responseFormat: options?.responseFormat
        )
    }

    func reserveBudget(for provider: any AIProvider) async throws -> SpendingGuard.Reservation? {
        guard let spendingGuard, provider.id.tier == .cloud else { return nil }

        let estimatedCost = (provider.capabilities.costPerMillionInputTokens ?? 0) / 1_000_000 * 1000
        return try await spendingGuard.reserveBudget(estimatedCost: estimatedCost)
    }

    func estimateCost(usage: TokenUsage, provider: any AIProvider) -> Double {
        let inputCost = (provider.capabilities.costPerMillionInputTokens ?? 0)
            / 1_000_000 * Double(usage.inputTokens)
        let outputCost = (provider.capabilities.costPerMillionOutputTokens ?? 0)
            / 1_000_000 * Double(usage.outputTokens)
        return inputCost + outputCost
    }

    func streamWithProviderSelection(
        messages: [Message],
        options: RequestOptions?
    ) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = self.buildRequest(messages: messages, options: options)
                    let provider = try await self.selectProvider(for: request, options: options)
                    let reservation = try await self.reserveBudget(for: provider)

                    let stream = provider.stream(request)
                    var lastUsage: TokenUsage?

                    for try await chunk in stream {
                        try Task.checkCancellation()
                        if let usage = chunk.usage { lastUsage = usage }
                        continuation.yield(chunk)
                    }

                    if let reservation, let usage = lastUsage {
                        let actualCost = self.estimateCost(usage: usage, provider: provider)
                        await self.spendingGuard?.finalizeReservation(reservation, actualCost: actualCost)
                    } else if let reservation {
                        await self.spendingGuard?.finalizeReservation(reservation, actualCost: 0)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// Configuration options for individual requests
public struct RequestOptions: Sendable {
    public var model: String?
    public var maxTokens: Int?
    public var temperature: Double?
    public var systemPrompt: String?
    public var tools: [ToolDefinition]?
    public var responseFormat: ResponseFormat?
    public var provider: ProviderID?
    public var privacyRequired: Bool

    public init(
        model: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        systemPrompt: String? = nil,
        tools: [ToolDefinition]? = nil,
        responseFormat: ResponseFormat? = nil,
        provider: ProviderID? = nil,
        privacyRequired: Bool = false
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.responseFormat = responseFormat
        self.provider = provider
        self.privacyRequired = privacyRequired
    }
}

/// How to select which provider handles a request
public enum RoutingPolicy: Sendable {
    case firstAvailable
    case preferLocal
    case preferCloud
    case specific(ProviderID)
}

/// Configuration for setting up SwiftAI with multiple providers
public struct Configuration: Sendable {
    var providers: [any AIProvider] = []
    var routingPolicy: RoutingPolicy = .firstAvailable
    var spendingGuard: SpendingGuard?

    /// Add a cloud provider (e.g., Anthropic, OpenAI)
    public mutating func cloud(_ provider: any AIProvider) {
        providers.append(provider)
    }

    /// Add a local server provider (e.g., Ollama)
    public mutating func local(_ provider: any AIProvider) {
        providers.append(provider)
    }

    /// Add a system-level provider (e.g., Apple Foundation Models)
    public mutating func system(_ provider: any AIProvider) {
        providers.append(provider)
    }

    /// Set the routing policy for provider selection
    public mutating func routing(_ policy: RoutingPolicy) {
        routingPolicy = policy
    }

    /// Set a spending limit in USD
    public mutating func spendingLimit(_ amount: Double) {
        spendingGuard = SpendingGuard(budgetLimit: amount)
    }
}
