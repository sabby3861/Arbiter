// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "ToolLoop")

/// One tool call and what came of it.
public struct ToolInvocation: Sendable, Equatable {
    /// The call the model made.
    public let call: ToolCall
    /// What the model was told in return — including the text describing a failure or a
    /// denial, because that is what the model actually reads.
    public let result: ToolResult
    /// Which round of the loop this belonged to, counting from 0.
    public let round: Int
    /// The human's answer, when the tool asked for one.
    public let approval: ToolApprovalDecision?
    /// Whether this call was served from an earlier identical call in the same run rather
    /// than executed again. See ``ToolContext/idempotencyKey`` for when that happens.
    public let wasDeduplicated: Bool
    /// Whether the tool threw or timed out.
    public let failed: Bool

    public init(
        call: ToolCall,
        result: ToolResult,
        round: Int,
        approval: ToolApprovalDecision? = nil,
        wasDeduplicated: Bool = false,
        failed: Bool = false
    ) {
        self.call = call
        self.result = result
        self.round = round
        self.approval = approval
        self.wasDeduplicated = wasDeduplicated
        self.failed = failed
    }
}

/// The outcome of ``Arbiter/run(_:tools:maxToolRounds:options:)-([Message],_,_,_)``.
public struct RunResult: Sendable {
    /// The model's last response — the answer, unless the run stopped at the round limit.
    public let response: AIResponse
    /// The conversation as the model saw it, including the assistant tool-call turns and
    /// the tool-result turns the loop appended. Feed it back in to continue the exchange —
    /// with one exception: when ``stoppedAtRoundLimit`` is set it ends on an assistant
    /// tool-call turn whose results were never produced, and providers reject a tool call
    /// with no answer. Answer those calls or drop that turn before sending it on.
    public let messages: [Message]
    /// How many rounds of tool execution ran.
    public let rounds: Int
    /// Every tool call the run executed, in the order it completed.
    public let invocations: [ToolInvocation]
    /// Whether the loop stopped because it hit `maxToolRounds` with the model still asking
    /// for tools. When `true`, ``response`` is a tool-call turn, not an answer, and
    /// ``messages`` is not directly replayable.
    public let stoppedAtRoundLimit: Bool
    /// Tokens across every round, when the providers reported them.
    public let totalUsage: TokenUsage?

    /// The final answer's text.
    public var content: String { response.content }

    public init(
        response: AIResponse,
        messages: [Message],
        rounds: Int,
        invocations: [ToolInvocation],
        stoppedAtRoundLimit: Bool,
        totalUsage: TokenUsage?
    ) {
        self.response = response
        self.messages = messages
        self.rounds = rounds
        self.invocations = invocations
        self.stoppedAtRoundLimit = stoppedAtRoundLimit
        self.totalUsage = totalUsage
    }
}

/// What ``Arbiter/runStream(_:tools:maxToolRounds:options:)-([Message],_,_,_)`` reports as the run proceeds.
public enum RunEvent: Sendable {
    /// A fragment of the model's text, as it arrives.
    case textDelta(String)
    /// A call the model made, about to be executed.
    case toolCallStarted(ToolCall)
    /// A call is suspended waiting on ``Arbiter/approve(_:)`` or ``Arbiter/deny(_:reason:)``.
    case approvalRequested(ToolApprovalRequest)
    /// What a call returned to the model.
    case toolResult(ToolResult)
    /// A round of tool execution finished; the next model turn follows.
    case roundCompleted(index: Int)
    /// The run is over. Always the last event.
    case finished(RunResult)
}

/// A tool call that ran past its tool's ``ArbiterTool/timeout``.
struct ToolTimedOut: Error, Sendable {
    let toolName: String
    let duration: Duration

    var localizedDescription: String { "timed out after \(duration)" }
}

