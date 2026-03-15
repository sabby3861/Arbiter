// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Analyses AI requests to determine complexity, intent, and
/// optimal provider characteristics.
///
/// This is the intelligence layer that makes Arbiter's routing
/// genuinely smart — not just capability matching but understanding
/// WHAT the request needs before deciding WHERE to send it.
public struct RequestAnalyser: Sendable {

    public init() {}

    /// Analyse a request and return routing hints
    public func analyse(
        _ request: AIRequest,
        providers: [any AIProvider] = []
    ) -> RequestAnalysis {
        let promptText = extractPromptText(from: request)
        let estimatedInputTokens = TokenEstimator.estimateTokens(for: request.messages)

        let hasStructuredOutput = request.responseFormat != nil && request.responseFormat != .text
        let detectedTask = detectTask(from: promptText, hasStructuredOutput: hasStructuredOutput)
        let complexity = classifyComplexity(
            inputTokens: estimatedInputTokens,
            task: detectedTask,
            promptText: promptText
        )

        let estimatedOutputTokens = estimateOutputTokens(
            task: detectedTask,
            inputTokens: estimatedInputTokens
        )

        let requiresReasoning = detectedTask == .reasoning
            || detectedTask == .codeGeneration
            || complexity >= .complex

        let costEstimates = buildCostEstimates(
            providers: providers,
            inputTokens: estimatedInputTokens,
            outputTokens: estimatedOutputTokens
        )

        return RequestAnalysis(
            complexity: complexity,
            detectedTask: detectedTask,
            estimatedInputTokens: estimatedInputTokens,
            estimatedOutputTokens: estimatedOutputTokens,
            requiresReasoning: requiresReasoning,
            costEstimates: costEstimates
        )
    }
}

private extension RequestAnalyser {
    func extractPromptText(from request: AIRequest) -> String {
        let messageText = request.messages
            .compactMap { $0.content.text }
            .joined(separator: " ")
        if let system = request.systemPrompt {
            return system + " " + messageText
        }
        return messageText
    }

    func detectTask(from text: String, hasStructuredOutput: Bool) -> DetectedTask {
        if hasStructuredOutput {
            return .structuredOutput
        }

        let lowered = text.lowercased()

        if matchesClassification(lowered) { return .classification }
        if matchesExtraction(lowered) { return .extraction }
        if matchesTranslation(lowered) { return .translation }
        if matchesSummarization(lowered) { return .summarization }
        if matchesCodeGeneration(lowered, original: text) { return .codeGeneration }
        if matchesReasoning(lowered) { return .reasoning }
        if matchesLongGeneration(lowered) { return .longGeneration }
        if matchesShortGeneration(lowered) { return .shortGeneration }

        return .conversation
    }

    func matchesClassification(_ text: String) -> Bool {
        let signals = [
            "classify", "categorize", "categorise", "is this",
            "positive or negative", "yes or no", "true or false",
            "sentiment",
        ]
        return signals.contains { text.contains($0) }
    }

    func matchesExtraction(_ text: String) -> Bool {
        let signals = ["extract", "find the", "list all", "what is the", "pull out"]
        return signals.contains { text.contains($0) }
    }

    func matchesTranslation(_ text: String) -> Bool {
        let signals = [
            "translate", "in french", "in spanish", "in german",
            "in japanese", "in chinese", "to french", "to spanish",
            "to german", "to japanese", "to chinese",
        ]
        return signals.contains { text.contains($0) }
    }

    func matchesSummarization(_ text: String) -> Bool {
        let signals = ["summarize", "summarise", "tldr", "brief overview", "sum up", "recap"]
        return signals.contains { text.contains($0) }
    }

    func matchesCodeGeneration(_ text: String, original: String) -> Bool {
        let signals = [
            "write code", "function that", "debug", "refactor",
            "implement", "write a function", "write a method",
            "write a class", "code review", "fix this code",
        ]
        let hasCodeSignal = signals.contains { text.contains($0) }
        let hasCodeFences = original.contains("```")
        return hasCodeSignal || hasCodeFences
    }

