// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "AnthropicMapper")

/// Maps between Arbiter's unified types and Anthropic API JSON
struct AnthropicMapper: Sendable {
    private let defaultModel: AnthropicModel

    init(defaultModel: AnthropicModel) {
        self.defaultModel = defaultModel
    }

    func buildRequestBody(_ request: AIRequest, stream: Bool) throws -> Data {
        let modelID = request.model ?? defaultModel.rawValue
        // A caller may name a model Arbiter does not know (a preview, or a
        // proxy's own alias). Per-model rules are only applied when the model
        // is recognised; otherwise the caller's values pass through untouched.
        let model = AnthropicModel.named(modelID)
        let options = request.providerOptions[.anthropic] as? AnthropicOptions

        let maxTokens = try resolvedMaxTokens(request.maxTokens, model: model)
        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": maxTokens,
        ]

        if stream {
            body["stream"] = true
        }

        // Sampling controls are rejected outright by newer models, and by older
        // ones while thinking is on, so they are dropped rather than sent — the
        // request would otherwise always 400.
        let thinkingEnabled = options?.thinking != nil
        if let temperature = request.temperature {
            if model?.supportsSamplingControls == false {
                logger.notice("Dropping temperature: model does not accept sampling controls")
            } else if thinkingEnabled {
                logger.notice("Dropping temperature: incompatible with thinking")
            } else {
                body["temperature"] = temperature
            }
        }

        if let topP = request.topP {
            if model?.supportsSamplingControls == false {
                logger.notice("Dropping top_p: model does not accept sampling controls")
            } else if thinkingEnabled, !Self.thinkingCompatibleTopP.contains(topP) {
                // With thinking on, older models only accept top_p in 0.95...1.
                logger.notice("Dropping top_p: outside the range thinking allows")
            } else {
                body["top_p"] = topP
            }
        }

        if let thinking = options?.thinking {
            body["thinking"] = try thinkingJSON(
                thinking,
                display: options?.thinkingDisplay,
                model: model,
                maxTokens: maxTokens
            )
        }

        let caching = options?.promptCaching
        var remainingBreakpoints = caching?.breakpoints ?? 0

        if let tools = request.tools, !tools.isEmpty {
            var toolsJSON = tools.map { mapToolToJSON($0) }
            if remainingBreakpoints > 0 {
                toolsJSON[toolsJSON.count - 1]["cache_control"] = Self.ephemeralCacheControl
                remainingBreakpoints -= 1
            }
            body["tools"] = toolsJSON
        }

        if let systemPrompt = request.systemPrompt {
            if remainingBreakpoints > 0 {
                // cache_control can only ride on a content block, so a cached
                // system prompt has to be sent in block form.
                body["system"] = [[
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": Self.ephemeralCacheControl,
                ] as [String: Any]]
                remainingBreakpoints -= 1
            } else {
                body["system"] = systemPrompt
            }
        }

        if let format = request.responseFormat,
           let outputConfig = try outputConfigJSON(for: format) {
            body["output_config"] = outputConfig
        }

