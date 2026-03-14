// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "SwiftAI")

/// The main entry point for SwiftAI — a unified runtime for multiple AI providers.
///
/// Quick start with Keychain-stored key (recommended):
/// ```swift
/// let ai = try SwiftAI {
///     try $0.cloud(.anthropic(from: .keychain))
/// }
/// let response = try await ai.generate("Hello!")
/// ```
///
/// Multi-provider with smart routing:
/// ```swift
/// let ai = try SwiftAI {
///     try $0.cloud(.anthropic(from: .keychain))
///     $0.local(OllamaProvider())
///     $0.routing(.smart)
///     $0.spendingLimit(5.00)
///     $0.privacy(.strict)
/// }
/// ```
public final class SwiftAI: Sendable {
    private let providers: [any AIProvider]
    private let routingPolicy: RoutingPolicy
    private let spendingGuard: SpendingGuard?
    private let router: SmartRouter
    private let costTracker: CostTracker

    /// Create SwiftAI with a single provider
    public init(provider: any AIProvider) {
        self.providers = [provider]
        self.routingPolicy = .firstAvailable
        self.spendingGuard = nil
        self.router = SmartRouter()
        self.costTracker = CostTracker()
    }

    /// Create SwiftAI with full configuration (non-throwing)
    public init(_ configure: (inout Configuration) -> Void) {
        var config = Configuration()
        configure(&config)
        self.providers = config.providers
        self.routingPolicy = config.routingPolicy
        self.spendingGuard = config.spendingGuard
        self.router = SmartRouter(privacyGuard: config.privacyGuard)
        self.costTracker = CostTracker()
    }

    /// Create SwiftAI with full configuration (throwing, for Keychain-based providers)
    public init(_ configure: (inout Configuration) throws -> Void) throws {
        var config = Configuration()
        try configure(&config)
        self.providers = config.providers
        self.routingPolicy = config.routingPolicy
        self.spendingGuard = config.spendingGuard
        self.router = SmartRouter(privacyGuard: config.privacyGuard)
        self.costTracker = CostTracker()
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

        guard !providers.isEmpty else {
            throw SwiftAIError.invalidRequest(reason: "No providers configured. Add at least one provider via cloud(), local(), or system().")
        }

        let request = buildRequest(messages: messages, options: options)
        let decision = await routeRequest(request, options: options)

        guard decision.isAvailable else {
            throw SwiftAIError.allProvidersFailed(attempts: [])
        }

        let providerOrder = buildProviderOrder(from: decision)
        var attempts: [(ProviderID, any Error & Sendable)] = []
        let maxAttempts = routingPolicy.fallbackEnabled ? routingPolicy.maxRetries + 1 : 1

        for providerID in providerOrder.prefix(maxAttempts) {
            guard let provider = providers.first(where: { $0.id == providerID }) else { continue }
            do {
                return try await executeGenerate(request: request, provider: provider)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempts.append((providerID, error))
                logger.debug("Provider \(providerID.rawValue) failed, trying next")
            }
        }

        throw SwiftAIError.allProvidersFailed(attempts: attempts)
    }

    func executeGenerate(request: AIRequest, provider: any AIProvider) async throws -> AIResponse {
        let reservation = try await reserveBudget(for: provider)
        do {
            let response = try await withTaskCancellationHandler {
                try await provider.generate(request)
            } onCancel: {
                logger.debug("Generate cancelled for \(provider.id.rawValue)")
            }
            await finalizeCost(reservation: reservation, usage: response.usage, provider: provider)
            return response
        } catch {
            if let reservation {
                await spendingGuard?.finalizeReservation(reservation, actualCost: 0)
            }
            throw error
        }
    }

    func routeRequest(_ request: AIRequest, options: RequestOptions?) async -> RoutingDecision {
        if let preferredID = options?.provider {
            return RoutingDecision(
                selectedProvider: preferredID,
                reason: "Explicit provider selection",
                factors: []
            )
        }

        var policy = routingPolicy
        if options?.privacyRequired == true {
            policy.forceLocal = true
        }

        let budget = await spendingGuard?.remainingBudget
        return await router.route(
            request, policy: policy,
            providers: providers, budgetRemaining: budget
        )
    }

    func buildProviderOrder(from decision: RoutingDecision) -> [ProviderID] {
        guard let selected = decision.selectedProvider else { return [] }
        var order = [selected]
        if routingPolicy.fallbackEnabled {
            order.append(contentsOf: decision.alternativeProviders)
        }
        return order
    }

