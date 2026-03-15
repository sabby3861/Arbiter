// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Plans token allocation across input and output to fit within
/// provider context windows.
///
/// Prevents the #1 production failure: requests that exceed the
/// context window and either fail or silently truncate.
///
/// ```swift
/// let planner = TokenBudgetPlanner()
/// let check = planner.fits(request: request, provider: capabilities)
/// switch check {
/// case .fits(let remaining):
///     print("Room for \(remaining) more tokens")
/// case .exceeds(let overage, let suggestion):
///     print("Over by \(overage) tokens — \(suggestion)")
/// }
/// ```
public struct TokenBudgetPlanner: Sendable {

    private static let defaultOutputReservation = 1024
    private static let minimumUsableOutputTokens = 256

    public init() {}

    public func fits(
        request: AIRequest,
        provider: ProviderCapabilities
    ) -> BudgetCheck {
        let inputTokens = TokenEstimator.estimateTokens(for: request.messages)
        let systemTokens = request.systemPrompt.map {
            TokenEstimator.estimateTokens(for: $0)
        } ?? 0
        let outputReservation = request.maxTokens ?? Self.defaultOutputReservation
        let totalNeeded = inputTokens + systemTokens + outputReservation
        let maxContext = provider.maxContextTokens

        if totalNeeded <= maxContext {
            return .fits(remaining: maxContext - totalNeeded)
        }

        let overage = totalNeeded - maxContext
        let suggestion = buildSuggestion(
            overage: overage,
            outputReservation: outputReservation,
            inputTokens: inputTokens,
            systemTokens: systemTokens,
            maxContext: maxContext,
            messageCount: request.messages.count
        )

        return .exceeds(by: overage, suggestion: suggestion)
    }

    public func trimToFit(
        messages: [Message],
        maxTokens: Int,
        reserveForOutput: Int = 1024
    ) -> [Message] {
        guard !messages.isEmpty else { return [] }

        let systemMessage: Message? = messages.first?.role == .system
            ? messages.first : nil
        let lastMessage = messages.last

        guard let last = lastMessage else { return [] }

        if messages.count == 1 {
            return [last]
        }

        let systemTokens = systemMessage.map {
            tokenCount(for: $0)
        } ?? 0
        let lastTokens = tokenCount(for: last)
        let availableBudget = maxTokens - reserveForOutput
            - systemTokens - lastTokens

        if availableBudget <= 0 {
            return compactArray([systemMessage, last])
        }

        let middleStart = systemMessage != nil ? 1 : 0
        let middleEnd = messages.count - 1
        guard middleStart < middleEnd else {
            return compactArray([systemMessage, last])
        }

        let middleMessages = messages[middleStart..<middleEnd]
        var kept: [Message] = []
        var usedTokens = 0

        for message in middleMessages.reversed() {
            let cost = tokenCount(for: message)
            if usedTokens + cost > availableBudget { break }
            kept.append(message)
            usedTokens += cost
        }
        kept.reverse()

        var result: [Message] = []
        if let sys = systemMessage { result.append(sys) }
        result.append(contentsOf: kept)
        result.append(last)
        return result
    }
}

private extension TokenBudgetPlanner {
    func tokenCount(for message: Message) -> Int {
        if let text = message.content.text {
            return TokenEstimator.estimateTokens(for: text)
        }
        return 100
    }

    func buildSuggestion(
        overage: Int,
        outputReservation: Int,
        inputTokens: Int,
        systemTokens: Int,
        maxContext: Int,
        messageCount: Int
    ) -> BudgetSuggestion {
        let reducedOutput = outputReservation - overage
        if reducedOutput >= Self.minimumUsableOutputTokens {
            return .reduceMaxTokens(to: reducedOutput)
        }

        let availableForMessages = maxContext - systemTokens
            - Self.defaultOutputReservation
        let avgTokensPerMessage = max(inputTokens / max(messageCount, 1), 1)
        let keepCount = max(availableForMessages / avgTokensPerMessage, 2)

        return .trimOldMessages(keepLast: keepCount)
    }

    func compactArray(_ items: [Message?]) -> [Message] {
        items.compactMap { $0 }
    }
}

public enum BudgetCheck: Sendable, Equatable {
    case fits(remaining: Int)
    case exceeds(by: Int, suggestion: BudgetSuggestion)
}

public enum BudgetSuggestion: Sendable, Equatable {
    case trimOldMessages(keepLast: Int)
    case reduceMaxTokens(to: Int)
    case useProviderWithLargerContext(ProviderID)
}