        try validateToolSequence(request.messages)
        try validateDocumentCitations(request.messages)
        var pending = mapMessages(request.messages)
        try validateToolTurnsAreAnswered(pending)
        applyMessageCaching(&pending, breakpoints: remainingBreakpoints)
        body["messages"] = pending.map { $0.rendered }

        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("Failed to serialize request body")
            throw ArbiterError.invalidRequest(reason: "Failed to serialize request: \(error.localizedDescription)")
        }
    }

    func parseResponse(_ data: Data) throws -> AIResponse {
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ArbiterError.decodingFailed(context: "Response is not a JSON object")
            }
            json = parsed
        } catch let swiftAIError as ArbiterError {
            throw swiftAIError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Failed to parse response JSON")
            throw ArbiterError.decodingFailed(context: "Invalid JSON: \(error.localizedDescription)")
        }

        let responseId = json["id"] as? String ?? ""
        let model = json["model"] as? String ?? defaultModel.rawValue

        return AIResponse(
            id: responseId,
            content: extractTextContent(from: json),
            model: model,
            provider: .anthropic,
            toolCalls: extractToolCalls(from: json),
            usage: extractUsage(from: json),
            finishReason: mapStopReason(json["stop_reason"] as? String),
            reasoning: extractReasoning(from: json),
            citations: extractCitations(from: json),
            thinking: extractThinking(from: json)
        )
    }

    /// Parse a single SSE event during streaming.
    ///
    /// Anthropic spreads one turn across many events: usage arrives in
    /// `message_start` (input) and `message_delta` (output), text in
    /// `content_block_delta`, and a tool call across a
    /// `content_block_start` / `input_json_delta` / `content_block_stop`
    /// triple whose arguments only become parseable at the stop. `state`
    /// carries that partial work between events.
    func parseStreamEvent(
        _ eventData: String,
        state: inout AnthropicStreamState
    ) -> AIStreamChunk? {
        guard let data = eventData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["type"] as? String else {
            return nil
        }

        switch eventType {
        case "message_start":
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                state.inputTokens = usage["input_tokens"] as? Int
                state.cacheCreationInputTokens = usage["cache_creation_input_tokens"] as? Int
                state.cacheReadInputTokens = usage["cache_read_input_tokens"] as? Int
            }
            return nil

        case "content_block_start":
            guard let index = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any],
                  block["type"] as? String == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String else {
                return nil
            }
            // The `input` on a start event is an empty stub; the real
            // arguments arrive as input_json_delta fragments.
            state.openToolCalls[index] = PartialToolCall(id: id, name: name)
            return nil

        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any] else { return nil }

            if let partialJSON = delta["partial_json"] as? String,
               let index = json["index"] as? Int {
                state.openToolCalls[index]?.partialJSON += partialJSON
                return nil
            }

            // Thinking and signature deltas carry no user-visible text.
            guard let text = delta["text"] as? String else { return nil }
            state.accumulated += text
            return AIStreamChunk(
                delta: text,
                accumulatedContent: state.accumulated,
                isComplete: false,
                provider: .anthropic
            )

        case "content_block_stop":
            guard let index = json["index"] as? Int,
                  let partial = state.openToolCalls.removeValue(forKey: index) else {
                return nil
            }
            let call = partial.completed()
            state.completedToolCalls.append(call)
            return AIStreamChunk(
                delta: "",
                accumulatedContent: state.accumulated,
                isComplete: false,
                toolCalls: [call],
                provider: .anthropic
            )

        case "message_delta":
            let outputTokens = (json["usage"] as? [String: Any])?["output_tokens"] as? Int
            let usage: TokenUsage?
            if let output = outputTokens {
                usage = TokenUsage(
                    inputTokens: state.inputTokens ?? 0,
                    outputTokens: output,
                    cacheCreationInputTokens: state.cacheCreationInputTokens,
                    cacheReadInputTokens: state.cacheReadInputTokens
                )
            } else {
                usage = nil
            }
            let stopReason = (json["delta"] as? [String: Any])?["stop_reason"] as? String
            return AIStreamChunk(
                delta: "",
                accumulatedContent: state.accumulated,
                isComplete: true,
                usage: usage,
                finishReason: mapStopReason(stopReason),
                toolCalls: state.completedToolCalls.isEmpty ? nil : state.completedToolCalls,
                provider: .anthropic
            )

        default:
            return nil
        }
    }
}

/// Partial work carried between SSE events of one Anthropic stream.
struct AnthropicStreamState: Sendable {
    var accumulated: String = ""
    var inputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
    /// Tool calls whose arguments are still streaming, keyed by block index.
    var openToolCalls: [Int: PartialToolCall] = [:]
    /// Every tool call completed so far this turn.
    var completedToolCalls: [ToolCall] = []

    init() {}
}

