// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "MLXProvider")

/// Configuration for the MLX on-device provider.
public struct MLXProviderConfiguration: Sendable {
    public let modelId: String?
    public let autoSelectModel: Bool
    public let gpuCacheLimit: UInt64?

    public init(modelId: String? = nil, autoSelectModel: Bool = false, gpuCacheLimit: UInt64? = nil) {
        self.modelId = modelId
        self.autoSelectModel = autoSelectModel
        self.gpuCacheLimit = gpuCacheLimit
    }

    /// Auto-select the best model based on device capabilities.
    public static let auto = MLXProviderConfiguration(autoSelectModel: true)

    /// Use a specific HuggingFace model.
    public static func model(_ huggingFaceId: String) -> MLXProviderConfiguration {
        MLXProviderConfiguration(modelId: huggingFaceId)
    }
}

#if canImport(MLX) && canImport(MLXLLM)
import MLX
@preconcurrency import MLXLMCommon
import MLXLLM

/// Thread-safe cache for loaded MLX model containers.
///
/// Uses task deduplication to prevent redundant concurrent loads — if two
/// callers request the same model simultaneously, only one download/load
/// occurs and both await the same result.
private actor ModelContainerCache {
    private var cache: [String: ModelContainer] = [:]
    private var inFlightLoads: [String: Task<ModelContainer, Error>] = [:]

    func clearAll() {
        cache.removeAll()
        for (_, task) in inFlightLoads { task.cancel() }
        inFlightLoads.removeAll()
    }

    func load(
        for modelId: String,
        using loader: @escaping @Sendable () async throws -> ModelContainer
    ) async throws -> ModelContainer {
        if let container = cache[modelId] {
            return container
        }
        if let existingTask = inFlightLoads[modelId] {
            return try await existingTask.value
        }
        let task = Task { try await loader() }
        inFlightLoads[modelId] = task
        do {
            let container = try await task.value
            cache[modelId] = container
            inFlightLoads.removeValue(forKey: modelId)
            return container
        } catch {
            inFlightLoads.removeValue(forKey: modelId)
            throw error
        }
    }
}

/// On-device AI provider using MLX Swift for Apple Silicon inference.
///
/// Runs models locally with zero network dependency and complete data privacy.
/// ```swift
/// let ai = Arbiter {
///     $0.local(MLXProvider(.auto))
/// }
/// ```
public struct MLXProvider: AIProvider, UnloadableProvider, Sendable {
    public let id: ProviderID = .mlx

    private let configuration: MLXProviderConfiguration
    private let modelRegistry: MLXModelRegistry
    private let resolvedModelId: String
    private let containerCache = ModelContainerCache()

    /// Unload all cached models from memory.
    ///
    /// Called automatically by ``LifecycleManager`` on memory warnings.
    /// The next `generate` or `stream` call will re-download and reload the model.
    public func unloadModel() {
        Task { await containerCache.clearAll() }
        logger.info("MLX model cache cleared — model will reload on next request")
    }

    public var capabilities: ProviderCapabilities {
        let modelInfo = modelRegistry.modelInfo(for: resolvedModelId)
        return ProviderCapabilities(
            supportedTasks: [.chat, .completion, .codeGeneration, .summarization, .translation],
            maxContextTokens: modelInfo?.contextWindow ?? 4_096,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .moderate,
            privacyLevel: .onDevice
        )
    }

    public var isAvailable: Bool {
        get async {
            let device = DeviceAssessor.assess()
            return device.canRunLocalModels
        }
    }

