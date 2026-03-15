// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
@testable import SwiftAI

@Suite("RequestAnalyser")
struct RequestAnalyserTests {
    let analyser = RequestAnalyser()

    @Test("'Is this positive or negative?' → trivial, classification")
    func classificationDetection() {
        let request = AIRequest.chat("Is this positive or negative?")
        let result = analyser.analyse(request)
        #expect(result.detectedTask == .classification)
        #expect(result.complexity == .trivial || result.complexity == .simple)
    }

    @Test("'Translate hello to French' → simple, translation")
    func translationDetection() {
        let request = AIRequest.chat("Translate 'hello' to French")
        let result = analyser.analyse(request)
        #expect(result.detectedTask == .translation)
        #expect(result.complexity <= .simple)
    }

    @Test("'Summarize this article' with long text → simple, summarization")
    func summarizationDetection() {
        let longText = String(repeating: "This is a long article about technology. ", count: 50)
        let request = AIRequest.chat("Summarize this article: \(longText)")
        let result = analyser.analyse(request)
        #expect(result.detectedTask == .summarization)
    }

    @Test("'Write a 2000-word essay about AI' → complex, longGeneration")
    func longGenerationDetection() {
        let request = AIRequest.chat("Write a 2000-word essay about AI")
        let result = analyser.analyse(request)
        #expect(result.detectedTask == .longGeneration)
        #expect(result.complexity >= .complex)
    }

    @Test("'Write a Swift function that sorts' → complex, codeGeneration")
    func codeGenerationDetection() {
        let request = AIRequest.chat("Write a Swift function that sorts an array of integers")
        let result = analyser.analyse(request)
        #expect(result.detectedTask == .codeGeneration)
        #expect(result.complexity >= .complex)
    }

    @Test("'Explain step by step why' → complex, reasoning")
    func reasoningDetection() {
        let request = AIRequest.chat("Explain step by step why the sky is blue")
        let result = analyser.analyse(request)
        #expect(result.detectedTask == .reasoning)
        #expect(result.complexity >= .complex)
    }

    @Test("'Hello, how are you?' → trivial, conversation")
    func conversationDetection() {
        let request = AIRequest.chat("Hello, how are you?")
        let result = analyser.analyse(request)
        #expect(result.detectedTask == .conversation)
    }

    @Test("Cost estimation produces non-zero for cloud providers")
    func costEstimationCloud() {
        let cloudProvider = MockProvider(
            id: .anthropic,
            capabilities: ProviderCapabilities(
                supportedTasks: [.chat],
                maxContextTokens: 200_000,
                supportsStreaming: true,
                supportsToolCalling: true,
                supportsImageInput: true,
                costPerMillionInputTokens: 3.0,
                costPerMillionOutputTokens: 15.0,
                estimatedLatency: .moderate,
                privacyLevel: .thirdPartyCloud
            )
        )
        let request = AIRequest.chat("Write a function")
        let result = analyser.analyse(request, providers: [cloudProvider])
        let anthropicCost = result.costEstimates[.anthropic] ?? 0
        #expect(anthropicCost > 0)
    }

    @Test("Cost estimation produces zero for free providers")
    func costEstimationFree() {
        let freeProvider = MockLocalProvider()
        let request = AIRequest.chat("Hello")
        let result = analyser.analyse(request, providers: [freeProvider])
        let mlxCost = result.costEstimates[.mlx] ?? 0
        #expect(mlxCost == 0)
    }

    @Test("ComplexityTier is Comparable: trivial < expert")
    func complexityComparable() {
        #expect(ComplexityTier.trivial < ComplexityTier.expert)
        #expect(ComplexityTier.simple < ComplexityTier.complex)
        #expect(ComplexityTier.moderate < ComplexityTier.expert)
    }

    @Test("Structured output request detected when response format is set")
    func structuredOutputDetected() {
        var request = AIRequest.chat("Give me a recipe")
        request.responseFormat = .json
        let result = analyser.analyse(request)
        #expect(result.detectedTask == .structuredOutput)
    }

    @Test("Output estimation is reasonable")
    func outputEstimation() {
        let request = AIRequest.chat("Is this positive or negative?")
        let result = analyser.analyse(request)
        #expect(result.estimatedOutputTokens > 0)
        #expect(result.estimatedInputTokens > 0)
    }

    @Test("Code with code fences detected")
    func codeFencesDetection() {
        let request = AIRequest.chat("What's wrong with this code?\n```swift\nlet x = 1\n```")
        let result = analyser.analyse(request)
        #expect(result.detectedTask == .codeGeneration)
    }

    @Test("Reasoning tasks require reasoning flag")
    func reasoningFlag() {
        let request = AIRequest.chat("Explain step by step why gravity works")
        let result = analyser.analyse(request)
        #expect(result.requiresReasoning == true)
    }
}