/// A tool call whose arguments are still arriving as JSON fragments.
struct PartialToolCall: Sendable {
    let id: String
    let name: String
    var partialJSON: String = ""

    /// Parse the accumulated fragments. A call with no arguments streams no
    /// fragments at all, and a truncated stream leaves unparseable text —
    /// both degrade to empty arguments rather than dropping the call.
    func completed() -> ToolCall {
        guard !partialJSON.isEmpty,
              let data = partialJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            if !partialJSON.isEmpty {
                logger.error("Tool call \(name, privacy: .public) had unparseable streamed arguments")
            }
            return ToolCall(id: id, name: name, arguments: .object([:]))
        }
        return ToolCall(id: id, name: name, arguments: decoded)
    }
}

/// One outgoing Anthropic message, before serialisation.
///
/// Tool results are held apart from the rest because Anthropic requires every
/// `tool_result` block to sit at the front of the user turn that carries it.
struct PendingAnthropicMessage {
    let role: String
    var resultBlocks: [[String: Any]] = []
    var blocks: [[String: Any]] = []
    /// Ids of the `tool_use` blocks this message carries, in order.
    var toolUseIds: [String] = []
    /// Ids of the calls this message's `tool_result` blocks answer.
    var toolResultIds: [String] = []
    /// Set when the message is a single text block, which can be sent in the
    /// API's shorthand string form.
    var plainText: String?

    var hasResults: Bool { !resultBlocks.isEmpty }

    var rendered: [String: Any] {
        if let plainText {
            return ["role": role, "content": plainText]
        }
        return ["role": role, "content": resultBlocks + blocks]
    }

    /// Attach a cache breakpoint to the final content block.
    mutating func applyCacheControl() {
        if let plainText {
            blocks = [["type": "text", "text": plainText]]
            self.plainText = nil
        }
        if !blocks.isEmpty {
            blocks[blocks.count - 1]["cache_control"] = AnthropicMapper.ephemeralCacheControl
        } else if !resultBlocks.isEmpty {
            resultBlocks[resultBlocks.count - 1]["cache_control"] = AnthropicMapper.ephemeralCacheControl
        }
    }
}

// Helpers for JSON mapping
extension AnthropicMapper {
    static let ephemeralCacheControl: [String: String] = ["type": "ephemeral"]

    /// The only `top_p` range models accept while thinking is on.
    static let thinkingCompatibleTopP: ClosedRange<Double> = 0.95...1.0

    /// Clamp-check `max_tokens` against the model's published output cap.
    ///
    /// The API rejects a request asking for more than the model can produce, so
    /// the limit is named here rather than surfaced as an opaque 400.
    func resolvedMaxTokens(_ requested: Int?, model: AnthropicModel?) throws -> Int {
        let maxTokens = requested ?? 1024
        if let cap = model?.maxOutputTokens, maxTokens > cap {
            throw ArbiterError.invalidRequest(
                reason: "max_tokens (\(maxTokens)) exceeds \(model?.displayName ?? "this model")'s limit of \(cap)"
            )
        }
        return maxTokens
    }

    /// Citations must be enabled on every document block or none of them.
    func validateDocumentCitations(_ messages: [Message]) throws {
        let flags = messages.flatMap { $0.content.allDocuments.map(\.enableCitations) }
        guard flags.contains(true), flags.contains(false) else { return }
        throw ArbiterError.invalidRequest(
            reason: "Citations must be enabled on every document in a request, or on none"
        )
    }

    /// Every tool call must be answered by the turn that follows it.
    ///
    /// The API requires the results for one assistant turn to arrive together in
    /// the next user message; a partially answered turn, or one with another
    /// turn wedged in front of its results, is rejected. A trailing call turn is
    /// allowed — its results simply have not been produced yet.
    func validateToolTurnsAreAnswered(_ pending: [PendingAnthropicMessage]) throws {
        for (index, message) in pending.enumerated() where !message.toolUseIds.isEmpty {
            guard index + 1 < pending.count else { continue }
            let issued = Set(message.toolUseIds)
            let answered = Set(pending[index + 1].toolResultIds)
            guard answered == issued else {
                let missing = issued.subtracting(answered).sorted()
                throw ArbiterError.invalidRequest(
                    reason: missing.isEmpty
                        ? "The turn after a tool call answered calls it did not make"
                        : "Tool call(s) \(missing.joined(separator: ", ")) are not answered by the turn that follows them"
                )
            }
        }
    }

