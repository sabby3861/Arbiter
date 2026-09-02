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

    /// A summarising retry that this conversation has already paid for.
    ///
    /// `original` is what the transcript builder produced from the request on the turn that
    /// overflowed; `condensed` is what the model was actually given instead. Keeping both
    /// is what lets a later turn — which rebuilds the *full* history from a request that
    /// has only grown — recognise the part that was already condensed and reuse the result.
    struct Condensation: Sendable, Equatable {
        let original: FMTranscript
        let condensed: FMTranscript
    }

    /// One conversation's state. Session and condensation share a cache slot because they
    /// describe the same conversation and should age out together.
    private struct CacheEntry {
        var session: (any FMSessionRunning)?
        var identity: String?
        var condensation: Condensation?

        var isEmpty: Bool { session == nil && condensation == nil }
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
    /// guardrails, adapter and tools). Those cannot change afterwards, so a mismatch must
    /// discard the session rather than silently run the old configuration.
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

        if let cached = entries[conversationID]?.session,
           entries[conversationID]?.identity == identity,
           cached.transcriptFingerprint == transcript.fingerprint {
            touch(conversationID)
            return cached
        }

        let session = try make()
        var entry = entries[conversationID] ?? CacheEntry()
        entry.session = session
        entry.identity = identity
        entries[conversationID] = entry
        touch(conversationID)
        evictIfNeeded()
        return session
    }

    /// Drops a conversation's *session*, so the next turn rebuilds from the transcript.
    ///
    /// The condensation record deliberately survives: a session is discarded precisely when
    /// its history overflowed, which is the moment that record becomes worth keeping.
    func discard(conversationID: String) {
        guard var entry = entries[conversationID] else { return }
        entry.session = nil
        entry.identity = nil
        if entry.isEmpty {
            entries[conversationID] = nil
            order.removeAll { $0 == conversationID }
        } else {
            entries[conversationID] = entry
            // A conversation is discarded precisely when it overflowed, which is when its
            // surviving record is worth most; leaving it at its old LRU position would make
            // it likelier to be evicted than one that never overflowed at all.
            touch(conversationID)
        }
    }

    /// The live session for a conversation, if one is cached. Feedback reporting needs the
    /// exact session that produced a response.
    func cachedSession(for conversationID: String) -> (any FMSessionRunning)? {
        entries[conversationID]?.session
    }

    /// Records that `original` was condensed to `condensed` for this conversation.
    ///
    /// Replaces any earlier record rather than accumulating: `original` is always the
    /// pre-adoption transcript for the turn that just overflowed, so each record maps the
    /// newest full history onto the newest condensed one, and repeated overflows compose.
    func recordCondensation(
        conversationID: String,
        original: FMTranscript,
        condensed: FMTranscript
    ) {
        var entry = entries[conversationID] ?? CacheEntry()
        entry.condensation = Condensation(original: original, condensed: condensed)
        entries[conversationID] = entry
        touch(conversationID)
        evictIfNeeded()
    }

    /// Substitutes a previously condensed prefix into a freshly built transcript.
    ///
    /// Without this, a summarising retry would be spent again on every subsequent turn: the
    /// request keeps the full history, so the builder keeps producing the transcript that
    /// already did not fit. When the recorded `original` is still a prefix of what was just
    /// built, the turns after it are appended to the condensed form instead — which is also
    /// exactly the history the retry's cached session holds, so session reuse falls out.
    ///
    /// Returns `transcript` unchanged when there is no record, or when the record no longer
    /// matches — a caller that edited or trimmed its own history has described a different
    /// conversation, and replaying a summary of turns it removed would be wrong.
    func adopted(conversationID: String?, transcript: FMTranscript) -> FMTranscript {
        guard let conversationID,
              let condensation = entries[conversationID]?.condensation
        else { return transcript }

        let original = condensation.original.entries
        guard transcript.entries.count >= original.count,
              Array(transcript.entries.prefix(original.count)) == original
        else { return transcript }

        touch(conversationID)
        return FMTranscript(
            entries: condensation.condensed.entries + transcript.entries.dropFirst(original.count)
        )
    }

    /// The condensation recorded for a conversation, if any. Test seam.
    func condensation(for conversationID: String) -> Condensation? {
        entries[conversationID]?.condensation
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
