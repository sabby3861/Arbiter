// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "OllamaMapper")

/// What a streamed turn has produced so far.
///
/// Ollama's NDJSON stream reports a tool call whole, in its own object with
/// empty content, so the calls have to be gathered across lines and replayed on
/// the final chunk — the contract ``AIStreamChunk/toolCalls`` documents.
struct OllamaStreamState {
    /// Answer text so far. Thinking deltas are excluded.
    var accumulatedContent = ""
    /// Every tool call seen this turn, in arrival order.
    var toolCalls: [ToolCall] = []
    /// Distinguishes this turn's synthesised call ids from the next turn's.
    /// See ``OllamaMapper/synthesisedCallIDPrefix``.
    let turnID: String

    init(turnID: String = OllamaMapper.newTurnID()) {
        self.turnID = turnID
    }
}

struct OllamaMapper: Sendable {
    /// Prefix marking a call id Arbiter invented because Ollama sent none.
    ///
    /// Ollama's `tool_calls` carry only a function name and arguments, and its
    /// `role: "tool"` messages correlate by `tool_name` rather than by id, so
    /// nothing is ever echoed back — the id exists only so Arbiter's own tool
    /// loop can pair a result with the call that asked for it.
    ///
    /// An id must therefore be stable within a turn — the streaming loop dedups
    /// a call it has already yielded by id — and unique *across* turns, because
    /// the loop also memoises a tool's output under a key built from the call id
    /// and its arguments alone. Numbering from zero every turn would make round
    /// two's first no-argument call collide with round one's, and the loop would
    /// answer a different tool with the earlier tool's cached output. Hence the
    /// per-turn nonce in the middle: `ollama-call-<turn>-<index>`.
    static let synthesisedCallIDPrefix = "ollama-call-"

    /// A fresh nonce identifying one assistant turn.
    static func newTurnID() -> String {
        UUID().uuidString.prefix(8).lowercased()
    }

    private let defaultModel: String

    init(defaultModel: String) {
        self.defaultModel = defaultModel
    }

    func buildChatBody(_ request: AIRequest, stream: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": request.model ?? defaultModel,
            "stream": stream,
        ]

        var messages: [[String: Any]] = []

        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }

        for message in request.messages where message.role != .system {
            messages.append(contentsOf: mapMessageToJSON(message))
        }

        body["messages"] = messages

        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { mapToolToJSON($0) }
        }

        let ollamaOptions = request.providerOptions[.ollama] as? OllamaOptions

        var options: [String: Any] = [:]
        if let temperature = request.temperature {
            options["temperature"] = temperature
        }
        if let topP = request.topP {
            options["top_p"] = topP
        }
        if let maxTokens = request.maxTokens {
            options["num_predict"] = maxTokens
        }
        if let numCtx = ollamaOptions?.numCtx {
            options["num_ctx"] = numCtx
        }
        if !options.isEmpty {
            body["options"] = options
        }

        // `keep_alive` and `think` are top-level request parameters, not entries
        // in `options`.
        if let keepAlive = ollamaOptions?.keepAlive {
            body["keep_alive"] = keepAlive.wireValue
        }
        if let think = ollamaOptions?.think {
            body["think"] = think.wireValue
        }

        if let format = request.responseFormat {
            try applyResponseFormat(format, to: &body)
        }

        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("Failed to serialize Ollama request")
            throw ArbiterError.invalidRequest(reason: "Failed to serialize: \(error.localizedDescription)")
        }
    }

    func parseResponse(_ data: Data) throws -> AIResponse {
        let json = try parseJSON(data)

        let model = json["model"] as? String ?? defaultModel
        let message = json["message"] as? [String: Any] ?? [:]
        let textContent = message["content"] as? String ?? ""
        let toolCalls = Self.extractToolCalls(from: message, turnID: Self.newTurnID())
        let usage = extractUsage(from: json)
        let finishReason = mapFinishReason(from: json, toolCalls: toolCalls)

        // `think` puts the model's reasoning on its own field, apart from the
        // answer. It carries no signature and Ollama takes none back, so it is
        // readable text only — not a replayable thinking block.
        let reasoning = (message["thinking"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return AIResponse(
            id: "ollama-\(UUID().uuidString)",
            content: textContent,
            model: model,
            provider: .ollama,
            toolCalls: toolCalls,
            usage: usage,
            finishReason: finishReason,
            reasoning: reasoning
        )
    }

    /// Turn one NDJSON line into a chunk, or `nil` when the line adds nothing a
    /// consumer can act on.
    ///
    /// A tool call arrives in an object of its own with empty `content`, so an
    /// empty delta is not by itself a reason to skip a line: the chunk that
    /// carries calls is yielded even though it has no text. Thinking deltas are
    /// dropped rather than mixed into the answer — ``AIStreamChunk`` has no
    /// field for reasoning, and appending it would corrupt the content a caller
    /// renders.
    func parseStreamLine(_ line: String, state: inout OllamaStreamState) -> AIStreamChunk? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let isDone = json["done"] as? Bool ?? false
        let message = json["message"] as? [String: Any] ?? [:]
        let deltaContent = message["content"] as? String ?? ""
        let newCalls = Self.extractToolCalls(
            from: message, turnID: state.turnID, startingAt: state.toolCalls.count
        )

        if !deltaContent.isEmpty {
            state.accumulatedContent += deltaContent
        }
        state.toolCalls.append(contentsOf: newCalls)

        if isDone {
            // The final line reports `done_reason: "stop"` even for a turn that
            // asked for a tool, so the calls decide the reason.
            return AIStreamChunk(
                delta: deltaContent,
                accumulatedContent: state.accumulatedContent,
                isComplete: true,
                usage: extractUsage(from: json),
                finishReason: mapFinishReason(from: json, toolCalls: state.toolCalls),
                toolCalls: state.toolCalls.isEmpty ? nil : state.toolCalls,
                provider: .ollama
            )
        }

        guard !deltaContent.isEmpty || !newCalls.isEmpty else { return nil }

        return AIStreamChunk(
            delta: deltaContent,
            accumulatedContent: state.accumulatedContent,
            isComplete: false,
            toolCalls: newCalls.isEmpty ? nil : newCalls,
            provider: .ollama
        )
    }
}