    /// Reject a tool result that answers no earlier call.
    ///
    /// Anthropic 400s on a `tool_result` whose `tool_use_id` never appeared in
    /// a preceding assistant turn; catching it here names the problem instead
    /// of surfacing an opaque API error.
    func validateToolSequence(_ messages: [Message]) throws {
        var issuedCallIds: Set<String> = []
        for message in messages {
            for result in message.content.allToolResults where !issuedCallIds.contains(result.toolCallId) {
                throw ArbiterError.invalidRequest(
                    reason: "Tool result '\(result.toolCallId)' has no preceding tool call in this conversation"
                )
            }
            for call in message.content.allToolCalls {
                issuedCallIds.insert(call.id)
            }
        }
    }

    /// Map the conversation, merging the tool results of one turn into a
    /// single user message.
    ///
    /// Anthropic expects every result for an assistant's parallel calls in one
    /// user turn; splitting them across messages is rejected, so adjacent
    /// user messages are merged whenever either side carries results. Note that
    /// merging puts the results first, so plain text the caller wrote *before*
    /// them ends up behind them — the API's block-order rule leaves no choice.
    func mapMessages(_ messages: [Message]) -> [PendingAnthropicMessage] {
        var pending: [PendingAnthropicMessage] = []
        for message in messages {
            for next in pendingMessages(for: message) {
                if var previous = pending.last,
                   previous.role == next.role,
                   previous.hasResults || next.hasResults {
                    previous.resultBlocks += next.resultBlocks
                    previous.blocks += next.blocks
                    previous.toolUseIds += next.toolUseIds
                    previous.toolResultIds += next.toolResultIds
                    previous.plainText = nil
                    pending[pending.count - 1] = previous
                } else {
                    pending.append(next)
                }
            }
        }
        return pending
    }

    /// Spend the remaining cache breakpoints on the most recent messages.
    func applyMessageCaching(_ pending: inout [PendingAnthropicMessage], breakpoints: Int) {
        guard breakpoints > 0 else { return }
        let cacheable = pending.indices.suffix(breakpoints)
        for index in cacheable {
            pending[index].applyCacheControl()
        }
    }

    func pendingMessages(for message: Message) -> [PendingAnthropicMessage] {
        guard message.role != .system else { return [] }

        switch message.content {
        case .text(let text):
            var pending = PendingAnthropicMessage(role: role(for: message.role))
            pending.blocks = [textContentBlock(text)]
            pending.plainText = text
            return [pending]

        case .image, .document:
            let blocks = plainContentBlocks(message.content)
            guard !blocks.isEmpty else { return [] }
            var pending = PendingAnthropicMessage(role: role(for: message.role))
            pending.blocks = blocks
            return [pending]

        case .toolCalls(let calls):
            return calls.isEmpty ? [] : [toolUseMessage(leadingBlocks: [], calls: calls)]

        case .toolResults(let results):
            return results.isEmpty ? [] : [toolResultMessage(results: results, trailingBlocks: [])]

        case .thinking(let blocks):
            let thinkingBlocks = replayableThinkingBlocks(blocks, role: message.role)
            guard !thinkingBlocks.isEmpty else { return [] }
            var pending = PendingAnthropicMessage(role: role(for: message.role))
            pending.blocks = thinkingBlocks
            return [pending]

        case .mixed(let parts):
            return mixedMessages(parts, role: message.role)
        }
    }

