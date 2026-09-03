// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "Arbiter")

/// The main entry point for Arbiter — a unified runtime for multiple AI providers.
///
/// Quick start with Keychain-stored key (recommended):
/// ```swift
/// let ai = try Arbiter {
///     try $0.cloud(.anthropic(from: .keychain))
/// }
/// let response = try await ai.generate("Hello!")
/// ```
///
/// Multi-provider with smart routing:
/// ```swift
/// let ai = try Arbiter {
///     try $0.cloud(.anthropic(from: .keychain))
///     $0.local(OllamaProvider())
///     $0.routing(.smart)
///     $0.spendingLimit(5.00)
///     $0.privacy(.strict)
/// }
/// ```
public final class Arbiter: Sendable {
    private let providers: [any AIProvider]
    private let routingPolicy: RoutingPolicy
    private let spendingGuard: SpendingGuard?
    private let router: SmartRouter
    private let costTracker: CostTracker
    private let middlewares: [any AIMiddleware]
    private let retryConfig: RetryConfiguration?
    private let responseValidator: ResponseValidator?
    private let structuredOutputHandler = StructuredOutputHandler()
    private let analyser = RequestAnalyser()
    /// Tool calls suspended awaiting a human decision, shared by every run on this instance.
    let approvals = ToolApprovalRegistry()

    /// Registered providers, exposed for UI components like `ProviderPicker`
    public var registeredProviders: [any AIProvider] { providers }

    /// The smart router, exposed for `RoutingDebugView`
    public var smartRouter: SmartRouter { router }

    /// Create Arbiter with a single provider
    public init(provider: any AIProvider) {
        self.providers = [provider]
        self.routingPolicy = .firstAvailable
        self.spendingGuard = nil
        self.router = SmartRouter()
        self.costTracker = CostTracker()
        self.middlewares = []
        self.retryConfig = nil
        self.responseValidator = nil
    }

    /// Create Arbiter with full configuration (non-throwing)
    public init(_ configure: (inout Configuration) -> Void) {
        var config = Configuration()
        configure(&config)
        self.providers = config.providers
        self.routingPolicy = config.routingPolicy
        self.spendingGuard = config.spendingGuard
        self.router = SmartRouter(
            privacyGuard: config.privacyGuard,
            healthMonitor: config.healthMonitor,
            taskClassifier: config.taskClassifier
        )
        self.costTracker = CostTracker()
        self.middlewares = config.middlewares
        self.retryConfig = config.retryConfig
        self.responseValidator = config.resolvedResponseValidator
    }

    /// Create Arbiter with full configuration (throwing, for Keychain-based providers)
    public init(_ configure: (inout Configuration) throws -> Void) throws {
        var config = Configuration()
        try configure(&config)
        self.providers = config.providers
        self.routingPolicy = config.routingPolicy
        self.spendingGuard = config.spendingGuard
        self.router = SmartRouter(
            privacyGuard: config.privacyGuard,
            healthMonitor: config.healthMonitor,
            taskClassifier: config.taskClassifier
        )
        self.costTracker = CostTracker()
        self.middlewares = config.middlewares
        self.retryConfig = config.retryConfig
        self.responseValidator = config.resolvedResponseValidator
    }

    /// Generate a response from a simple text prompt
    public func generate(_ prompt: String, options: RequestOptions? = nil) async throws -> AIResponse {
        try await performGenerate(messages: [.user(prompt)], options: options)
    }

