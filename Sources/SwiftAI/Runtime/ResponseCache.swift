// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "ResponseCache")

/// In-memory cache for AI responses, keyed by prompt content and provider.
///
/// Reduces API costs by returning cached responses for identical prompts.
/// Entries expire after a configurable TTL and the cache enforces a maximum
/// entry count, evicting oldest entries first.
///
/// ```swift
/// let cache = ResponseCache(maxEntries: 500, ttl: .seconds(300))
/// if let cached = await cache.get(request: request, provider: .anthropic) {
///     return cached
/// }
/// ```
public actor ResponseCache {
    private var entries: [CacheKey: CacheEntry] = [:]
    private let maxEntries: Int
    private let ttlSeconds: Double

    /// Create a response cache
    /// - Parameters:
    ///   - maxEntries: Maximum number of cached responses
    ///   - ttl: Time-to-live for each cache entry
    public init(maxEntries: Int = 1000, ttl: Duration = .seconds(600)) {
        self.maxEntries = maxEntries
        self.ttlSeconds = Double(ttl.components.seconds)
            + Double(ttl.components.attoseconds) / 1e18
    }

    /// Look up a cached response for the given request and provider
    public func get(request: AIRequest, provider: ProviderID) -> AIResponse? {
        let key = CacheKey(request: request, provider: provider)
        guard let entry = entries[key] else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(entry.storedAt)
        if elapsed > ttlSeconds {
            entries.removeValue(forKey: key)
            logger.debug("Cache miss (expired) for \(provider.rawValue)")
            return nil
        }

        logger.debug("Cache hit for \(provider.rawValue)")
        return entry.response
    }

    /// Store a response in the cache
    public func set(request: AIRequest, provider: ProviderID, response: AIResponse) {
        evictIfNeeded()
        let key = CacheKey(request: request, provider: provider)
        entries[key] = CacheEntry(response: response, storedAt: Date())
        logger.debug("Cached response for \(provider.rawValue) (\(self.entries.count)/\(self.maxEntries))")
    }

    /// Remove all cached entries
    public func clear() {
        entries.removeAll()
    }

    /// Number of entries currently in the cache
    public var count: Int { entries.count }
}

private extension ResponseCache {
    func evictIfNeeded() {
        guard entries.count >= maxEntries else { return }
        let sortedKeys = entries.sorted { lhs, rhs in
            lhs.value.storedAt < rhs.value.storedAt
        }
        let evictCount = entries.count - maxEntries + 1
        for entry in sortedKeys.prefix(evictCount) {
            entries.removeValue(forKey: entry.key)
        }
    }
}

private struct CacheKey: Hashable, Sendable {
    let promptHash: Int
    let provider: ProviderID

    init(request: AIRequest, provider: ProviderID) {
        var hasher = Hasher()
        for message in request.messages {
            hasher.combine(message.role)
            if let text = message.content.text {
                hasher.combine(text)
            }
        }
        hasher.combine(request.model)
        hasher.combine(request.systemPrompt)
        hasher.combine(request.temperature)
        hasher.combine(request.maxTokens)
        self.promptHash = hasher.finalize()
        self.provider = provider
    }
}

private struct CacheEntry: Sendable {
    let response: AIResponse
    let storedAt: Date
}
