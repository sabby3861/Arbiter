// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "ArbiterRun")

public extension Arbiter {
    /// Run an agent loop: send the conversation, execute whatever tools the model calls,
    /// send the results back, and repeat until it answers.
    ///
    /// ```swift
    /// let result = try await ai.run(
    ///     [.user("What's the weather in Paris, and should I take a coat?")],
    ///     tools: [weatherTool]
    /// )
    /// print(result.content)
    /// ```
    ///
    /// Calls of one turn run concurrently unless a tool says it is not
    /// ``ArbiterTool/isConcurrencySafe``. A tool that returns
    /// ``ToolOutput/requiresApproval(payload:)`` suspends the run until
    /// ``approve(_:)`` or ``deny(_:reason:)`` answers it.
    ///
    /// - Parameter messages: the conversation to send. The loop appends the tool-call and
    ///   tool-result turns it runs to a copy, returned as ``RunResult/messages``.
    /// - Parameter tools: the tools the model may call this run. Each is offered to the
    ///   model by its ``ArbiterTool/definition`` and executed by the loop when called.
    /// - Parameter maxToolRounds: how many rounds of tool execution to allow. Reaching it
    ///   ends the run with ``RunResult/stoppedAtRoundLimit`` set rather than looping on. The
    ///   conversation then ends on an unanswered tool-call turn — see
    ///   ``RunResult/messages``.
    /// - Parameter options: per-request overrides — model, token cap, temperature and the
    ///   rest. `nil` uses the defaults the ``Arbiter`` instance was built with.
    ///
    /// - Note: Apple Foundation Models runs tools inside its own session, so a run routed
    ///   there executes the same tools through the same approval, timeout and
    ///   deduplication path but finishes in a single round.
    func run(
        _ messages: [Message],
        tools: [any ArbiterTool],
        maxToolRounds: Int = 8,
        options: RequestOptions? = nil
    ) async throws -> RunResult {
        try await performRun(
            messages: messages, tools: tools, maxToolRounds: maxToolRounds,
            options: options, streaming: false, emit: { _ in }
        )
    }

    /// Run an agent loop from a single prompt.
    func run(
        _ prompt: String,
        tools: [any ArbiterTool],
        maxToolRounds: Int = 8,
        options: RequestOptions? = nil
    ) async throws -> RunResult {
        try await run([.user(prompt)], tools: tools, maxToolRounds: maxToolRounds, options: options)
    }

    /// The streaming form of ``run(_:tools:maxToolRounds:options:)-([Message],_,_,_)``.
    ///
    /// Yields the model's text as it arrives, plus an event for each tool call started,
    /// each approval requested and each result produced, and finishes with
    /// ``RunEvent/finished(_:)`` carrying the same ``RunResult`` the non-streaming form
    /// returns.
    ///
    /// - Note: providers stream an answer's text but not the opaque signature of a
    ///   thinking block, so a streamed run cannot replay extended thinking across rounds
    ///   the way ``run(_:tools:maxToolRounds:options:)-([Message],_,_,_)`` does. Use the non-streaming form
    ///   when thinking is enabled together with tools.
    func runStream(
        _ messages: [Message],
        tools: [any ArbiterTool],
        maxToolRounds: Int = 8,
        options: RequestOptions? = nil
    ) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await performRun(
                        messages: messages, tools: tools, maxToolRounds: maxToolRounds,
                        options: options, streaming: true, emit: { continuation.yield($0) }
                    )
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// The streaming form of ``run(_:tools:maxToolRounds:options:)-(String,_,_,_)``, from a single prompt.
    func runStream(
        _ prompt: String,
        tools: [any ArbiterTool],
        maxToolRounds: Int = 8,
        options: RequestOptions? = nil
    ) -> AsyncThrowingStream<RunEvent, Error> {
        runStream([.user(prompt)], tools: tools, maxToolRounds: maxToolRounds, options: options)
    }

    /// Let a suspended tool call proceed.
    ///
    /// - Parameter id: the ``ToolApprovalRequest/id`` — the model's id for that call.
    func approve(_ id: String) async {
        await approvals.resolve(id: id, decision: .approved)
    }

    /// Refuse a suspended tool call. The model is told, and carries on without it.
    func deny(_ id: String, reason: String? = nil) async {
        await approvals.resolve(id: id, decision: .denied(reason: reason))
    }