    /// Generate a response and decode it into a typed Swift value.
    ///
    /// Providers that can constrain decoding to a schema are sent one derived from `T`;
    /// the rest are asked for JSON in the prompt, with `example` if you supply one. Either
    /// way the answer is decoded into `T`.
    public func generate<T: Codable & Sendable>(
        _ prompt: String,
        as type: T.Type,
        example: T? = nil,
        options: RequestOptions? = nil
    ) async throws -> T {
        try await generateStructured(
            messages: [.user(prompt)], as: type, example: example, options: options
        )
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

    /// Generate from messages and decode into a typed value.
    ///
    /// As ``generate(_:as:example:options:)``, keeping the conversation's history.
    public func chat<T: Codable & Sendable>(
        _ messages: [Message],
        as type: T.Type,
        example: T? = nil,
        options: RequestOptions? = nil
    ) async throws -> T {
        try await generateStructured(
            messages: messages, as: type, example: example, options: options
        )
    }

    /// Stream a response from a conversation history
    public func chatStream(
        _ messages: [Message],
        options: RequestOptions? = nil
    ) -> AsyncThrowingStream<AIStreamChunk, Error> {
        streamWithProviderSelection(messages: messages, options: options)
    }

    /// Estimate the cost of a request across all configured providers
    /// WITHOUT sending it.
    ///
    /// ```swift
    /// let estimates = await ai.estimateCost("Write a long essay about AI")
    /// for estimate in estimates {
    ///     print("\(estimate.provider): $\(estimate.estimatedCost)")
    /// }
    /// ```
    public func estimateCost(
        _ prompt: String,
        options: RequestOptions? = nil
    ) async -> [CostEstimate] {
        let request = buildRequest(messages: [.user(prompt)], options: options)
        let analysis = analyser.analyse(request, providers: providers)
        let decision = await routeRequest(request, options: options)
        let selectedProvider = decision.selectedProvider

        let availability = await withTaskGroup(
            of: (ProviderID, Bool).self
        ) { group in
            for provider in providers {
                group.addTask { (provider.id, await provider.isAvailable) }
            }
            var result: [ProviderID: Bool] = [:]
            for await (id, available) in group {
                result[id] = available
            }
            return result
        }

        return providers.map { provider in
            let inputCost = (provider.capabilities.costPerMillionInputTokens ?? 0)
                / 1_000_000 * Double(analysis.estimatedInputTokens)
            let outputCost = (provider.capabilities.costPerMillionOutputTokens ?? 0)
                / 1_000_000 * Double(analysis.estimatedOutputTokens)

            return CostEstimate(
                provider: provider.id,
                estimatedInputTokens: analysis.estimatedInputTokens,
                estimatedOutputTokens: analysis.estimatedOutputTokens,
                estimatedCost: inputCost + outputCost,
                isAvailable: availability[provider.id] ?? false,
                wouldBeSelected: provider.id == selectedProvider
            )
        }
    }
}

/// Pre-request cost estimate for a provider
public struct CostEstimate: Sendable, Identifiable {
    public var id: ProviderID { provider }
    public let provider: ProviderID
    public let estimatedInputTokens: Int
    public let estimatedOutputTokens: Int
    public let estimatedCost: Double
    public let isAvailable: Bool
    public let wouldBeSelected: Bool
}

/// Retry configuration for single-provider setups
public struct RetryConfiguration: Sendable {
    public let maxAttempts: Int
    public let baseDelay: Duration
    public let maxDelay: Duration

    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(30)
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }
}

extension Arbiter {
    /// Send a request, falling back through the routing decision's candidates.
    ///
    /// `adapt` reshapes the request for the provider about to receive it. Fallback can move
    /// a request between providers with very different capabilities, so the decision of
    /// what to send belongs per candidate rather than once per request.
    func performGenerate(
        messages: [Message],
        options: RequestOptions?,
        adapt: (@Sendable (ProviderID, AIRequest) -> AIRequest)? = nil
    ) async throws -> AIResponse {
        try Task.checkCancellation()

        guard !providers.isEmpty else {
            throw ArbiterError.invalidRequest(reason: "No providers configured. Add at least one provider via cloud(), local(), or system().")
        }

        let request = buildRequest(messages: messages, options: options)
        let decision = await routeRequest(request, options: options)

        guard decision.isAvailable else {
            throw unroutableError(for: decision)
        }

        let providerOrder = buildProviderOrder(from: decision)
        var attempts: [(ProviderID, any Error & Sendable)] = []
        let policy = executionPolicy(options: options)

        for providerID in providerOrder.prefix(policy.providerAttemptLimit) {
            guard let provider = providers.first(where: { $0.id == providerID }) else { continue }
            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                let providerRequest = adapt?(providerID, request) ?? request
                let response = try await executeGenerate(
                    request: providerRequest, provider: provider, options: options
                )
                let latency = CFAbsoluteTimeGetCurrent() - startTime
                let detectedTask = decision.analysis?.detectedTask ?? .conversation
                await router.performanceTracker.recordOutcome(
                    provider: providerID,
                    task: detectedTask,
                    latencySeconds: latency,
                    succeeded: true,
                    tokenCount: response.usage?.totalTokens ?? 0
                )
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failureLatency = CFAbsoluteTimeGetCurrent() - startTime
                attempts.append((providerID, error))
                let detectedTask = decision.analysis?.detectedTask ?? .conversation
                await router.performanceTracker.recordOutcome(
                    provider: providerID,
                    task: detectedTask,
                    latencySeconds: failureLatency,
                    succeeded: false,
                    tokenCount: 0
                )
                logger.debug("Provider \(providerID.rawValue) failed, trying next")
            }
        }