/// Runs tool calls for one `run`, applying concurrency, timeouts, approval and reporting
/// identically whether the calls came back from a cloud provider for the loop to execute,
/// or were invoked inside an Apple Foundation Models session.
///
/// Concurrency is the one thing that cannot carry over to the Apple path: the session calls
/// its tools itself, one at a time, so ``ArbiterTool/isConcurrencySafe`` has nothing to
/// schedule there.
actor ToolExecutor {
    private let tools: [String: any ArbiterTool]
    private let approvals: ToolApprovalRegistry
    private let emit: @Sendable (RunEvent) -> Void
    /// Results of executed calls, keyed by ``ToolIdempotency``.
    ///
    /// The key covers the call id as well as the arguments, so this serves *the same call*
    /// arriving twice — a turn re-sent by a retry, or a provider replaying one — and never
    /// suppresses a fresh call the model deliberately made again. Cloud providers mint a
    /// new id per call, so on that path it only ever fires on a genuine repeat.
    private var memo: [String: String] = [:]
    private var log: [ToolInvocation] = []

    init(
        tools: [any ArbiterTool],
        approvals: ToolApprovalRegistry,
        emit: @escaping @Sendable (RunEvent) -> Void = { _ in }
    ) {
        self.tools = Dictionary(tools.map { ($0.definition.name, $0) }, uniquingKeysWith: { _, last in last })
        self.approvals = approvals
        self.emit = emit
    }

    /// Every invocation this executor has run, in completion order.
    var invocations: [ToolInvocation] { log }

    /// Execute one turn's calls, returning their results in the order the model asked.
    ///
    /// Concurrency-safe calls run together in a task group; a call whose tool is not
    /// concurrency-safe runs on its own, and the calls listed around it keep their relative
    /// order, so a tool that mutates shared state never overlaps another tool.
    func execute(_ calls: [ToolCall], round: Int) async throws -> [ToolInvocation] {
        var results: [Int: ToolInvocation] = [:]
        var batch: [(index: Int, call: ToolCall)] = []

        for (index, call) in calls.enumerated() {
            if tools[call.name]?.isConcurrencySafe ?? true {
                batch.append((index, call))
                continue
            }
            // A tool that is not concurrency-safe runs alone: everything queued ahead of it
            // finishes first, and the calls after it start only once it is done.
            for (batchIndex, invocation) in try await runConcurrently(batch, round: round) {
                results[batchIndex] = invocation
            }
            batch = []
            results[index] = try await run(call, round: round)
        }
        for (batchIndex, invocation) in try await runConcurrently(batch, round: round) {
            results[batchIndex] = invocation
        }

        return calls.indices.compactMap { results[$0] }
    }

    private func runConcurrently(
        _ pending: [(index: Int, call: ToolCall)],
        round: Int
    ) async throws -> [(Int, ToolInvocation)] {
        guard !pending.isEmpty else { return [] }
        if pending.count == 1 {
            return [(pending[0].index, try await run(pending[0].call, round: round))]
        }
        return try await withThrowingTaskGroup(of: (Int, ToolInvocation).self) { group in
            for (index, call) in pending {
                group.addTask { (index, try await self.run(call, round: round)) }
            }
            var collected: [(Int, ToolInvocation)] = []
            for try await item in group {
                collected.append(item)
            }
            return collected
        }
    }

    /// Execute a single call arriving from inside an Apple Foundation Models session, where
    /// the framework supplies arguments and expects the text the model reads back.
    ///
    /// Apple gives a tool call no id, so one is derived from the tool and its arguments
    /// rather than minted fresh. That is what makes the idempotency key mean anything here:
    /// the session runs its tools *inside* `respond()`, so anything that re-sends the turn —
    /// a retry on `.busy`, a quality retry, overflow recovery — would otherwise repeat every
    /// side effect under a new key. The cost is that a model calling one tool twice with
    /// identical arguments in a single turn is served the first result.
    func executeBridged(name: String, arguments: JSONValue, round: Int) async throws -> String {
        let call = ToolCall(
            id: "fm-\(ToolIdempotency.key(callID: name, arguments: arguments).prefix(16))",
            name: name,
            arguments: arguments
        )
        return try await run(call, round: round).result.content
    }

    private func run(_ call: ToolCall, round: Int) async throws -> ToolInvocation {
        try Task.checkCancellation()
        emit(.toolCallStarted(call))

        guard let tool = tools[call.name] else {
            // Reported to the model rather than thrown: a call to a tool that does not
            // exist is the model's mistake, and it can recover from being told.
            return record(ToolInvocation(
                call: call,
                result: ToolResult(
                    toolCallId: call.id, name: call.name,
                    content: "Error: no tool named '\(call.name)' is available."
                ),
                round: round,
                failed: true
            ))
        }

        let key = ToolIdempotency.key(callID: call.id, arguments: call.arguments)
        if let cached = memo[key] {
            return record(ToolInvocation(
                call: call,
                result: ToolResult(toolCallId: call.id, name: call.name, content: cached),
                round: round,
                wasDeduplicated: true
            ))
        }

        var approval: ToolApprovalDecision?
        do {
            var output = try await invoke(tool, call: call, key: key, round: round, isApproved: false)

            if case .requiresApproval(let payload) = output {
                let request = ToolApprovalRequest(
                    id: call.id, toolName: call.name, payload: payload, arguments: call.arguments
                )
                emit(.approvalRequested(request))
                let decision = await approvals.wait(for: request)
                approval = decision
                switch decision {
                case .denied(let reason):
                    // Deliberately not memoised: a denial is a decision about this moment,
                    // and an identical later call deserves to be asked again.
                    let explanation = reason.map { ": \($0)" } ?? "."
                    return record(ToolInvocation(
                        call: call,
                        result: ToolResult(
                            toolCallId: call.id, name: call.name,
                            content: "The user denied this tool call\(explanation)"
                        ),
                        round: round,
                        approval: decision
                    ))
                case .approved:
                    try Task.checkCancellation()
                    output = try await invoke(tool, call: call, key: key, round: round, isApproved: true)
                }
            }

            guard case .content(let text) = output else {
                // An approved call that asks for approval again would suspend forever.
                throw ArbiterError.invalidRequest(
                    reason: "Tool '\(call.name)' asked for approval again after being approved."
                )
            }

            memo[key] = text
            return record(ToolInvocation(
                call: call,
                result: ToolResult(toolCallId: call.id, name: call.name, content: text),
                round: round,
                approval: approval
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A failing tool is reported to the model, which can retry or explain itself.
            // Not memoised: the next attempt should really run.
            logger.debug("Tool \(call.name) failed: \(error.localizedDescription)")
            return record(ToolInvocation(
                call: call,
                result: ToolResult(
                    toolCallId: call.id, name: call.name,
                    content: "Tool '\(call.name)' failed: \(Self.describe(error))"
                ),
                round: round,
                approval: approval,
                failed: true
            ))
        }
    }

    /// One attempt at the tool, bounded by its own timeout.
    ///
    /// The deadline covers the tool body only. Waiting for a human to approve a call is
    /// deliberately outside it — a person is not late — and is bounded by cancelling the
    /// run instead.
    private func invoke(
        _ tool: any ArbiterTool,
        call: ToolCall,
        key: String,
        round: Int,
        isApproved: Bool
    ) async throws -> ToolOutput {
        let context = ToolContext(
            callID: call.id,
            toolName: call.name,
            idempotencyKey: key,
            round: round,
            isApproved: isApproved
        )
        let arguments = call.arguments
        guard let timeout = tool.timeout else {
            return try await tool.call(arguments, context: context)
        }
        return try await withThrowingTaskGroup(of: ToolOutput.self) { group in
            group.addTask { try await tool.call(arguments, context: context) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ToolTimedOut(toolName: call.name, duration: timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ToolTimedOut(toolName: call.name, duration: timeout)
            }
            return first
        }
    }

    @discardableResult
    private func record(_ invocation: ToolInvocation) -> ToolInvocation {
        log.append(invocation)
        emit(.toolResult(invocation.result))
        return invocation
    }

    private static func describe(_ error: any Error) -> String {
        if let timeout = error as? ToolTimedOut { return timeout.localizedDescription }
        if let arbiter = error as? ArbiterError { return arbiter.errorDescription ?? "\(arbiter)" }
        return error.localizedDescription
    }
}