    /// Anthropic constrains where tool blocks may sit: `tool_use` belongs to an
    /// assistant turn, `tool_result` to a user turn, and every `tool_result`
    /// block must precede any other block in the message carrying it. A mixed
    /// turn is reshaped to satisfy that — including splitting into two messages
    /// when the caller put calls and results in the same turn.
    func mixedMessages(_ parts: [MessageContent], role messageRole: Role) -> [PendingAnthropicMessage] {
        // Thinking blocks are pulled out and put first whatever order the caller wrote
        // them in: the API requires them to lead the assistant turn they belong to.
        let thinking = replayableThinkingBlocks(parts.flatMap(\.allThinking), role: messageRole)
        let plain = thinking + parts.flatMap { plainContentBlocks($0) }
        let calls = parts.flatMap(\.allToolCalls)
        let results = parts.flatMap(\.allToolResults)

        var messages: [PendingAnthropicMessage] = []
        if !results.isEmpty {
            // With no calls to split off, the plain blocks ride along after the results.
            messages.append(toolResultMessage(
                results: results,
                trailingBlocks: calls.isEmpty ? plain : []
            ))
        }
        if !calls.isEmpty {
            messages.append(toolUseMessage(leadingBlocks: plain, calls: calls))
        } else if results.isEmpty, !plain.isEmpty {
            var pending = PendingAnthropicMessage(role: role(for: messageRole))
            pending.blocks = plain
            return [pending]
        }
        return messages
    }

    /// Text, image and document blocks only — tool blocks are placed by the
    /// caller, which has to control their position and the message role.
    func plainContentBlocks(_ part: MessageContent) -> [[String: Any]] {
        switch part {
        case .text(let text):
            return [textContentBlock(text)]
        case .image(let source):
            return [imageContentBlock(source)].compactMap { $0 }
        case .document(let source):
            return [documentContentBlock(source)]
        case .mixed(let nested):
            return nested.flatMap { plainContentBlocks($0) }
        case .toolCalls, .toolResults, .thinking:
            return []
        }
    }

    /// The thinking blocks that can legally go back on the wire.
    ///
    /// Only an assistant turn may carry them, and only a block the API can validate: a
    /// `thinking` block is checked against its `signature`, so one that lost its signature
    /// — a streamed turn, or history built by hand — is dropped rather than sent to be
    /// rejected. `redacted_thinking` carries its own opaque payload and needs no signature.
    func replayableThinkingBlocks(_ blocks: [ThinkingBlock], role: Role) -> [[String: Any]] {
        guard role == .assistant else { return [] }
        return blocks.compactMap { block in
            if let data = block.redactedData {
                return ["type": "redacted_thinking", "data": data]
            }
            guard let signature = block.signature, !signature.isEmpty else {
                logger.notice("Dropping an unsigned thinking block: it cannot be replayed")
                return nil
            }
            return ["type": "thinking", "thinking": block.text, "signature": signature]
        }
    }

    func toolUseMessage(leadingBlocks: [[String: Any]], calls: [ToolCall]) -> PendingAnthropicMessage {
        var pending = PendingAnthropicMessage(role: "assistant")
        pending.blocks = leadingBlocks + calls.map { toolUseContentBlock($0) }
        pending.toolUseIds = calls.map(\.id)
        return pending
    }

    func toolResultMessage(results: [ToolResult], trailingBlocks: [[String: Any]]) -> PendingAnthropicMessage {
        var pending = PendingAnthropicMessage(role: "user")
        pending.resultBlocks = results.map { toolResultContentBlock($0) }
        pending.blocks = trailingBlocks
        pending.toolResultIds = results.map(\.toolCallId)
        return pending
    }

    func role(for role: Role) -> String {
        switch role {
        case .assistant: "assistant"
        case .user, .tool, .system: "user"
        }
    }

    func toolUseContentBlock(_ call: ToolCall) -> [String: Any] {
        [
            "type": "tool_use",
            "id": call.id,
            "name": call.name,
            "input": call.arguments.foundationObject,
        ]
    }