        throw ArbiterError.allProvidersFailed(attempts: attempts)
    }

    func executeGenerate(
        request: AIRequest,
        provider: any AIProvider,
        options: RequestOptions? = nil,
        allowQualityRetry: Bool = true
    ) async throws -> AIResponse {
        let processedRequest = try await applyRequestMiddleware(request)
        let reservation = try await reserveBudget(for: provider, request: processedRequest)
        // A reservation is settled exactly once. Without this, a failure *after* the
        // response was priced — a validation throw, or the quality retry throwing — would
        // release the estimate a second time and understate what has been spent.
        var settled = false
        let policy = executionPolicy(options: options)

        let operation: @Sendable () async throws -> AIResponse = {
            try await withTaskCancellationHandler {
                try await provider.generate(processedRequest)
            } onCancel: {
                logger.debug("Generate cancelled for \(provider.id.rawValue)")
            }
        }
        // The deadline belongs inside the retry, not around it: a request that timed out
        // gets a fresh attempt with a fresh deadline, rather than one budget shared by all
        // of them. Retry now runs whether or not fallback is enabled — the two are
        // consecutive stages of `ExecutionPolicy`, not alternatives.
        let attempt: @Sendable () async throws -> AIResponse = { [self] in
            guard let timeout = policy.timeout else { return try await operation() }
            return try await withTimeout(timeout, provider: provider.id) { try await operation() }
        }

        do {
            let response: AIResponse
            if let retry = policy.retry {
                let engine = RetryEngine(
                    maxRetries: retry.maxAttempts - 1,
                    baseDelay: retry.baseDelay,
                    maxDelay: retry.maxDelay
                )
                response = try await engine.execute(operation: attempt)
            } else {
                response = try await attempt()
            }

            await finalizeCost(reservation: reservation, usage: response.usage, provider: provider)
            settled = true
            let finalResponse = try await applyResponseMiddleware(response)

            if let validator = responseValidator {
                let analysis = analyser.analyse(processedRequest, providers: [provider])
                let result = validator.validate(finalResponse, for: processedRequest, analysis: analysis)
                switch result {
                case .valid, .truncated:
                    break
                case .empty, .refused:
                    let description = String(describing: result)
                    logger.warning("Response validation failed: \(description)")
                    throw ArbiterError.contentFiltered(
                        reason: "Response failed validation: \(description)"
                    )
                case .retryRecommended:
                    // Routed back through this method so the retry gets the same timeout,
                    // cancellation, budget reservation and cost tracking as the first
                    // attempt. `allowQualityRetry` stops the recursion at one retry: the
                    // second attempt is returned whatever its quality, and only an empty
                    // or refused response throws.
                    guard allowQualityRetry else { break }
                    logger.debug("Low quality response, retrying once")
                    return try await executeGenerate(
                        request: request, provider: provider,
                        options: options, allowQualityRetry: false
                    )
                }
            }

            return finalResponse
        } catch {
            if let reservation, !settled {
                await spendingGuard?.finalizeReservation(reservation, actualCost: 0)
            }
            throw error
        }
    }

    /// Ask for a typed value, by schema where the provider can be constrained to one and by
    /// prompt everywhere else.
    ///
    /// Both forms are prepared up front and chosen per provider, because fallback can hand
    /// the request to a provider that would ignore a schema and answer in prose.
    func generateStructured<T: Codable & Sendable>(
        messages: [Message],
        as type: T.Type,
        example: T?,
        options: RequestOptions?
    ) async throws -> T {
        guard let lastUserMessage = messages.last(where: { $0.role == .user }),
              let promptText = lastUserMessage.content.text else {
            throw ArbiterError.invalidRequest(reason: "No user message found for structured output")
        }

        let instruction = structuredOutputHandler.buildJSONPrompt(
            for: type, userPrompt: promptText, example: example
        )
        var promptMessages = messages.dropLast(where: { $0.id == lastUserMessage.id })
        promptMessages.append(.user(instruction))

        // A type whose shape cannot be derived — an enum property is the usual reason —
        // simply takes the prompt path everywhere.
        let schema = try? JSONSchemaBuilder.schema(for: type)
        if schema == nil {
            logger.debug("No schema derived for \(String(describing: type)); using the prompt path")
        }

        var mergedOptions = options ?? RequestOptions()
        mergedOptions.responseFormat = .json

        let original = messages
        let response = try await performGenerate(
            messages: promptMessages,
            options: mergedOptions
        ) { providerID, request in
            guard let schema, NativeStructuredOutput.supports(providerID) else { return request }
            var native = request
            // The schema constrains decoding, so the prompt keeps the caller's own wording
            // rather than the instructions that stand in for a schema — except where the
            // provider asks for both. See `NativeStructuredOutput.wantsInstructedPrompt`.
            if !NativeStructuredOutput.wantsInstructedPrompt(providerID) {
                native.messages = original
            }
            native.responseFormat = .structured(schema: schema)
            return native
        }

        // A refusal is the model declining, not malformed JSON, and saying so lets a caller
        // handle it without parsing a decoding error's message.
        if response.finishReason == .refusal {
            throw ArbiterError.refused(response.provider, explanation: response.content)
        }
        return try structuredOutputHandler.decode(response.content, as: type)
    }

    /// Why nothing could be routed to.
    ///
    /// A privacy constraint that left nowhere to run is reported as
    /// ``ArbiterError/privacyViolation(detectedTypes:reason:)`` rather than as a generic
    /// failure: the request was not attempted *deliberately*, and a fail-closed guard's
    /// whole purpose is that the caller can tell that apart from a network problem.
    ///
    /// The guard having narrowed the field is not enough on its own. If a private provider
    /// is registered and simply failed — offline, over its context window — then providers
    /// are what failed, and saying "register an on-device provider" to someone who has one
    /// would send them looking in the wrong place.
    func unroutableError(for decision: RoutingDecision) -> ArbiterError {
        guard let report = decision.privacyReport, report.forcesOnDevice else {
            return .allProvidersFailed(attempts: [])
        }
        let hasPrivateProvider = providers.contains { $0.capabilities.privacyLevel != .thirdPartyCloud }
        guard !hasPrivateProvider else { return .allProvidersFailed(attempts: []) }

        let reason: String
        if !report.matchedTags.isEmpty {
            reason = "request tagged \(report.matchedTags.map(\.rawValue).sorted().joined(separator: ", "))"
        } else if !report.detectedTypes.isEmpty {
            reason = "sensitive data detected"
        } else if report.failedClosed {
            reason = "detection was inconclusive and the guard fails closed"
        } else {
            reason = "the guard restricts this request to on-device providers"
        }
        return .privacyViolation(detectedTypes: report.sortedTypes, reason: reason)
    }

    /// The guards and recovery mechanisms this request runs under.
    func executionPolicy(options: RequestOptions?) -> ExecutionPolicy {
        ExecutionPolicy(
            routingPolicy: routingPolicy,
            retry: retryConfig,
            timeout: options?.timeout
        )
    }

    func withTimeout<T: Sendable>(
        _ timeout: Duration,
        provider: ProviderID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ArbiterError.timeout(provider, duration: timeout)
            }
            guard let result = try await group.next() else {
                throw ArbiterError.timeout(provider, duration: timeout)
            }
            group.cancelAll()
            return result
        }
    }

    func applyRequestMiddleware(_ request: AIRequest) async throws -> AIRequest {
        var processed = request
        for middleware in middlewares {
            processed = try await middleware.process(processed)
        }
        return processed
    }

    func applyResponseMiddleware(_ response: AIResponse) async throws -> AIResponse {
        var processed = response
        for middleware in middlewares {
            processed = try await middleware.process(processed)
        }
        return processed
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
            tags: options?.tags ?? [],
            providerOptions: options?.providerOptions ?? [:]
        )
        if let maxTokens = spendingGuard?.effectiveMaxTokens, request.maxTokens == nil {
            request.maxTokens = maxTokens
        }
        return request
    }

    func reserveBudget(for provider: any AIProvider, request: AIRequest) async throws -> SpendingGuard.Reservation? {
        guard let spendingGuard, provider.id.tier == .cloud else { return nil }
        let estimatedCost = await costTracker.estimateRequestCost(
            request: request, capabilities: provider.capabilities
        )
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
        // Cached tokens bill on top of `inputTokens`; ignoring them would let a
        // cache-heavy workload run past its budget unnoticed.
        usage.cost(
            inputPerMillion: provider.capabilities.costPerMillionInputTokens,
            outputPerMillion: provider.capabilities.costPerMillionOutputTokens
        )
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
            throw ArbiterError.invalidRequest(
                reason: "No providers configured. Add at least one provider via cloud(), local(), or system().")
        }

        var request = buildRequest(messages: messages, options: options)
        request = try await applyRequestMiddleware(request)
        let decision = await routeRequest(request, options: options)

        guard decision.isAvailable else {
            throw unroutableError(for: decision)
        }

        let lastError = await attemptStreamProviders(
            request: request, decision: decision, continuation: continuation
        )

        if let lastError {
            throw lastError
        }
    }

    func attemptStreamProviders(
        request: AIRequest,
        decision: RoutingDecision,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async -> (any Error)? {
        let providerOrder = buildProviderOrder(from: decision)
        let policy = executionPolicy(options: nil)
        var lastError: (any Error)?

        for providerID in providerOrder.prefix(policy.providerAttemptLimit) {
            guard let provider = providers.first(where: { $0.id == providerID }) else { continue }
            do {
                try await executeStream(
                    request: request, provider: provider, continuation: continuation
                )
                return nil
            } catch is CancellationError {
                return CancellationError()
            } catch let streamError as StreamingFallbackUnsafe {
                return streamError.underlying
            } catch {
                lastError = error
                logger.debug("Stream provider \(providerID.rawValue) failed, trying next")
                continue
            }
        }

        return lastError ?? ArbiterError.allProvidersFailed(attempts: [])
    }

    func executeStream(
        request: AIRequest,
        provider: any AIProvider,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        let reservation = try await reserveBudget(for: provider, request: request)
        let stream = provider.stream(request)
        var lastUsage: TokenUsage?
        var hasYieldedChunks = false

        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                if let usage = chunk.usage { lastUsage = usage }
                hasYieldedChunks = true
                continuation.yield(chunk)
            }
        } catch {
            if let reservation {
                await spendingGuard?.finalizeReservation(reservation, actualCost: 0)
            }
            if hasYieldedChunks {
                throw StreamingFallbackUnsafe(underlying: error)
            }
            throw error
        }

        await finalizeCost(reservation: reservation, usage: lastUsage, provider: provider)
        continuation.finish()
    }
}

