// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "MLXProvider")

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
import MLXLMCommon
import MLXLLM

/// Thread-safe cache for loaded MLX model containers.
private actor ModelContainerCache {
    private var cache: [String: ModelContainer] = [:]

    func get(for modelId: String) -> ModelContainer? {
        cache[modelId]
    }

    func set(_ container: ModelContainer, for modelId: String) {
        cache[modelId] = container
    }
}

/// On-device AI provider using MLX Swift for Apple Silicon inference.
///
/// Runs models locally with zero network dependency and complete data privacy.
/// ```swift
/// let ai = SwiftAI {
///     $0.local(MLXProvider(.auto))
/// }
/// ```
public struct MLXProvider: AIProvider, Sendable {
    public let id: ProviderID = .mlx

    private let configuration: MLXProviderConfiguration
    private let modelRegistry: MLXModelRegistry
    private let resolvedModelId: String
    private let containerCache = ModelContainerCache()

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
            throw SwiftAIError.deviceNotCapable(reason: "Device requires at least 4GB RAM and non-critical thermal state")
        }

        let container = try await loadModel()
        let chatSession = ChatSession(container, instructions: request.systemPrompt)
        let prompt = buildConversationPrompt(from: request)

        do {
            let content = try await chatSession.respond(to: prompt)

            return AIResponse(
                id: "mlx-\(UUID().uuidString)",
                content: content,
                model: resolvedModelId,
                provider: .mlx,
                finishReason: .complete
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("MLX generation failed: \(error.localizedDescription)")
            throw SwiftAIError.providerUnavailable(.mlx, reason: error.localizedDescription)
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
        if let cached = await containerCache.get(for: resolvedModelId) {
            return cached
        }
        do {
            let container = try await loadModelContainer(id: resolvedModelId)
            await containerCache.set(container, for: resolvedModelId)
            return container
        } catch {
            logger.error("Failed to load MLX model '\(self.resolvedModelId)': \(error.localizedDescription)")
            throw SwiftAIError.modelNotFound(resolvedModelId)
        }
    }

    func buildConversationPrompt(from request: AIRequest) -> String {
        var parts: [String] = []
        for message in request.messages {
            guard let text = message.content.text else { continue }
            switch message.role {
            case .user:
                parts.append("User: \(text)")
            case .assistant:
                parts.append("Assistant: \(text)")
            case .system:
                parts.append("System: \(text)")
            case .tool:
                parts.append("Tool: \(text)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    func performStream(
        for request: AIRequest,
        continuation: AsyncThrowingStream<AIStreamChunk, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()

        let device = DeviceAssessor.assess()
        guard device.canRunLocalModels else {
            throw SwiftAIError.deviceNotCapable(reason: "Device requires at least 4GB RAM and non-critical thermal state")
        }

        let container = try await loadModel()
        let chatSession = ChatSession(container, instructions: request.systemPrompt)
        let prompt = buildConversationPrompt(from: request)

        var accumulated = ""
        var tokenCount = 0

        let tokenStream = chatSession.streamResponse(to: prompt)

        do {
            for try await token in tokenStream {
                try Task.checkCancellation()
                accumulated += token
                tokenCount += 1

                continuation.yield(AIStreamChunk(
                    delta: token,
                    accumulatedContent: accumulated,
                    isComplete: false,
                    provider: .mlx
                ))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("MLX stream failed: \(error.localizedDescription)")
            throw SwiftAIError.providerUnavailable(.mlx, reason: error.localizedDescription)
        }

        continuation.yield(AIStreamChunk(
            delta: "",
            accumulatedContent: accumulated,
            isComplete: true,
            usage: TokenUsage(inputTokens: 0, outputTokens: tokenCount),
            finishReason: .complete,
            provider: .mlx
        ))
    }
}

#else

/// Stub MLX provider when mlx-swift is not available.
///
/// Reports as unavailable so the router skips it gracefully.
/// Add mlx-swift as a dependency to enable on-device inference.
public struct MLXProvider: AIProvider, Sendable {
    public let id: ProviderID = .mlx

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
        throw SwiftAIError.providerUnavailable(.mlx, reason: "MLX Swift is not available. Add mlx-swift as a package dependency.")
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: SwiftAIError.providerUnavailable(
                .mlx, reason: "MLX Swift is not available. Add mlx-swift as a package dependency."
            ))
        }
    }
}

#endif
