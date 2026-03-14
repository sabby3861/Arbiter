// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("AppleFoundationProvider")
struct AppleFoundationProviderTests {

    @Test func providerHasCorrectId() {
        let provider = AppleFoundationProvider()
        #expect(provider.id == .appleFoundation)
    }

    @Test func providerCapabilitiesAreOnDevice() {
        let provider = AppleFoundationProvider()
        #expect(provider.capabilities.privacyLevel == .onDevice)
        #expect(provider.capabilities.costPerMillionInputTokens == nil)
        #expect(provider.capabilities.costPerMillionOutputTokens == nil)
        #expect(provider.capabilities.supportsStreaming)
    }

    @Test func providerSupportsChatAndSummarization() {
        let provider = AppleFoundationProvider()
        let tasks = provider.capabilities.supportedTasks
        #expect(tasks.contains(.chat))
        #expect(tasks.contains(.summarization))
        #expect(tasks.contains(.translation))
        #expect(tasks.contains(.structuredOutput))
    }

    @Test func providerDoesNotSupportToolCalling() {
        let provider = AppleFoundationProvider()
        #expect(!provider.capabilities.supportsToolCalling)
    }

    @Test func stubProviderReportsUnavailable() async {
        #if !canImport(FoundationModels)
        let provider = AppleFoundationProvider()
        let available = await provider.isAvailable
        #expect(!available)
        #endif
    }

    @Test func stubProviderThrowsOnGenerate() async {
        #if !canImport(FoundationModels)
        let provider = AppleFoundationProvider()
        let request = AIRequest.chat("Hello")

        await #expect(throws: SwiftAIError.self) {
            try await provider.generate(request)
        }
        #endif
    }

    @Test func stubProviderThrowsOnStream() async throws {
        #if !canImport(FoundationModels)
        let provider = AppleFoundationProvider()
        let request = AIRequest.chat("Hello")
        let stream = provider.stream(request)

        await #expect(throws: SwiftAIError.self) {
            for try await _ in stream {}
        }
        #endif
    }

    @Test func providerTierIsSystem() {
        #expect(ProviderID.appleFoundation.tier == .system)
    }

    @Test func providerDisplayNameIsCorrect() {
        #expect(ProviderID.appleFoundation.displayName == "Apple Foundation Models")
    }

    @Test func providerHasFastLatency() {
        let provider = AppleFoundationProvider()
        #expect(provider.capabilities.estimatedLatency == .fast)
    }

    @Test func providerDoesNotSupportImageInput() {
        let provider = AppleFoundationProvider()
        #expect(!provider.capabilities.supportsImageInput)
    }

    @Test func providerContextWindowIs4K() {
        let provider = AppleFoundationProvider()
        #expect(provider.capabilities.maxContextTokens == 4_096)
    }

    @Test func providerDoesNotSupportCodeGeneration() {
        let provider = AppleFoundationProvider()
        #expect(!provider.capabilities.supportedTasks.contains(.codeGeneration))
    }

    @Test func providerDoesNotSupportEmbedding() {
        let provider = AppleFoundationProvider()
        #expect(!provider.capabilities.supportedTasks.contains(.embedding))
    }
}

@Suite("AvailabilityChecker")
struct AvailabilityCheckerTests {

    @Test func unavailableReasonReturnsString() async {
        let reason = await AvailabilityChecker.unavailableReason()
        #expect(!reason.isEmpty)
    }

    @Test func availabilityCheckReturnsBoolean() async {
        let available = await AvailabilityChecker.isAppleFoundationAvailable()
        // On machines without FoundationModels, this should be false
        #if !canImport(FoundationModels)
        #expect(!available)
        #endif
        _ = available // Silence unused warning when FoundationModels IS available
    }
}
