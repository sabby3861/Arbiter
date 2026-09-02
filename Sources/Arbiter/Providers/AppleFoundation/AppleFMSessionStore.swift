// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Caches `LanguageModelSession`s across the turns of a conversation so Apple's KV cache
/// survives, instead of rebuilding the whole transcript on every call.
///
/// An `actor` because the cache is mutable shared state. Note that it serialises *lookup*,
/// not generation: two turns of one conversation can still overlap, which the provider
/// catches with `isResponding` and Apple catches with `concurrentRequests`.
actor AppleFMSessionStore {
    /// Conversations kept alive at once. Sessions hold model state, so this is bounded.
    static let defaultCapacity = 8

    private struct CacheEntry {
        let session: any FMSessionRunning
        let identity: String
    }

    private let capacity: Int
    private var entries: [String: CacheEntry] = [:]
    /// Least-recently-used first.
    private var order: [String] = []

    init(capacity: Int = AppleFMSessionStore.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Returns a session that already holds `transcript`, reusing a cached one when possible.
    ///
    /// Reuse is verified rather than bookkept: the cached session's own transcript
    /// fingerprint must equal the fingerprint of the history being requested. If Apple
    /// normalises entries so a round-trip differs, reuse simply never triggers and the
    /// session is rebuilt — slower, never wrong.
    ///
    /// `identity` guards the fields baked into a session at construction (model use case,
    /// guardrails, adapter and, from F7b, tools). Those cannot change afterwards, so a
    /// mismatch must discard the session rather than silently run the old configuration.
    func session(
        conversationID: String?,
        transcript: FMTranscript,
        identity: String,
        make: @Sendable () throws -> any FMSessionRunning
    ) throws -> any FMSessionRunning {
        guard let conversationID else {
            // Stateless: no caching requested.
            return try make()
        }

        if let cached = entries[conversationID],
           cached.identity == identity,
           cached.session.transcriptFingerprint == transcript.fingerprint {
            touch(conversationID)
            return cached.session
        }

        let session = try make()
        entries[conversationID] = CacheEntry(session: session, identity: identity)
        touch(conversationID)
        evictIfNeeded()
        return session
    }

    /// Drops a conversation's session, so the next turn rebuilds from the transcript.
    func discard(conversationID: String) {
        entries[conversationID] = nil
        order.removeAll { $0 == conversationID }
    }

    /// The live session for a conversation, if one is cached. Feedback reporting (F7c)
    /// needs the exact session that produced a response.
    func cachedSession(for conversationID: String) -> (any FMSessionRunning)? {
        entries[conversationID]?.session
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }
}