private extension OllamaMapper {
    func mapMessageToJSON(_ message: Message) -> [[String: Any]] {
        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .system: role = "system"
        case .tool: role = "tool"
        }

        switch message.content {
        case .text(let text):
            return [["role": role, "content": text]]

        case .image(let source):
            switch source {
            case .base64(let data, _):
                return [["role": role, "content": "", "images": [data]]]
            case .url:
                return [["role": role, "content": ""]]
            }

        case .document:
            // Document input is not mapped for this provider yet.
            logger.error("Dropping document content: unsupported by this provider")
            return []

        case .thinking:
            // No wire representation: Ollama returns its own thinking text but takes none back.
            return []

        case .toolCalls(let calls):
            return calls.isEmpty ? [] : [assistantToolCallMessage(text: "", calls: calls)]

        case .toolResults(let results):
            return results.map { toolResultMessage($0) }

        case .mixed(let parts):
            return mapMixedContentToJSON(parts, role: role)
        }
    }

    /// Ollama carries tool calls on one assistant message and each tool result on
    /// its own `role: "tool"` message, so a mixed turn fans out.
    ///
    /// Results come first: they answer the preceding assistant `tool_calls` turn and
    /// must not be separated from it. A turn containing tool calls is emitted as
    /// `assistant` whatever role the caller gave it.
    func mapMixedContentToJSON(_ parts: [MessageContent], role: String) -> [[String: Any]] {
        let text = flattenedText(parts).joined(separator: "\n")
        let images = flattenedImages(parts)
        let calls = parts.flatMap(\.allToolCalls)
        let results = parts.flatMap(\.allToolResults)

        var messages: [[String: Any]] = results.map { toolResultMessage($0) }
        if !calls.isEmpty {
            messages.append(assistantToolCallMessage(text: text, calls: calls))
        } else if !text.isEmpty || !images.isEmpty {
            var message: [String: Any] = ["role": role, "content": text]
            if !images.isEmpty {
                message["images"] = images
            }
            messages.append(message)
        }
        return messages
    }

    /// Text of every non-tool part; tool results become their own messages.
    func flattenedText(_ parts: [MessageContent]) -> [String] {
        parts.flatMap { part -> [String] in
            switch part {
            case .text(let text): [text]
            case .mixed(let nested): flattenedText(nested)
            default: []
            }
        }
    }

    func flattenedImages(_ parts: [MessageContent]) -> [String] {
        parts.flatMap { part -> [String] in
            switch part {
            case .image(.base64(let data, _)): [data]
            case .mixed(let nested): flattenedImages(nested)
            default: []
            }
        }
    }

    func assistantToolCallMessage(text: String, calls: [ToolCall]) -> [String: Any] {
        [
            "role": "assistant",
            "content": text,
            // Ollama's history format has no call id — only the function payload.
            "tool_calls": calls.map { call in
                ["function": ["name": call.name, "arguments": call.arguments.foundationObject]]
            },
        ]
    }

    /// Ollama correlates a result with its call by `tool_name`, not by id, so a
    /// `ToolResult` built by hand without a `name` produces a message the model
    /// cannot attribute. The tool loop always sets one.
    func toolResultMessage(_ result: ToolResult) -> [String: Any] {
        var message: [String: Any] = ["role": "tool", "content": result.content]
        if let name = result.name {
            message["tool_name"] = name
        }
        return message
    }

    /// Ollama takes tools in the OpenAI function shape, the schema passed through
    /// as the caller wrote it.
    func mapToolToJSON(_ tool: ToolDefinition) -> [String: Any] {
        var function: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        function["parameters"] = tool.inputSchema.foundationObject
        return ["type": "function", "function": function]
    }

    /// Map the requested response format onto `format`.
    ///
    /// `format` takes either the string `"json"` — free-form JSON — or a JSON
    /// Schema **object**, which constrains decoding. Verified 3 September 2026
    /// against https://raw.githubusercontent.com/ollama/ollama/main/docs/api.md.
    func applyResponseFormat(_ format: ResponseFormat, to body: inout [String: Any]) throws {
        switch format {
        case .text:
            break
        case .json:
            body["format"] = "json"
        case .structured(let schema):
            // Sent as written: Ollama constrains sampling with the schema
            // directly and documents no restricted subset to normalise into.
            body["format"] = try JSONSchemaNormalizer.parseObject(schema)
        }
    }

    /// A turn that asked for a tool finishes as `.toolCall` whatever Ollama
    /// says: it reports `done_reason: "stop"` for a tool turn too, and a caller
    /// branching on the reason would end the conversation with the call
    /// unanswered.
    func mapFinishReason(from json: [String: Any], toolCalls: [ToolCall]) -> FinishReason {
        if !toolCalls.isEmpty { return .toolCall }
        guard let reason = json["done_reason"] as? String else { return .complete }
        switch reason {
        case "length": return .maxTokens
        case "stop": return .complete
        default: return .complete
        }
    }

    func extractUsage(from json: [String: Any]) -> TokenUsage? {
        let promptEvalCount = json["prompt_eval_count"] as? Int
        let evalCount = json["eval_count"] as? Int

        guard promptEvalCount != nil || evalCount != nil else {
            return nil
        }
        return TokenUsage(inputTokens: promptEvalCount ?? 0, outputTokens: evalCount ?? 0)
    }

    /// Decode a call's arguments.
    ///
    /// The documented shape is a JSON object. A stringified object is accepted
    /// too: some community model templates emit one, and reading it is better
    /// than running the tool with no arguments and saying nothing.
    static func decodeArguments(_ raw: Any?) -> JSONValue {
        guard let raw else { return .object([:]) }

        if let text = raw as? String {
            guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                  case .object = decoded else {
                return .object([:])
            }
            return decoded
        }

        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object([:])
        }
        return decoded
    }

    /// Read `message.tool_calls`.
    ///
    /// Ollama sends the arguments as a JSON object rather than the stringified
    /// JSON the OpenAI wire format uses, and attaches no id — `startingAt` keeps
    /// the synthesised ids unique across the lines of a streamed turn.
    static func extractToolCalls(
        from message: [String: Any],
        turnID: String,
        startingAt offset: Int = 0
    ) -> [ToolCall] {
        guard let rawCalls = message["tool_calls"] as? [[String: Any]] else { return [] }

        // Numbered over the calls actually kept, not over the raw array: a
        // malformed entry is dropped, and numbering by raw position would leave
        // `offset` — the count of calls kept so far — pointing at an id the
        // previous line already used.
        return rawCalls.compactMap { rawCall -> (name: String, arguments: JSONValue)? in
            guard let function = rawCall["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }

            return (name, decodeArguments(function["arguments"]))
        }.enumerated().map { index, call in
            ToolCall(
                id: "\(synthesisedCallIDPrefix)\(turnID)-\(offset + index)",
                name: call.name,
                arguments: call.arguments
            )
        }
    }

    func parseJSON(_ data: Data) throws -> [String: Any] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ArbiterError.decodingFailed(context: "Response is not a JSON object")
            }
            return json
        } catch let swiftAIError as ArbiterError {
            throw swiftAIError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Failed to parse Ollama response JSON")
            throw ArbiterError.decodingFailed(context: "Invalid JSON: \(error.localizedDescription)")
        }
    }
}
