// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// One place that says how a request is guarded, retried and failed over.
///
/// Before this existed the answers were scattered: the budget was checked inside the
/// execute step, privacy and health inside the router, in-provider retry only when
/// fallback happened to be *off*, and the fallback count came from a field called
/// `maxRetries` that never retried anything. The stages below are the order those
/// mechanisms apply in, and every generate and stream path runs through them.
struct ExecutionPolicy: Sendable {
    /// Whether a failed provider may be replaced by the next candidate.
    let fallbackEnabled: Bool
    /// How many *additional* providers may be tried after the first one fails.
    let maxFallbackProviders: Int
    /// In-provider retry for transient failures. `nil` disables it.
    let retry: RetryConfiguration?
    /// Per-attempt deadline, applied inside each retry attempt rather than around them.
    let timeout: Duration?

    /// How many providers this request may touch in total.
    var providerAttemptLimit: Int {
        fallbackEnabled ? max(0, maxFallbackProviders) + 1 : 1
    }

    init(routingPolicy: RoutingPolicy, retry: RetryConfiguration?, timeout: Duration?) {
        self.fallbackEnabled = routingPolicy.fallbackEnabled
        self.maxFallbackProviders = routingPolicy.maxFallbackProviders
        self.retry = retry
        self.timeout = timeout
    }

    /// The order in which the runtime's guards and recovery mechanisms apply.
    ///
    /// Earlier stages decide what later stages ever see: a request the budget guard stops
    /// is never routed, a provider privacy excludes is never scored on health, and a
    /// provider is only replaced once its own retries are spent.
    ///
    /// This list documents that order; the behaviour is in `Arbiter.performGenerate` and
    /// `executeGenerate`, and it is those the `Execution policy` tests exercise.
    static let stages: [ExecutionStage] = ExecutionStage.allCases
}

/// A step of ``ExecutionPolicy``'s precedence, in order.
enum ExecutionStage: Int, Sendable, CaseIterable, Comparable {
    /// Remaining budget narrows the candidates, and the estimated cost is reserved before
    /// the request is sent. A request that cannot be paid for never reaches a provider.
    case budgetGuard
    /// Privacy constraints — the request's tags, detected content and `forceLocal` — remove
    /// providers whose tier is not allowed to see the request.
    case privacy
    /// Health and performance history order what is left, and drop providers currently
    /// reporting as down.
    case health
    /// The selected provider retries its own transient failures. A `Retry-After` the
    /// provider sent is honoured as the delay; everything else backs off exponentially.
    case providerRetry
    /// Only once a provider's retries are spent does the next candidate get the request.
    case providerFallback

    static func < (lhs: ExecutionStage, rhs: ExecutionStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
