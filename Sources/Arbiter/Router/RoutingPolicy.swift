// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// How the Smart Router selects a provider for each request.
public enum RoutingStrategy: Sendable {
    /// Always use a specific provider
    case fixed(ProviderID)
    /// Try providers in explicit order, fail over to next
    case priority([ProviderID])
    /// Full intelligent routing — the default
    case smart
    /// Minimize cost, prefer free/cheap providers
    case costOptimized
    /// Prefer on-device, cloud only if explicitly allowed
    case privacyFirst
    /// Use the most capable provider available
    case qualityFirst
    /// Use the fastest provider for the task
    case latencyOptimized
}

/// Configuration for how requests are routed across providers.
///
/// ```swift
/// let ai = Arbiter {
///     $0.cloud(.anthropic(from: .keychain))
///     $0.local(OllamaProvider())
///     $0.routing(.smart)
/// }
/// ```
public struct RoutingPolicy: Sendable {
    public var strategy: RoutingStrategy
    public var fallbackEnabled: Bool
    public var maxRetries: Int
    public var forceLocal: Bool
    public var forceCloud: Bool
    public var privacyTags: Set<RequestTag>

    public init(
        strategy: RoutingStrategy = .smart,
        fallbackEnabled: Bool = true,
        maxRetries: Int = 2,
        forceLocal: Bool = false,
        forceCloud: Bool = false,
        privacyTags: Set<RequestTag> = [.private, .health, .financial, .personal]
    ) {
        self.strategy = strategy
        self.fallbackEnabled = fallbackEnabled
        self.maxRetries = maxRetries
        self.forceLocal = forceLocal
        self.forceCloud = forceCloud
        self.privacyTags = privacyTags
    }
}

extension RoutingPolicy {
    /// Try all providers in registration order
    public static let firstAvailable = RoutingPolicy(strategy: .priority([]))

    /// Prefer on-device/local providers, fall back to cloud
    public static let preferLocal = RoutingPolicy(strategy: .privacyFirst)

    /// Prefer cloud providers for quality, fall back to local
    public static let preferCloud = RoutingPolicy(strategy: .qualityFirst)

    /// Full intelligent routing (default)
    public static let smart = RoutingPolicy(strategy: .smart)

    /// Always use a specific provider
    public static func specific(_ provider: ProviderID) -> RoutingPolicy {
        RoutingPolicy(strategy: .fixed(provider))
    }
}