    func buildRequest(messages: [Message], options: RequestOptions?) -> AIRequest {
        var request = AIRequest(
            messages: messages,
            model: options?.model,
            maxTokens: options?.maxTokens,
            temperature: options?.temperature,
            systemPrompt: options?.systemPrompt,
            tools: options?.tools,
            responseFormat: options?.responseFormat,
            tags: options?.tags ?? []
        )
        if let maxTokens = spendingGuard?.effectiveMaxTokens, request.maxTokens == nil {
            request.maxTokens = maxTokens
        }
        return request
    }

    func reserveBudget(for provider: any AIProvider) async throws -> SpendingGuard.Reservation? {
        guard let spendingGuard, provider.id.tier == .cloud else { return nil }
        let estimatedCost = (provider.capabilities.costPerMillionInputTokens ?? 0) / 1_000_000 * 1000
        return try await spendingGuard.reserveBudget(estimatedCost: estimatedCost)
    }

    func finalizeCost(
        reservation: SpendingGuard.Reservation?,
        usage: TokenUsage?,
        provider: any AIProvider
    ) async {
        if let reservation, let usage {
            let actualCost = estimateCost(usage: usage, provider: provider)
            await spendingGuard?.finalizeReservation(reservation, actualCost: actualCost)
            await costTracker.recordUsage(provider: provider.id, usage: usage, cost: actualCost)
        } else if let reservation {
            await spendingGuard?.finalizeReservation(reservation, actualCost: 0)
        }
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
                    try await self.performStreamRouting(
                        messages: messages, options: options, continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func performStreamRouting(
        messages: [Message],
        options: RequestOptions?,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        guard !providers.isEmpty else {
            throw SwiftAIError.invalidRequest(
                reason: "No providers configured. Add at least one provider via cloud(), local(), or system().")
        }

        let request = buildRequest(messages: messages, options: options)
        let decision = await routeRequest(request, options: options)

        guard decision.isAvailable else {
            throw SwiftAIError.allProvidersFailed(attempts: [])
        }

        let providerOrder = buildProviderOrder(from: decision)
        let maxAttempts = routingPolicy.fallbackEnabled ? routingPolicy.maxRetries + 1 : 1
        var lastError: (any Error)?

        for providerID in providerOrder.prefix(maxAttempts) {
            guard let provider = providers.first(where: { $0.id == providerID }) else { continue }
            do {
                try await executeStream(
                    request: request, provider: provider, continuation: continuation
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                logger.debug("Stream provider \(providerID.rawValue) failed, trying next")
            }
        }

        throw lastError ?? SwiftAIError.allProvidersFailed(attempts: [])
    }

    func executeStream(
        request: AIRequest,
        provider: any AIProvider,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        let reservation = try await reserveBudget(for: provider)
        let stream = provider.stream(request)
        var lastUsage: TokenUsage?

        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                if let usage = chunk.usage { lastUsage = usage }
                continuation.yield(chunk)
            }
        } catch {
            if let reservation {
                await spendingGuard?.finalizeReservation(reservation, actualCost: 0)
            }
            throw error
        }

        await finalizeCost(reservation: reservation, usage: lastUsage, provider: provider)
        continuation.finish()
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
    public var tags: Set<RequestTag>

    public init(
        model: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        systemPrompt: String? = nil,
        tools: [ToolDefinition]? = nil,
        responseFormat: ResponseFormat? = nil,
        provider: ProviderID? = nil,
        privacyRequired: Bool = false,
        tags: Set<RequestTag> = []
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.responseFormat = responseFormat
        self.provider = provider
        self.privacyRequired = privacyRequired
        self.tags = tags
    }
}

/// Configuration for setting up SwiftAI with multiple providers
public struct Configuration: Sendable {
    var providers: [any AIProvider] = []
    var routingPolicy: RoutingPolicy = .firstAvailable
    var spendingGuard: SpendingGuard?
    var privacyGuard: PrivacyGuard?

    /// Add a cloud provider (e.g., Anthropic, OpenAI)
    public mutating func cloud(_ provider: any AIProvider) {
        providers.append(provider)
    }

    /// Add a cloud provider from a factory (supports Keychain retrieval)
    public mutating func cloud(_ factory: ProviderFactory) throws {
        providers.append(try factory.createProvider())
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
    public mutating func spendingLimit(_ amount: Double, action: LimitAction = .block) {
        spendingGuard = SpendingGuard(budgetLimit: amount, limitAction: action)
    }

    /// Set privacy enforcement level
    public mutating func privacy(_ guard: PrivacyGuard) {
        privacyGuard = `guard`
    }
}