/// Sentinel error: a streaming provider failed after already yielding chunks.
/// Retrying with another provider would corrupt the consumer's output stream.
private struct StreamingFallbackUnsafe: Error {
    let underlying: any Error & Sendable
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
    public var timeout: Duration?
    /// Provider-specific settings, keyed by the provider they configure.
    /// See `AIRequest.providerOptions`.
    public var providerOptions: [ProviderID: any Sendable]

    public init(
        model: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        systemPrompt: String? = nil,
        tools: [ToolDefinition]? = nil,
        responseFormat: ResponseFormat? = nil,
        provider: ProviderID? = nil,
        privacyRequired: Bool = false,
        tags: Set<RequestTag> = [],
        timeout: Duration? = nil,
        providerOptions: [ProviderID: any Sendable] = [:]
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
        self.timeout = timeout
        self.providerOptions = providerOptions
    }
}

/// Configuration for setting up Arbiter with multiple providers
public struct Configuration: Sendable {
    var providers: [any AIProvider] = []
    var routingPolicy: RoutingPolicy = .firstAvailable
    var spendingGuard: SpendingGuard?
    var privacyGuard: PrivacyGuard?
    var middlewares: [any AIMiddleware] = []
    var retryConfig: RetryConfiguration?
    var healthMonitor: ProviderHealthMonitor?
    var validationPolicy: ResponseValidationPolicy = .disabled
    var taskClassifier: (any TaskClassifier)?