    /// Tool calls waiting on a decision, oldest first.
    var pendingApprovalRequests: [ToolApprovalRequest] {
        get async { await approvals.pendingRequests }
    }

    /// A stream of tool calls waiting on a decision.
    ///
    /// Replays what is already pending before going live, so a view that subscribes while a
    /// run is suspended still sees the request it has to answer.
    var pendingApprovals: AsyncStream<ToolApprovalRequest> {
        get async { await approvals.observe() }
    }
}

extension Arbiter {
    func performRun(
        messages: [Message],
        tools: [any ArbiterTool],
        maxToolRounds: Int,
        options: RequestOptions?,
        streaming: Bool,
        emit: @escaping @Sendable (RunEvent) -> Void
    ) async throws -> RunResult {
        guard maxToolRounds >= 0 else {
            throw ArbiterError.invalidRequest(reason: "maxToolRounds must not be negative")
        }
        // Two tools of the same name would be an ambiguous call: the executor could only
        // pick one, while every provider is sent both definitions and rejects the pair.
        let names = tools.map(\.definition.name)
        guard Set(names).count == names.count else {
            throw ArbiterError.invalidRequest(
                reason: "run(_:tools:) was given more than one tool named "
                    + "'\(Dictionary(grouping: names, by: { $0 }).first { $0.value.count > 1 }?.key ?? "")'."
            )
        }
        let executor = ToolExecutor(tools: tools, approvals: approvals, emit: emit)
        let runID = UUID().uuidString

        var conversation = messages
        var rounds = 0
        var stoppedAtRoundLimit = false
        var usage = UsageAccumulator()

        while true {
            try Task.checkCancellation()
            let roundOptions = runOptions(
                base: options, tools: tools, executor: executor, round: rounds, runID: runID
            )
            let response = streaming
                ? try await streamRound(messages: conversation, options: roundOptions, emit: emit)
                : try await performGenerate(messages: conversation, options: roundOptions)
            usage.add(response.usage)

            // The continuation condition is the finish reason, never `toolCalls` being
            // non-empty: Apple Foundation Models executes its tools inside the session and
            // then reports them on a `.complete` response, so branching on the array would
            // run every one of them a second time.
            guard response.finishReason == .toolCall, !response.toolCalls.isEmpty else {
                return RunResult(
                    response: response, messages: conversation + turn(from: response),
                    rounds: rounds, invocations: await executor.invocations,
                    stoppedAtRoundLimit: false, totalUsage: usage.total
                )
            }

            if rounds >= maxToolRounds {
                stoppedAtRoundLimit = true
                logger.debug("Tool loop stopped at the \(maxToolRounds)-round limit")
                return RunResult(
                    response: response, messages: conversation + turn(from: response),
                    rounds: rounds, invocations: await executor.invocations,
                    stoppedAtRoundLimit: stoppedAtRoundLimit, totalUsage: usage.total
                )
            }

            conversation.append(contentsOf: turn(from: response))
            let invocations = try await executor.execute(response.toolCalls, round: rounds)
            conversation.append(
                Message(role: .tool, content: .toolResults(invocations.map(\.result)))
            )
            emit(.roundCompleted(index: rounds))
            rounds += 1
        }
    }

    /// Rebuild the assistant's turn so the next request replays it exactly.
    ///
    /// Thinking blocks come first and keep their opaque signatures: Anthropic requires
    /// them back unchanged when a thinking turn made tool calls, and rejects the request
    /// otherwise.
    ///
    /// A response with nothing in it produces no message at all, rather than an empty text
    /// turn — which is itself rejected by providers that forbid empty content blocks.
    func turn(from response: AIResponse) -> [Message] {
        var parts: [MessageContent] = []
        if !response.thinking.isEmpty {
            parts.append(.thinking(response.thinking))
        }
        if !response.content.isEmpty {
            parts.append(.text(response.content))
        }
        if !response.toolCalls.isEmpty {
            parts.append(.toolCalls(response.toolCalls))
        }
        guard !parts.isEmpty else { return [] }
        return [Message(
            role: .assistant,
            content: parts.count == 1 ? parts[0] : .mixed(parts)
        )]
    }

