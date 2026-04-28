// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import Arbiter
import os

private let logger = Logger(subsystem: "com.arbiter.showcase", category: "AppState")

@MainActor
@Observable
final class AppState {
    let ai: Arbiter
    private(set) var log: [LogEntry] = []
    private(set) var isConfigured = false
    private(set) var configuredProviders: [String] = []
    private(set) var providerStats: [String: ProviderStat] = [:]

    struct ProviderStat: Sendable {
        var requests = 0
        var tokens = 0
        var totalCost: Double = 0
        var totalLatency: Double = 0

        var averageLatency: Double {
            requests > 0 ? totalLatency / Double(requests) : 0
        }
    }

    init() {
        let env = ProcessInfo.processInfo.environment
        let (providers, names) = Self.buildProviders(from: env)

        configuredProviders = names
        isConfigured = !providers.isEmpty

        ai = Arbiter { config in
            for provider in providers {
                config.cloud(provider)
            }
            config.routing(.smart)
            config.responseValidation(.enabled)
            config.middleware(LoggingMiddleware())
            config.retry(maxAttempts: 2)
        }

        logger.info("Configured providers: \(names.joined(separator: ", "))")
    }

    func addLog(_ entry: LogEntry) {
        log.insert(entry, at: 0)
    }

    func recordUsage(provider: String, tokens: Int, cost: Double, latency: Double) {
        var stat = providerStats[provider] ?? ProviderStat()
        stat.requests += 1
        stat.tokens += tokens
        stat.totalCost += cost
        stat.totalLatency += latency
        providerStats[provider] = stat
    }

    func clearLog() { log.removeAll() }
    func resetStats() { providerStats.removeAll() }

    static func estimateCost(provider: ProviderID, usage: TokenUsage?) -> Double {
        guard let usage else { return 0 }
        let (inRate, outRate): (Double, Double) = switch provider {
        case .anthropic: (3.0, 15.0)
        case .openAI: (2.5, 10.0)
        case .gemini: (0.5, 1.5)
        default: (0, 0)
        }
        return (Double(usage.inputTokens) * inRate + Double(usage.outputTokens) * outRate) / 1_000_000
    }

    var totalSpend: Double {
        providerStats.values.reduce(0) { $0 + $1.totalCost }
    }

    @available(*, deprecated, message: "Demo uses env var keys; production apps use Keychain")
    private static func buildProviders(
        from env: [String: String]
    ) -> ([any AIProvider], [String]) {
        var providers: [any AIProvider] = []
        var names: [String] = []

        if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty {
            providers.append(AnthropicProvider(apiKey: key))
            names.append("Anthropic")
        }
        if let key = env["OPENAI_API_KEY"], !key.isEmpty {
            providers.append(OpenAIProvider(apiKey: key))
            names.append("OpenAI")
        }
        if let key = env["GEMINI_API_KEY"], !key.isEmpty {
            providers.append(GeminiProvider(apiKey: key))
            names.append("Gemini")
        }

        return (providers, names)
    }
}
