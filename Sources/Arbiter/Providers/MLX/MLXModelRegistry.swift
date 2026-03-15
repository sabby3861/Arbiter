// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Registry of tested MLX models with device compatibility recommendations.
///
/// Each model entry includes RAM requirements and context window sizes,
/// enabling the router to pick the right model for the current device.
public struct MLXModelRegistry: Sendable {
    public static let defaultModelId = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    private let models: [MLXModelEntry]

    public init() {
        self.models = Self.curatedModels
    }

    /// Recommend the best model for the given device capabilities.
    public func recommendedModel(for device: DeviceCapabilities) -> String {
        let tier = device.recommendedLocalTier
        let candidates = models.filter { $0.minimumTier <= tier }

        guard let best = candidates.last else {
            return Self.defaultModelId
        }
        return best.huggingFaceId
    }

    /// Get model metadata for a specific model ID.
    public func modelInfo(for modelId: String) -> MLXModelEntry? {
        models.first { $0.huggingFaceId == modelId }
    }
}

/// Metadata for a single MLX model.
public struct MLXModelEntry: Sendable {
    public let huggingFaceId: String
    public let displayName: String
    public let parameterCount: String
    public let quantization: String
    public let contextWindow: Int
    public let ramRequired: Double
    public let minimumTier: LocalModelTier

    public init(
        huggingFaceId: String,
        displayName: String,
        parameterCount: String,
        quantization: String,
        contextWindow: Int,
        ramRequired: Double,
        minimumTier: LocalModelTier
    ) {
        self.huggingFaceId = huggingFaceId
        self.displayName = displayName
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.contextWindow = contextWindow
        self.ramRequired = ramRequired
        self.minimumTier = minimumTier
    }
}

private extension MLXModelRegistry {
    static let curatedModels: [MLXModelEntry] = [
        // Small tier (4-8GB RAM)
        MLXModelEntry(
            huggingFaceId: "mlx-community/SmolLM2-360M-Instruct-4bit",
            displayName: "SmolLM2 360M",
            parameterCount: "360M", quantization: "4-bit",
            contextWindow: 2_048, ramRequired: 0.5, minimumTier: .small
        ),
        MLXModelEntry(
            huggingFaceId: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            displayName: "Qwen 2.5 0.5B",
            parameterCount: "0.5B", quantization: "4-bit",
            contextWindow: 4_096, ramRequired: 0.8, minimumTier: .small
        ),
        MLXModelEntry(
            huggingFaceId: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            displayName: "Qwen 2.5 1.5B",
            parameterCount: "1.5B", quantization: "4-bit",
            contextWindow: 4_096, ramRequired: 1.5, minimumTier: .small
        ),
        MLXModelEntry(
            huggingFaceId: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            displayName: "Llama 3.2 1B",
            parameterCount: "1B", quantization: "4-bit",
            contextWindow: 8_192, ramRequired: 1.2, minimumTier: .small
        ),
        MLXModelEntry(
            huggingFaceId: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B",
            parameterCount: "3B", quantization: "4-bit",
            contextWindow: 8_192, ramRequired: 2.5, minimumTier: .small
        ),
        MLXModelEntry(
            huggingFaceId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            displayName: "Qwen 2.5 3B",
            parameterCount: "3B", quantization: "4-bit",
            contextWindow: 4_096, ramRequired: 2.5, minimumTier: .small
        ),

        // Medium tier (8-16GB RAM)
        MLXModelEntry(
            huggingFaceId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            displayName: "Qwen 2.5 7B",
            parameterCount: "7B", quantization: "4-bit",
            contextWindow: 8_192, ramRequired: 5.0, minimumTier: .medium
        ),
        MLXModelEntry(
            huggingFaceId: "mlx-community/Llama-3.1-8B-Instruct-4bit",
            displayName: "Llama 3.1 8B",
            parameterCount: "8B", quantization: "4-bit",
            contextWindow: 8_192, ramRequired: 5.5, minimumTier: .medium
        ),
        MLXModelEntry(
            huggingFaceId: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            displayName: "Mistral 7B v0.3",
            parameterCount: "7B", quantization: "4-bit",
            contextWindow: 8_192, ramRequired: 5.0, minimumTier: .medium
        ),
        MLXModelEntry(
            huggingFaceId: "mlx-community/gemma-2-9b-it-4bit",
            displayName: "Gemma 2 9B",
            parameterCount: "9B", quantization: "4-bit",
            contextWindow: 8_192, ramRequired: 6.5, minimumTier: .medium
        ),

        // Large tier (16-32GB RAM)
        MLXModelEntry(
            huggingFaceId: "mlx-community/Qwen2.5-14B-Instruct-4bit",
            displayName: "Qwen 2.5 14B",
            parameterCount: "14B", quantization: "4-bit",
            contextWindow: 8_192, ramRequired: 9.0, minimumTier: .large
        ),
        MLXModelEntry(
            huggingFaceId: "mlx-community/Mistral-Nemo-Instruct-2407-4bit",
            displayName: "Mistral Nemo 12B",
            parameterCount: "12B", quantization: "4-bit",
            contextWindow: 16_384, ramRequired: 8.5, minimumTier: .large
        ),

        // XLarge tier (32GB+ RAM)
        MLXModelEntry(
            huggingFaceId: "mlx-community/Qwen2.5-32B-Instruct-4bit",
            displayName: "Qwen 2.5 32B",
            parameterCount: "32B", quantization: "4-bit",
            contextWindow: 16_384, ramRequired: 20.0, minimumTier: .xlarge
        ),
        MLXModelEntry(
            huggingFaceId: "mlx-community/Llama-3.3-70B-Instruct-4bit",
            displayName: "Llama 3.3 70B",
            parameterCount: "70B", quantization: "4-bit",
            contextWindow: 16_384, ramRequired: 42.0, minimumTier: .xlarge
        ),
    ]
}
