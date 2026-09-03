// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Turns an `AIRequest` into the transcript Apple Foundation Models replays plus the
/// prompt for this turn.
///
/// `LanguageModelSession.respond(to:)` appends its own `Prompt` entry, so the final
/// user turn must be handed over separately rather than placed in the transcript —
/// otherwise the model sees the question twice.
///
/// Pure by design: no `FoundationModels` symbol appears here, so every mapping rule
/// and rejection below is unit tested on any platform.
enum FMTranscriptBuilder {
    struct Built: Sendable, Equatable {
        /// History replayed into the session. Empty for a single-turn request with no system prompt.
        let transcript: FMTranscript
        /// The text passed to `respond(to:)` / `streamResponse(to:)`.
        let prompt: String
    }

    /// - Parameter toolNames: the tools this turn runs with, recorded on the instructions
    ///   entry. Passed in rather than read from `request.tools` because the effective set is
    ///   what the request declares *and* the provider options bind — a decision that belongs
    ///   to the provider, not to this translation.
    static func build(from request: AIRequest, toolNames: [String] = []) throws -> Built {
        let messages = request.messages

        // System content has no transcript entry of its own: it becomes the leading
        // `instructions` entry, which is the only route into a session built from a
        // transcript.
        var instructionParts: [String] = []
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            instructionParts.append(systemPrompt)
        }
        for message in messages where message.role == .system {
            if let text = message.content.text, !text.isEmpty {
                instructionParts.append(text)
            }
        }

        let conversation = messages.filter { $0.role != .system }

        guard let last = conversation.last else {
            throw ArbiterError.invalidRequest(
                reason: "Apple Foundation Models needs at least one user message; the request has none."
            )
        }
        // The final turn bypasses `append`, so its unsupported content has to be rejected
        // here too — otherwise an image in the *current* question would be silently dropped
        // while the same image one message earlier throws.
        try rejectUnsupportedContent(in: last)

        guard last.role == .user, let promptText = userPromptText(last), !promptText.isEmpty else {
            throw ArbiterError.invalidRequest(
                reason: """
                Apple Foundation Models requires the final message to be a user message carrying \
                text; this request ends with a \(last.role.rawValue) message with no text to send.
                """
            )
        }

        var entries: [FMTranscriptEntry] = []
        // An entry with no text is still emitted when tools are bound: the instructions
        // entry is where a transcript carries its tool definitions, so without one the
        // session would hold executors the model was never told about.
        if !instructionParts.isEmpty || !toolNames.isEmpty {
            entries.append(.instructions(
                segments: instructionParts.isEmpty
                    ? []
                    : [.text(instructionParts.joined(separator: "\n\n"))],
                toolNames: toolNames
            ))
        }

        // Tool results correlate by id against any preceding call in this conversation,
        // matching how the cloud mappers do it. Ids repeated across turns resolve to the
        // most recent call of that id.
        var pendingToolNames: [String: String] = [:]

        for message in conversation.dropLast() {
            try append(message, to: &entries, pendingToolNames: &pendingToolNames)
        }

        return Built(transcript: FMTranscript(entries: entries), prompt: promptText)
    }

    /// Rejects content Apple Foundation Models cannot accept, wherever it appears.
    private static func rejectUnsupportedContent(in message: Message) throws {
        for part in flatten(message.content) {
            switch part {
            case .image:
                // TODO(F7-I): image input needs the OS 27 SDK, which exposes no image
                // segment today. Rejected rather than silently dropped.
                throw ArbiterError.invalidRequest(
                    reason: "Apple Foundation Models does not accept image content on this OS version."
                )
            case .document:
                throw ArbiterError.invalidRequest(
                    reason: "Apple Foundation Models does not accept document content."
                )
            default:
                continue
            }
        }
    }

    /// The text of a user message, ignoring tool results — a tool-result turn is not a prompt.
    private static func userPromptText(_ message: Message) -> String? {
        switch message.content {
        case .text(let text):
            return text
        case .mixed(let parts):
            let texts = parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default:
            return nil
        }
    }

    private static func append(
        _ message: Message,
        to entries: inout [FMTranscriptEntry],
        pendingToolNames: inout [String: String]
    ) throws {
        for part in flatten(message.content) {
            switch part {
            case .text(let text):
                guard !text.isEmpty else { continue }
                switch message.role {
                case .assistant:
                    entries.append(.response(segments: [.text(text)]))
                case .user:
                    entries.append(.prompt(segments: [.text(text)]))
                case .tool:
                    // A tool turn carrying loose text has no call to attach to.
                    throw ArbiterError.invalidRequest(
                        reason: "A tool message must carry tool results, not plain text."
                    )
                case .system:
                    continue  // Already folded into the instructions entry.
                }

            case .toolCalls(let calls):
                guard !calls.isEmpty else { continue }
                for call in calls {
                    pendingToolNames[call.id] = call.name
                }
                entries.append(.toolCalls(try calls.map {
                    FMToolCall(id: $0.id, toolName: $0.name, argumentsJSON: try jsonString(for: $0.arguments))
                }))

            case .toolResults(let results):
                guard !results.isEmpty else { continue }
                for result in results {
                    // Mirrors the Anthropic rule from F3: a result with no call to answer
                    // is a malformed history, not something to paper over.
                    guard let callName = pendingToolNames[result.toolCallId] else {
                        throw ArbiterError.invalidRequest(
                            reason: """
                            Tool result '\(result.toolCallId)' has no preceding tool call in this \
                            conversation.
                            """
                        )
                    }
                    let name = result.name ?? callName
                    // One `toolOutput` entry per result: Apple's entry is singular.
                    entries.append(.toolOutput(
                        id: result.toolCallId,
                        toolName: name,
                        segments: [.text(result.content)]
                    ))
                }

            case .thinking:
                // A `Transcript` has no entry for another model's reasoning, and the
                // on-device model does not continue from one, so it is left out.
                continue

            case .image, .document:
                try rejectUnsupportedContent(in: message)

            case .mixed:
                continue  // `flatten` has already removed nesting.
            }
        }
    }

    /// Flattens `.mixed` nesting while preserving order, so a turn that interleaves
    /// text and tool calls produces entries in the same sequence the model saw.
    private static func flatten(_ content: MessageContent) -> [MessageContent] {
        guard case .mixed(let parts) = content else { return [content] }
        return parts.flatMap(flatten)
    }

    /// Deterministic JSON for tool arguments — sorted keys keep transcript fingerprints stable.
    private static func jsonString(for value: JSONValue) throws -> String {
        // Checked on the case rather than with `isValidJSONObject`, which also accepts a
        // top-level array — that would pass a guard whose message promises an object and
        // then fail later inside `GeneratedContent(json:)`.
        guard case .object = value else {
            throw ArbiterError.invalidRequest(
                reason: "Tool call arguments must be a JSON object."
            )
        }
        let data = try JSONSerialization.data(withJSONObject: value.foundationValue, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