    var resolvedResponseValidator: ResponseValidator? {
        switch validationPolicy {
        case .disabled: return nil
        case .enabled: return ResponseValidator()
        case .custom(let validator): return validator
        }
    }

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

    /// Supply an on-device classifier the router consults before its own task heuristics.
    ///
    /// See ``TaskClassifier``. A classifier that is unsure leaves the heuristics in charge.
    public mutating func taskClassification(_ classifier: any TaskClassifier) {
        taskClassifier = classifier
    }

    /// Add a middleware to the processing pipeline
    public mutating func middleware(_ middleware: any AIMiddleware) {
        middlewares.append(middleware)
    }

    /// Configure retry behaviour for single-provider setups
    public mutating func retry(
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(30)
    ) {
        retryConfig = RetryConfiguration(
            maxAttempts: maxAttempts,
            baseDelay: baseDelay,
            maxDelay: maxDelay
        )
    }

    /// Set the response validation policy
    public mutating func responseValidation(_ policy: ResponseValidationPolicy) {
        validationPolicy = policy
    }

    /// Enable periodic provider health monitoring
    public mutating func healthCheck(_ config: HealthCheckConfig) {
        switch config {
        case .disabled:
            healthMonitor = nil
        case .enabled(let interval):
            healthMonitor = ProviderHealthMonitor(checkInterval: interval)
        }
    }
}

private extension Array where Element == Message {
    func dropLast(where predicate: (Element) -> Bool) -> [Element] {
        guard let lastIndex = lastIndex(where: predicate) else { return self }
        var result = self
        result.remove(at: lastIndex)
        return result
    }
}
