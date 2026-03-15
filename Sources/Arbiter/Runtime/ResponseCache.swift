// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "ResponseCache")

/// Cache persistence strategy
public enum CachePersistence: Sendable {
    case memory
    case disk(directory: URL? = nil)

    var isDisk: Bool {
        if case .disk = self { return true }
        return false
    }
}

/// In-memory (or disk-backed) cache for AI responses, keyed by prompt content and provider.
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
    private let persistence: CachePersistence
    private let cacheDirectory: URL?

    /// Create a response cache
    /// - Parameters:
    ///   - maxEntries: Maximum number of cached responses
    ///   - ttl: Time-to-live for each cache entry
    ///   - persistence: Storage strategy (.memory or .disk)
    public init(
        maxEntries: Int = 1000,
        ttl: Duration = .seconds(600),
        persistence: CachePersistence = .memory
    ) {
        self.maxEntries = maxEntries
        self.ttlSeconds = Double(ttl.components.seconds)
            + Double(ttl.components.attoseconds) / 1e18
        self.persistence = persistence

        if case .disk(let customDirectory) = persistence {
            let dir = customDirectory ?? FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("com.arbiter.cache", isDirectory: true)
            self.cacheDirectory = dir
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        } else {
            self.cacheDirectory = nil
        }
    }

    /// Look up a cached response for the given request and provider
    public func get(request: AIRequest, provider: ProviderID) -> AIResponse? {
        let key = CacheKey(request: request, provider: provider)

        if let entry = entries[key] {
            let elapsed = Date().timeIntervalSince(entry.storedAt)
            if elapsed > ttlSeconds {
                entries.removeValue(forKey: key)
                logger.debug("Cache miss (expired) for \(provider.rawValue)")
                return nil
            }
            logger.debug("Cache hit for \(provider.rawValue)")
            return entry.response
        }

        if persistence.isDisk, let response = loadFromDisk(key: key) {
            entries[key] = CacheEntry(response: response, storedAt: Date())
            return response
        }

        return nil
    }

    /// Store a response in the cache
    public func set(request: AIRequest, provider: ProviderID, response: AIResponse) {
        evictIfNeeded()
        let key = CacheKey(request: request, provider: provider)
        entries[key] = CacheEntry(response: response, storedAt: Date())
        logger.debug("Cached response for \(provider.rawValue) (\(self.entries.count)/\(self.maxEntries))")

        if persistence.isDisk {
            saveToDisk(key: key, response: response)
        }
    }

    /// Remove all cached entries
    public func clear() {
        entries.removeAll()
        if persistence.isDisk, let dir = cacheDirectory {
            try? FileManager.default.removeItem(at: dir)
            ensureCacheDirectoryExists()
        }
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
            if persistence.isDisk {
                deleteFromDisk(key: entry.key)
            }
        }
    }

    func ensureCacheDirectoryExists() {
        guard let dir = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func diskPath(for key: CacheKey) -> URL? {
        let hashString = String(key.promptHash, radix: 16, uppercase: false)
        return cacheDirectory?.appendingPathComponent("\(hashString)_\(key.provider.rawValue).json")
    }

    func saveToDisk(key: CacheKey, response: AIResponse) {
        guard let path = diskPath(for: key) else { return }
        let diskEntry = DiskCacheEntry(
            id: response.id,
            content: response.content,
            model: response.model,
            provider: response.provider.rawValue,
            storedAt: Date()
        )
        do {
            let data = try JSONEncoder().encode(diskEntry)
            try data.write(to: path, options: .atomic)
        } catch {
            logger.debug("Failed to write cache to disk: \(error.localizedDescription)")
        }
    }

    func loadFromDisk(key: CacheKey) -> AIResponse? {
        guard let path = diskPath(for: key),
              FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: path)
            let entry = try JSONDecoder().decode(DiskCacheEntry.self, from: data)
            let elapsed = Date().timeIntervalSince(entry.storedAt)
            if elapsed > ttlSeconds {
                try? FileManager.default.removeItem(at: path)
                return nil
            }
            guard let providerID = ProviderID(rawValue: entry.provider) else { return nil }
            return AIResponse(
                id: entry.id,
                content: entry.content,
                model: entry.model,
                provider: providerID
            )
        } catch {
            logger.debug("Failed to read cache from disk: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteFromDisk(key: CacheKey) {
        guard let path = diskPath(for: key) else { return }
        try? FileManager.default.removeItem(at: path)
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
        hasher.combine(request.topP)
        if let tools = request.tools {
            for tool in tools {
                hasher.combine(tool.name)
            }
        }
        self.promptHash = hasher.finalize()
        self.provider = provider
    }
}

private struct CacheEntry: Sendable {
    let response: AIResponse
    let storedAt: Date
}

private struct DiskCacheEntry: Codable, Sendable {
    let id: String
    let content: String
    let model: String
    let provider: String
    let storedAt: Date
}