    func matchesReasoning(_ text: String) -> Bool {
        let signals = [
            "explain why", "compare", "analyze", "analyse", "evaluate",
            "pros and cons", "step by step", "reasoning",
            "think through", "trade-offs", "tradeoffs",
        ]
        return signals.contains { text.contains($0) }
    }

    func matchesLongGeneration(_ text: String) -> Bool {
        let signals = [
            "write an essay", "article about", "2000 words", "2000-word",
            "detailed guide", "comprehensive", "in-depth",
            "long form", "write a report",
        ]
        return signals.contains { text.contains($0) }
    }

    func matchesShortGeneration(_ text: String) -> Bool {
        let signals = [
            "write a poem", "write a haiku", "generate a",
            "create a short", "draft a",
        ]
        return signals.contains { text.contains($0) }
    }

    func classifyComplexity(
        inputTokens: Int,
        task: DetectedTask,
        promptText: String
    ) -> ComplexityTier {
        let tokenComplexity: ComplexityTier
        switch inputTokens {
        case ..<20: tokenComplexity = .trivial
        case 20..<100: tokenComplexity = .simple
        case 100..<500: tokenComplexity = .moderate
        default: tokenComplexity = .complex
        }

        let taskComplexity: ComplexityTier
        switch task {
        case .classification: taskComplexity = .trivial
        case .extraction, .translation, .summarization: taskComplexity = .simple
        case .shortGeneration, .conversation: taskComplexity = .simple
        case .structuredOutput: taskComplexity = .moderate
        case .longGeneration, .codeGeneration: taskComplexity = .complex
        case .reasoning: taskComplexity = .complex
        }

        // Use the higher of the two signals
        return max(tokenComplexity, taskComplexity)
    }

    func estimateOutputTokens(task: DetectedTask, inputTokens: Int) -> Int {
        switch task {
        case .classification: return 30
        case .extraction: return 125
        case .translation: return Int(Double(inputTokens) * 1.2)
        case .summarization: return max(Int(Double(inputTokens) * 0.3), 50)
        case .shortGeneration: return 300
        case .longGeneration: return 2500
        case .codeGeneration: return 1100
        case .reasoning: return 1250
        case .conversation: return 300
        case .structuredOutput: return 550
        }
    }

    func buildCostEstimates(
        providers: [any AIProvider],
        inputTokens: Int,
        outputTokens: Int
    ) -> [ProviderID: Double] {
        var estimates: [ProviderID: Double] = [:]
        for provider in providers {
            let caps = provider.capabilities
            let inputCost = (caps.costPerMillionInputTokens ?? 0) / 1_000_000 * Double(inputTokens)
            let outputCost = (caps.costPerMillionOutputTokens ?? 0) / 1_000_000 * Double(outputTokens)
            estimates[provider.id] = inputCost + outputCost
        }
        return estimates
    }
}

/// The result of analysing a request's content and requirements
public struct RequestAnalysis: Sendable, Equatable {
    public let complexity: ComplexityTier
    public let detectedTask: DetectedTask
    public let estimatedInputTokens: Int
    public let estimatedOutputTokens: Int
    public let requiresReasoning: Bool
    public let costEstimates: [ProviderID: Double]

    public init(
        complexity: ComplexityTier,
        detectedTask: DetectedTask,
        estimatedInputTokens: Int,
        estimatedOutputTokens: Int,
        requiresReasoning: Bool,
        costEstimates: [ProviderID: Double]
    ) {
        self.complexity = complexity
        self.detectedTask = detectedTask
        self.estimatedInputTokens = estimatedInputTokens
        self.estimatedOutputTokens = estimatedOutputTokens
        self.requiresReasoning = requiresReasoning
        self.costEstimates = costEstimates
    }
}

public enum ComplexityTier: Int, Sendable, Comparable, Equatable {
    case trivial = 0
    case simple = 1
    case moderate = 2
    case complex = 3
    case expert = 4

    public static func < (lhs: ComplexityTier, rhs: ComplexityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum DetectedTask: String, Sendable, Equatable, Codable, Hashable {
    case classification
    case extraction
    case translation
    case summarization
    case shortGeneration
    case longGeneration
    case codeGeneration
    case reasoning
    case conversation
    case structuredOutput
}