    /// Create an MLX provider with the given configuration.
    public init(_ configuration: MLXProviderConfiguration = .auto) {
        self.configuration = configuration
        let registry = MLXModelRegistry()
        self.modelRegistry = registry

        if let explicit = configuration.modelId {
            self.resolvedModelId = explicit
        } else if configuration.autoSelectModel {
            let device = DeviceAssessor.assess()
            self.resolvedModelId = registry.recommendedModel(for: device)
        } else {
            self.resolvedModelId = MLXModelRegistry.defaultModelId
        }

        if let cacheLimit = configuration.gpuCacheLimit {
            MLX.GPU.set(cacheLimit: Int(clamping: cacheLimit))
        }
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        try Task.checkCancellation()

        let device = DeviceAssessor.assess()
        guard device.canRunLocalModels else {
            throw ArbiterError.deviceNotCapable(reason: "Device requires at least 4GB RAM and non-critical thermal state")
        }

        let container = try await loadModel()
        let chatMessages = try buildChatMessages(from: request)
        let parameters = buildGenerateParameters(from: request)

        do {
            // Use ModelContainer directly with structured Chat.Message arrays.
            // This feeds role-annotated messages into the tokenizer's chat template
            // (via processor.prepare → tokenizer.applyChatTemplate), preserving
            // multi-turn context without the double-formatting that ChatSession
            // would introduce (it wraps the entire input as a single user message).
            let result: GenerateResult = try await container.perform { context in
                let userInput = UserInput(chat: chatMessages)
                let lmInput = try await context.processor.prepare(input: userInput)
                return try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: parameters,
                    context: context
                ) { tokens in
                    if let max = parameters.maxTokens, tokens.count >= max {
                        return .stop
                    }
                    return .more
                }
            }

            let hitMaxTokens = parameters.maxTokens.map { result.generationTokenCount >= $0 } ?? false

            return AIResponse(
                id: "mlx-\(UUID().uuidString)",
                content: result.output,
                model: resolvedModelId,
                provider: .mlx,
                usage: TokenUsage(
                    inputTokens: result.promptTokenCount,
                    outputTokens: result.generationTokenCount
                ),
                finishReason: hitMaxTokens ? .maxTokens : .complete
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("MLX generation failed: \(error.localizedDescription)")
            throw ArbiterError.providerUnavailable(.mlx, reason: error.localizedDescription)
        }
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

private extension MLXProvider {
    func loadModel() async throws -> ModelContainer {
        let modelId = resolvedModelId
        do {
            return try await containerCache.load(for: modelId) {
                try await loadModelContainer(id: modelId)
            }
        } catch {
            logger.error("Failed to load MLX model '\(modelId)': \(error.localizedDescription)")
            throw ArbiterError.modelNotFound(modelId)
        }
    }

    /// Convert Arbiter messages to MLXLMCommon's model-agnostic `Chat.Message` format.
    ///
    /// These structured messages are passed to `UserInput(chat:)` which feeds them
    /// through the model's `MessageGenerator` and `tokenizer.applyChatTemplate()`.
    /// This ensures each role is correctly annotated with the model-specific chat
    /// template tokens (e.g. `<|user|>`, `<|assistant|>`) — without the
    /// double-formatting that occurs when a pre-formatted string is wrapped as a
    /// single user message by `ChatSession.respond(to:)`.
    func buildChatMessages(from request: AIRequest) throws -> [Chat.Message] {
        var chatMessages = [Chat.Message]()

        if let systemPrompt = request.systemPrompt {
            chatMessages.append(.system(systemPrompt))
        }

        for message in request.messages {
            guard let text = message.content.text else { continue }
            switch message.role {
            case .user:
                chatMessages.append(.user(text))
            case .assistant:
                chatMessages.append(.assistant(text))
            case .system:
                chatMessages.append(.system(text))
            case .tool:
                chatMessages.append(.tool(text))
            }
        }

        guard !chatMessages.isEmpty else {
            throw ArbiterError.providerUnavailable(.mlx, reason: "Request contains no text messages to process")
        }

        return chatMessages
    }

    /// Default token ceiling when the caller does not specify `maxTokens`.
    /// Prevents unbounded generation if the model fails to emit an EOS token.
    static let defaultMaxTokens = 4_096

    /// Map Arbiter request parameters to MLX generation parameters.
    func buildGenerateParameters(from request: AIRequest) -> GenerateParameters {
        GenerateParameters(
            maxTokens: request.maxTokens ?? Self.defaultMaxTokens,
            temperature: request.temperature.map { Float($0) } ?? 0.6,
            topP: request.topP.map { Float($0) } ?? 1.0
        )
    }

    func performStream(
        for request: AIRequest,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()

        let device = DeviceAssessor.assess()
        guard device.canRunLocalModels else {
            throw ArbiterError.deviceNotCapable(reason: "Device requires at least 4GB RAM and non-critical thermal state")
        }

        let container = try await loadModel()
        let chatMessages = try buildChatMessages(from: request)
        let parameters = buildGenerateParameters(from: request)

        // Stream tokens using ModelContainer directly with structured messages.
        // See buildChatMessages() for why we bypass ChatSession.
        do {
            try await container.perform { context in
                let userInput = UserInput(chat: chatMessages)
                let lmInput = try await context.processor.prepare(input: userInput)
                let tokenStream: AsyncStream<Generation> = try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: parameters,
                    context: context
                )

                let (accumulated, completionInfo) = try await consumeTokenStream(
                    tokenStream, continuation: continuation
                )

                yieldFinalChunk(
                    accumulated: accumulated,
                    completionInfo: completionInfo,
                    fallbackInputTokens: lmInput.text.tokens.size,
                    parameters: parameters,
                    continuation: continuation
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("MLX stream failed: \(error.localizedDescription)")
            throw ArbiterError.providerUnavailable(.mlx, reason: error.localizedDescription)
        }
    }

    func consumeTokenStream(
        _ tokenStream: AsyncStream<Generation>,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws -> (String, GenerateCompletionInfo?) {
        var accumulated = ""
        var completionInfo: GenerateCompletionInfo?

        for await generation in tokenStream {
            try Task.checkCancellation()
            switch generation {
            case .chunk(let chunk):
                accumulated += chunk
                continuation.yield(AIStreamChunk(
                    delta: chunk,
                    accumulatedContent: accumulated,
                    isComplete: false,
                    provider: .mlx
                ))
            case .info(let info):
                completionInfo = info
            case .toolCall:
                break
            }
        }

        return (accumulated, completionInfo)
    }

    func yieldFinalChunk(
        accumulated: String,
        completionInfo: GenerateCompletionInfo?,
        fallbackInputTokens: Int,
        parameters: GenerateParameters,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) {
        let inputTokens = completionInfo?.promptTokenCount ?? fallbackInputTokens
        let outputTokens = completionInfo?.generationTokenCount ?? 0
        let maxTokens = parameters.maxTokens ?? Self.defaultMaxTokens
        let hitMaxTokens = outputTokens >= maxTokens

        continuation.yield(AIStreamChunk(
            delta: "",
            accumulatedContent: accumulated,
            isComplete: true,
            usage: TokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens
            ),
            finishReason: hitMaxTokens ? .maxTokens : .complete,
            provider: .mlx
        ))
    }
}

#else

/// Stub MLX provider when mlx-swift is not available.
///
/// Reports as unavailable so the router skips it gracefully.
/// Add mlx-swift as a dependency to enable on-device inference.
public struct MLXProvider: AIProvider, UnloadableProvider, Sendable {
    public let id: ProviderID = .mlx

    public func unloadModel() {}

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            supportedTasks: [.chat, .completion, .codeGeneration, .summarization, .translation],
            maxContextTokens: 4_096,
            supportsStreaming: true,
            supportsToolCalling: false,
            supportsImageInput: false,
            costPerMillionInputTokens: nil,
            costPerMillionOutputTokens: nil,
            estimatedLatency: .moderate,
            privacyLevel: .onDevice
        )
    }

    public var isAvailable: Bool {
        get async { false }
    }

    public init(_ configuration: MLXProviderConfiguration = .auto) {
        logger.debug("MLX provider stub initialized — mlx-swift dependency not linked")
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        throw ArbiterError.providerUnavailable(.mlx, reason: "MLX Swift is not available. Add mlx-swift as a package dependency.")
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ArbiterError.providerUnavailable(
                .mlx, reason: "MLX Swift is not available. Add mlx-swift as a package dependency."
            ))
        }
    }
}

#endif