    /// The options one round is sent with: the tools declared to every provider, plus the
    /// executor bridged into Apple Foundation Models' own tool API.
    func runOptions(
        base: RequestOptions?,
        tools: [any ArbiterTool],
        executor: ToolExecutor,
        round: Int,
        runID: String
    ) -> RequestOptions {
        var options = base ?? RequestOptions()
        let runNames = Set(tools.map(\.definition.name))
        // The run's tools win a name collision with `options.tools`: they are the set the
        // caller just handed this call, and they are the only ones with executors.
        options.tools = tools.map(\.definition)
            + (base?.tools ?? []).filter { !runNames.contains($0.name) }

        guard registeredProviders.contains(where: { $0.id == .appleFoundation }) else {
            return options
        }
        var fmOptions = (base?.providerOptions[.appleFoundation] as? AppleFMOptions) ?? AppleFMOptions()
        let bridged = tools.map { tool in
            AppleFMToolBinding(definition: tool.definition) { arguments in
                try await executor.executeBridged(
                    name: tool.definition.name, arguments: arguments, round: round
                )
            }
        }
        fmOptions.tools = fmOptions.tools.filter { !runNames.contains($0.definition.name) } + bridged
        // A cached session keeps the tools — and therefore the executor closures — it was
        // built with, and `sessionIdentity` cannot see a closure to notice the difference.
        // Reusing one across two runs would report the second run's calls into the first
        // run's log and events, so a run that binds tools gets a session of its own. The
        // cost is Apple's KV cache between turns; the alternative is silently wrong
        // bookkeeping. A tool-free run keeps the caller's conversation untouched.
        if !tools.isEmpty, let conversationID = fmOptions.conversationID {
            fmOptions.conversationID = "\(conversationID)#arbiter-run-\(runID)"
        }
        options.providerOptions[.appleFoundation] = fmOptions
        return options
    }

    /// One streamed round, reassembled into the response the loop reasons about.
    func streamRound(
        messages: [Message],
        options: RequestOptions,
        emit: @escaping @Sendable (RunEvent) -> Void
    ) async throws -> AIResponse {
        var accumulated = ""
        var toolCalls: [ToolCall] = []
        var seenCallIDs: Set<String> = []
        var finishReason: FinishReason?
        var usage: TokenUsage?
        var provider: ProviderID?

        for try await chunk in streamWithProviderSelection(messages: messages, options: options) {
            if !chunk.delta.isEmpty {
                emit(.textDelta(chunk.delta))
            }
            if !chunk.accumulatedContent.isEmpty {
                accumulated = chunk.accumulatedContent
            } else {
                accumulated += chunk.delta
            }
            // Calls are reported as each one completes and again on the final chunk, so
            // they are merged by id rather than replaced or appended.
            for call in chunk.toolCalls ?? [] where !seenCallIDs.contains(call.id) {
                seenCallIDs.insert(call.id)
                toolCalls.append(call)
            }
            if let reason = chunk.finishReason { finishReason = reason }
            if let chunkUsage = chunk.usage { usage = chunkUsage }
            provider = chunk.provider
        }

        guard let provider else {
            throw ArbiterError.invalidRequest(reason: "The stream ended without producing any chunk")
        }
        return AIResponse(
            id: "run-\(UUID().uuidString)",
            content: accumulated,
            model: options.model ?? "",
            provider: provider,
            toolCalls: toolCalls,
            usage: usage,
            finishReason: finishReason
        )
    }
}

/// Adds up the per-round usage of a run.
struct UsageAccumulator {
    private var input = 0
    private var output = 0
    private var cacheWrite = 0
    private var cacheRead = 0
    private var reported = false

    mutating func add(_ usage: TokenUsage?) {
        guard let usage else { return }
        reported = true
        input += usage.inputTokens
        output += usage.outputTokens
        cacheWrite += usage.cacheCreationInputTokens ?? 0
        cacheRead += usage.cacheReadInputTokens ?? 0
    }

    /// `nil` when no round reported usage, rather than a zeroed total that reads as free.
    var total: TokenUsage? {
        guard reported else { return nil }
        return TokenUsage(
            inputTokens: input,
            outputTokens: output,
            cacheCreationInputTokens: cacheWrite == 0 ? nil : cacheWrite,
            cacheReadInputTokens: cacheRead == 0 ? nil : cacheRead
        )
    }
}