    func toolResultContentBlock(_ result: ToolResult) -> [String: Any] {
        [
            "type": "tool_result",
            "tool_use_id": result.toolCallId,
            "content": result.content,
        ]
    }

    func textContentBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    func imageContentBlock(_ source: ImageSource) -> [String: Any]? {
        switch source {
        case .base64(let data, let mimeType):
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mimeType,
                    "data": data,
                ] as [String: String],
            ]
        case .url:
            // The provider downloads and re-encodes URL images before mapping,
            // so reaching here means the fetch was skipped.
            logger.error("Dropping URL image: Anthropic requires inline base64 data")
            return nil
        }
    }

    func documentContentBlock(_ source: DocumentSource) -> [String: Any] {
        var block: [String: Any] = [
            "type": "document",
            "source": [
                "type": "base64",
                "media_type": source.mimeType,
                "data": source.data,
            ] as [String: String],
        ]
        if let title = source.title {
            block["title"] = title
        }
        if source.enableCitations {
            block["citations"] = ["enabled": true]
        }
        return block
    }

    func mapToolToJSON(_ tool: ToolDefinition) -> [String: Any] {
        var toolJSON: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]

        if let schemaData = try? JSONEncoder().encode(tool.inputSchema),
           let schemaObj = try? JSONSerialization.jsonObject(with: schemaData) {
            toolJSON["input_schema"] = schemaObj
        }

        return toolJSON
    }

    /// Map the requested response format onto `output_config`.
    ///
    /// Only a schema reaches the wire: Anthropic has no JSON-mode flag, so
    /// `.json` and `.text` keep taking the prompt path they always have rather
    /// than being silently dropped into a field that does not exist.
    ///
    /// Shape verified 2 September 2026 against
    /// https://platform.claude.com/docs/en/build-with-claude/structured-outputs —
    /// generally available, so no beta header rides with it.
    func outputConfigJSON(for format: ResponseFormat) throws -> [String: Any]? {
        guard case .structured(let schema) = format else { return nil }
        let parsed = try JSONSchemaNormalizer.parseObject(schema)
        return [
            "format": [
                "type": "json_schema",
                "schema": JSONSchemaNormalizer.anthropicSchema(parsed),
            ],
        ]
    }

    /// Build the `thinking` parameter, rejecting shapes the model refuses.
    ///
    /// Models differ: current models take adaptive thinking and 400 on a fixed
    /// `budget_tokens`, while earlier ones only accept the budget form.
    func thinkingJSON(
        _ thinking: AnthropicThinking,
        display: AnthropicThinkingDisplay?,
        model: AnthropicModel?,
        maxTokens: Int
    ) throws -> [String: Any] {
        var json = try thinkingModeJSON(thinking, model: model, maxTokens: maxTokens)
        if let display {
            json["display"] = display.rawValue
        }
        return json
    }

    func thinkingModeJSON(
        _ thinking: AnthropicThinking,
        model: AnthropicModel?,
        maxTokens: Int
    ) throws -> [String: Any] {
        let support = model?.thinkingSupport
        switch thinking {
        case .adaptive:
            if support == .extended {
                throw ArbiterError.invalidRequest(
                    reason: "\(model?.displayName ?? "This model") does not support adaptive thinking; use .extended(budgetTokens:)"
                )
            }
            return ["type": "adaptive"]

        case .extended(let budgetTokens):
            if let support, support != .extended {
                throw ArbiterError.invalidRequest(
                    reason: "\(model?.displayName ?? "This model") does not accept a thinking budget; use .adaptive"
                )
            }
            guard budgetTokens >= 1024 else {
                throw ArbiterError.invalidRequest(
                    reason: "Thinking budget must be at least 1024 tokens, got \(budgetTokens)"
                )
            }
            guard budgetTokens < maxTokens else {
                throw ArbiterError.invalidRequest(
                    reason: "Thinking budget (\(budgetTokens)) must be less than max_tokens (\(maxTokens))"
                )
            }
            return ["type": "enabled", "budget_tokens": budgetTokens]
        }
    }

    func contentBlocks(from json: [String: Any]) -> [[String: Any]] {
        json["content"] as? [[String: Any]] ?? []
    }

    func extractTextContent(from json: [String: Any]) -> String {
        contentBlocks(from: json)
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    /// Join the model's thinking blocks, if the request asked for them.
    func extractReasoning(from json: [String: Any]) -> String? {
        let thinking = contentBlocks(from: json)
            .filter { ($0["type"] as? String) == "thinking" }
            .compactMap { $0["thinking"] as? String }
            .filter { !$0.isEmpty }
        return thinking.isEmpty ? nil : thinking.joined(separator: "\n")
    }

    /// The thinking blocks as they arrived, signatures included.
    ///
    /// The signature is what makes a block replayable: a tool-use conversation with
    /// thinking on has to send the assistant's thinking back unchanged, and the API
    /// validates it against the signature.
    func extractThinking(from json: [String: Any]) -> [ThinkingBlock] {
        contentBlocks(from: json).compactMap { block in
            switch block["type"] as? String {
            case "thinking":
                guard let text = block["thinking"] as? String else { return nil }
                return ThinkingBlock(text: text, signature: block["signature"] as? String)
            case "redacted_thinking":
                guard let data = block["data"] as? String else { return nil }
                return .redacted(data: data)
            default:
                return nil
            }
        }
    }

    /// Collect the citations attached to the response's text blocks.
    func extractCitations(from json: [String: Any]) -> [Citation] {
        contentBlocks(from: json)
            .compactMap { $0["citations"] as? [[String: Any]] }
            .flatMap { $0 }
            .map { citation in
                Citation(
                    citedText: citation["cited_text"] as? String,
                    title: citation["document_title"] as? String ?? citation["title"] as? String,
                    documentIndex: citation["document_index"] as? Int,
                    // Character, page and block locations are all ranges; the
                    // block's own type says which unit the numbers are in.
                    startIndex: citation["start_char_index"] as? Int
                        ?? citation["start_page_number"] as? Int
                        ?? citation["start_block_index"] as? Int,
                    endIndex: citation["end_char_index"] as? Int
                        ?? citation["end_page_number"] as? Int
                        ?? citation["end_block_index"] as? Int,
                    url: (citation["url"] as? String).flatMap(URL.init(string:))
                )
            }
    }

    func extractToolCalls(from json: [String: Any]) -> [ToolCall] {
        contentBlocks(from: json)
            .filter { ($0["type"] as? String) == "tool_use" }
            .compactMap { block -> ToolCall? in
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String else {
                    return nil
                }

                let arguments: JSONValue
                if let input = block["input"],
                   let inputData = try? JSONSerialization.data(withJSONObject: input),
                   let decoded = try? JSONDecoder().decode(JSONValue.self, from: inputData) {
                    arguments = decoded
                } else {
                    arguments = .object([:])
                }

                return ToolCall(id: id, name: name, arguments: arguments)
            }
    }

    func extractUsage(from json: [String: Any]) -> TokenUsage? {
        // Usage can be at top level or nested under "usage"
        let usageDict = (json["usage"] as? [String: Any]) ?? json

        guard let inputTokens = usageDict["input_tokens"] as? Int,
              let outputTokens = usageDict["output_tokens"] as? Int else {
            return nil
        }

        return TokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationInputTokens: usageDict["cache_creation_input_tokens"] as? Int,
            cacheReadInputTokens: usageDict["cache_read_input_tokens"] as? Int
        )
    }

    func mapStopReason(_ reason: String?) -> FinishReason? {
        guard let reason else { return nil }
        switch reason {
        case "end_turn": return .complete
        case "max_tokens": return .maxTokens
        case "stop_sequence": return .stopSequence
        case "tool_use": return .toolCall
        case "refusal": return .refusal
        case "pause_turn": return .pauseTurn
        case "content_filter": return .contentFilter
        default: return nil
        }
    }
}
