// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// A tool call waiting on a human's consent.
///
/// Published on ``Arbiter/pendingApprovals`` when a tool returns
/// ``ToolOutput/requiresApproval(payload:)``. Answer it with ``Arbiter/approve(_:)`` or
/// ``Arbiter/deny(_:reason:)``, passing ``id``.
public struct ToolApprovalRequest: Sendable, Identifiable, Equatable {
    /// The tool call's id — the value to pass to `approve`/`deny`.
    public let id: String
    public let toolName: String
    /// What the tool wants the human to see before deciding.
    public let payload: String
    /// The arguments the model proposed.
    public let arguments: JSONValue
    public let requestedAt: Date

    public init(
        id: String,
        toolName: String,
        payload: String,
        arguments: JSONValue,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.payload = payload
        self.arguments = arguments
        self.requestedAt = requestedAt
    }
}

/// A human's answer to a ``ToolApprovalRequest``.
public enum ToolApprovalDecision: Sendable, Equatable {
    case approved
    case denied(reason: String?)
}

/// Holds the tool calls suspended awaiting consent, and the observers watching for them.
///
/// One registry per ``Arbiter``, so `approve(_:)`/`deny(_:reason:)` can be called from a
/// view while the run is suspended inside `run(_:tools:)`.
actor ToolApprovalRegistry {
    private var pending: [String: ToolApprovalRequest] = [:]
    /// Publication order, so a late observer replays the queue as it was built.
    private var order: [String] = []
    private var waiters: [String: CheckedContinuation<ToolApprovalDecision, Never>] = [:]
    /// Decisions that arrived before anything was waiting on them. Kept so a caller that
    /// pre-approves a known call id does not deadlock the run.
    ///
    /// Bounded: an answer to a call that never comes — a second answer to one already
    /// resolved, or a decision for an id that was cancelled — would otherwise sit here for
    /// the lifetime of the `Arbiter`. Oldest are dropped first.
    private var earlyDecisions: [String: ToolApprovalDecision] = [:]
    private var earlyDecisionOrder: [String] = []
    /// Enough for any plausible pre-approval, small enough to never be a leak.
    private static let maximumEarlyDecisions = 64
    private var observers: [UUID: AsyncStream<ToolApprovalRequest>.Continuation] = [:]

    /// Requests currently awaiting a decision, oldest first.
    var pendingRequests: [ToolApprovalRequest] {
        order.compactMap { pending[$0] }
    }

    /// A stream of approval requests.
    ///
    /// Replays what is already pending before going live, so a view that subscribes after a
    /// run has already suspended still sees the request it has to answer. Each caller gets
    /// its own stream: a single shared one would hand each request to whichever consumer
    /// happened to be first.
    func observe() -> AsyncStream<ToolApprovalRequest> {
        let observerID = UUID()
        let backlog = pendingRequests
        return AsyncStream { continuation in
            for request in backlog {
                continuation.yield(request)
            }
            observers[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    /// Suspend until this request is answered.
    ///
    /// Cancelling the surrounding task resolves the wait as a denial rather than leaving
    /// the run suspended forever; the loop then reports cancellation to its caller.
    func wait(for request: ToolApprovalRequest) async -> ToolApprovalDecision {
        if let early = earlyDecisions.removeValue(forKey: request.id) {
            earlyDecisionOrder.removeAll { $0 == request.id }
            return early
        }
        publish(request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[request.id] = continuation
            }
        } onCancel: {
            Task { await self.resolve(id: request.id, decision: .denied(reason: "Run cancelled")) }
        }
    }

    /// Answer a pending request. Answering an unknown id is remembered, so a decision that
    /// races ahead of the call it answers is not lost.
    func resolve(id: String, decision: ToolApprovalDecision) {
        clearPending(id)
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: decision)
        } else {
            rememberEarly(id, decision)
        }
    }

    private func rememberEarly(_ id: String, _ decision: ToolApprovalDecision) {
        if earlyDecisions[id] == nil {
            earlyDecisionOrder.append(id)
        }
        earlyDecisions[id] = decision
        while earlyDecisionOrder.count > Self.maximumEarlyDecisions {
            let oldest = earlyDecisionOrder.removeFirst()
            earlyDecisions[oldest] = nil
        }
    }

    private func publish(_ request: ToolApprovalRequest) {
        if pending[request.id] == nil {
            order.append(request.id)
        }
        pending[request.id] = request
        for observer in observers.values {
            observer.yield(request)
        }
    }

    private func clearPending(_ id: String) {
        pending[id] = nil
        order.removeAll { $0 == id }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
