// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("MLXProvider")
struct MLXProviderTests {

    @Test func stubProviderReportsUnavailable() async {
        let provider = MLXProvider(.auto)
        let available = await provider.isAvailable

        // When mlx-swift is not linked, the stub always returns false
        #if !canImport(MLX)
        #expect(!available)
        #endif
    }

    @Test func stubProviderThrowsOnGenerate() async {
        #if !canImport(MLX)
        let provider = MLXProvider(.auto)
        let request = AIRequest.chat("Hello")

        await #expect(throws: SwiftAIError.self) {
            try await provider.generate(request)
        }
        #endif
    }

    @Test func stubProviderThrowsOnStream() async throws {
        #if !canImport(MLX)
        let provider = MLXProvider(.auto)
        let request = AIRequest.chat("Hello")
        let stream = provider.stream(request)

        await #expect(throws: SwiftAIError.self) {
            for try await _ in stream {}
        }
        #endif
    }

    @Test func providerHasCorrectId() {
        let provider = MLXProvider(.auto)
        #expect(provider.id == .mlx)
    }

    @Test func providerCapabilitiesAreOnDevice() {
        let provider = MLXProvider(.auto)
        #expect(provider.capabilities.privacyLevel == .onDevice)
        #expect(provider.capabilities.costPerMillionInputTokens == nil)
        #expect(provider.capabilities.costPerMillionOutputTokens == nil)
        #expect(provider.capabilities.supportsStreaming)
    }

    @Test func configurationAutoSelectCreatesProvider() {
        let config = MLXProviderConfiguration.auto
        #expect(config.autoSelectModel)
        #expect(config.modelId == nil)
    }

    @Test func configurationExplicitModelCreatesProvider() {
        let config = MLXProviderConfiguration.model("mlx-community/Qwen2.5-3B-Instruct-4bit")
        #expect(config.modelId == "mlx-community/Qwen2.5-3B-Instruct-4bit")
        #expect(!config.autoSelectModel)
    }

    @Test func providerTierIsOnDevice() {
        #expect(ProviderID.mlx.tier == .onDevice)
    }

    @Test func providerDoesNotSupportToolCalling() {
        let provider = MLXProvider(.auto)
        #expect(!provider.capabilities.supportsToolCalling)
    }

    @Test func providerDoesNotSupportImageInput() {
        let provider = MLXProvider(.auto)
        #expect(!provider.capabilities.supportsImageInput)
    }

    @Test func configurationWithGPUCacheLimit() {
        let config = MLXProviderConfiguration(gpuCacheLimit: 1_073_741_824)
        #expect(config.gpuCacheLimit == 1_073_741_824)
    }

    @Test func configurationDefaultIsNotAutoSelect() {
        let config = MLXProviderConfiguration()
        #expect(!config.autoSelectModel)
        #expect(config.modelId == nil)
        #expect(config.gpuCacheLimit == nil)
    }

    @Test func providerDisplayNameIsCorrect() {
        #expect(ProviderID.mlx.displayName == "MLX")
    }

    @Test func providerSupportsChatTask() {
        let provider = MLXProvider(.auto)
        #expect(provider.capabilities.supportedTasks.contains(.chat))
        #expect(provider.capabilities.supportedTasks.contains(.codeGeneration))
    }
}

@Suite("MLXModelRegistry")
struct MLXModelRegistryTests {

    @Test func registryRecommendsTinyModelForSmallDevice() {
        let registry = MLXModelRegistry()
        let device = DeviceCapabilities(memoryGB: 6, thermalLevel: .nominal, processorCount: 4)
        let modelId = registry.recommendedModel(for: device)

        #expect(!modelId.isEmpty)
        let info = registry.modelInfo(for: modelId)
        #expect(info != nil)
        #expect(info?.minimumTier == .small)
    }

    @Test func registryRecommendsMediumModelForMediumDevice() {
        let registry = MLXModelRegistry()
        let device = DeviceCapabilities(memoryGB: 12, thermalLevel: .nominal, processorCount: 8)
        let modelId = registry.recommendedModel(for: device)

        let info = registry.modelInfo(for: modelId)
        #expect(info != nil)
        #expect(info?.minimumTier == .medium || info?.minimumTier == .small)
    }

    @Test func registryRecommendsLargeModelForLargeDevice() {
        let registry = MLXModelRegistry()
        let device = DeviceCapabilities(memoryGB: 24, thermalLevel: .nominal, processorCount: 10)
        let modelId = registry.recommendedModel(for: device)

        let info = registry.modelInfo(for: modelId)
        #expect(info != nil)
    }

    @Test func registryReturnsDefaultForTinyDevice() {
        let registry = MLXModelRegistry()
        let device = DeviceCapabilities(memoryGB: 2, thermalLevel: .nominal, processorCount: 2)
        let modelId = registry.recommendedModel(for: device)

        #expect(!modelId.isEmpty)
    }

    @Test func modelInfoReturnsNilForUnknownModel() {
        let registry = MLXModelRegistry()
        let info = registry.modelInfo(for: "nonexistent/model-id")
        #expect(info == nil)
    }

    @Test func modelInfoReturnsEntryForKnownModel() {
        let registry = MLXModelRegistry()
        let info = registry.modelInfo(for: "mlx-community/Qwen2.5-3B-Instruct-4bit")
        #expect(info != nil)
        #expect(info?.contextWindow ?? 0 > 0)
    }
}
