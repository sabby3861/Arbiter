// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "OpenAIMapper")

struct OpenAIMapper: Sendable {
    private let defaultModel: OpenAIModel

    init(defaultModel: OpenAIModel) {
        self.defaultModel = defaultModel
    }

    func buildRequestBody(_ request: AIRequest, stream: Bool) throws -> Data {
        let modelID = request.model ?? defaultModel.rawValue
        let options = request.providerOptions[.openAI] as? OpenAIOptions
        // A caller may name a model this catalogue has never seen — a preview,
        // a dated snapshot, or an OpenAI-compatible host's own alias — so the
        // reasoning family is judged from the raw ID, not the enum.
        let isReasoning = OpenAIModel.isReasoningModel(id: modelID)

        var body: [String: Any] = ["model": modelID]

        if let maxTokens = request.maxTokens {
            // `max_tokens` is deprecated and outright rejected by reasoning
            // models, which count their hidden reasoning tokens against
            // `max_completion_tokens` instead.
            body[isReasoning ? "max_completion_tokens" : "max_tokens"] = maxTokens
        }

        // Reasoning models reject sampling controls, so these are dropped
        // rather than sent — the request would otherwise always 400.
        if let temperature = request.temperature {
            if isReasoning {
                logger.notice("Dropping temperature: reasoning models do not accept it")
            } else {
                body["temperature"] = temperature
            }
        }
        if let topP = request.topP {
            if isReasoning {
                logger.notice("Dropping top_p: reasoning models do not accept it")
            } else {
                body["top_p"] = topP
            }
        }

        if let effort = options?.reasoningEffort {
            body["reasoning_effort"] = try reasoningEffortValue(
                effort,
                modelID: modelID,
                isReasoning: isReasoning
            )
        }

        if stream {
            body["stream"] = true
            // Required to receive token usage data in the final streaming chunk
            body["stream_options"] = ["include_usage": true]
        }

        body["messages"] = request.messages.flatMap { mapMessageToJSON($0) }

        if let systemPrompt = request.systemPrompt {
            let systemMsg: [String: Any] = ["role": "system", "content": systemPrompt]
            if var messages = body["messages"] as? [[String: Any]] {
                messages.insert(systemMsg, at: 0)
                body["messages"] = messages
            }
        }

        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { mapToolToJSON($0) }
        }

        if let format = request.responseFormat {
            body["response_format"] = try mapResponseFormat(format, options: options)
        }

        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("Failed to serialize request body")
            throw ArbiterError.invalidRequest(reason: "Failed to serialize request: \(error.localizedDescription)")
        }
    }

    func parseResponse(_ data: Data) throws -> AIResponse {
        let json = try parseJSON(data)

        let responseId = json["id"] as? String ?? ""
        let model = json["model"] as? String ?? defaultModel.rawValue

        let choices = json["choices"] as? [[String: Any]] ?? []
        let firstChoice = choices.first ?? [:]
        let message = firstChoice["message"] as? [String: Any] ?? [:]

        let toolCalls = extractToolCalls(from: message)
        let usage = extractUsage(from: json)
        var finishReason = mapFinishReason(firstChoice["finish_reason"] as? String)
        var textContent = message["content"] as? String ?? ""

        // A safety refusal arrives in its own field with `finish_reason: stop`,
        // so it would otherwise look like an ordinary empty answer. The text is
        // surfaced as the content rather than dropped.
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            finishReason = .refusal
            if textContent.isEmpty { textContent = refusal }
        }

        return AIResponse(
            id: responseId,
            content: textContent,
            model: model,
            provider: .openAI,
            toolCalls: toolCalls,
            usage: usage,
            finishReason: finishReason
        )
    }

    /// Parse one SSE `data:` payload.
    ///
    /// OpenAI spreads a turn across many chunks: text in `delta.content`, a
    /// tool call as an `id`/`name` header followed by argument fragments keyed
    /// by index, `finish_reason` on its own chunk, and — with
    /// `stream_options.include_usage` — token usage in a trailing chunk that
    /// carries no choices at all. `state` holds that partial work between
    /// chunks.
    ///
    /// Note that a completed tool call is reported more than once: on the chunk
    /// carrying `finish_reason` and again on the terminating chunk, which
    /// always lists every call of the turn. A consumer should take the calls
    /// from the chunk where `isComplete` is true rather than appending them
    /// from each chunk.
    func parseStreamEvent(_ eventData: String, state: inout OpenAIStreamState) -> AIStreamChunk? {
        if eventData == "[DONE]" {
            // Reached without a usage chunk on hosts that do not send one
            // (and on an interrupted OpenAI stream), so this has to be able to
            // terminate the stream on its own.
            state.completeOpenToolCalls()
            return finalChunk(state: state)
        }

        guard let data = eventData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let chunkUsage = extractUsage(from: json)
        if let chunkUsage {
            state.usage = chunkUsage
        }

        let choices = json["choices"] as? [[String: Any]] ?? []
        guard let firstChoice = choices.first else {
            // The usage-only trailing chunk: no choices, usage at top level.
            // It is the last thing before `[DONE]`, so it ends the stream.
            //
            // The test is whether *this* chunk carried usage, not whether any
            // chunk has: hosts emit other choice-less frames (Azure's
            // `prompt_filter_results`, proxy keep-alives), and treating one of
            // those as the end would truncate the response mid-generation.
            guard chunkUsage != nil else { return nil }
            state.completeOpenToolCalls()
            return finalChunk(state: state)
        }

        // Recorded before the content early-return below: OpenAI sends
        // `finish_reason` on its own chunk, but compatible hosts and proxies
        // sometimes attach it to the last content chunk, where returning first
        // would lose it.
        let reason = firstChoice["finish_reason"] as? String

        if let delta = firstChoice["delta"] as? [String: Any] {
            accumulateToolCallDeltas(delta, into: &state)

            if let refusal = delta["refusal"] as? String, !refusal.isEmpty {
                state.sawRefusal = true
            }

            if let content = delta["content"] as? String, !content.isEmpty {
                state.accumulated += content
                if let reason {
                    state.completeOpenToolCalls()
                    state.finishReason = state.sawRefusal ? .refusal : mapFinishReason(reason)
                }
                return AIStreamChunk(
                    delta: content,
                    accumulatedContent: state.accumulated,
                    isComplete: false,
                    finishReason: state.finishReason,
                    toolCalls: state.completedToolCalls.isEmpty ? nil : state.completedToolCalls,
                    provider: .openAI
                )
            }
        }

        guard let reason else { return nil }

        // Arguments have finished arriving, so partial calls can be parsed.
        state.completeOpenToolCalls()
        state.finishReason = state.sawRefusal ? .refusal : mapFinishReason(reason)
        // Deliberately not `isComplete`: with `include_usage` the usage chunk
        // still follows, and marking this one complete would end the stream
        // before the token counts arrive.
        return AIStreamChunk(
            delta: "",
            accumulatedContent: state.accumulated,
            isComplete: false,
            finishReason: state.finishReason,
            toolCalls: state.completedToolCalls.isEmpty ? nil : state.completedToolCalls,
            provider: .openAI
        )
    }
}

/// Pieces both OpenAI transports need: the Responses mapper reuses the same
/// argument decoding and strict-schema construction.
extension OpenAIMapper {
    /// Build the `json_schema` payload shared by both transports.
    ///
    /// The caller's schema arrives as a string; OpenAI wants a parsed object
    /// under a required `name`, and strict mode additionally requires every
    /// object to close `additionalProperties` and require all its properties.
    static func strictJSONSchema(_ schema: String, options: OpenAIOptions?) throws -> [String: Any] {
        let parsed = try JSONSchemaNormalizer.parseObject(schema)
        let strict = options?.strictStructuredOutputs ?? true
        return [
            "name": options?.structuredOutputName ?? OpenAIOptions.defaultStructuredOutputName,
            "strict": strict,
            "schema": strict ? JSONSchemaNormalizer.openAIStrict(parsed) : parsed,
        ]
    }

    /// Decode a tool call's arguments, which every OpenAI surface sends as a
    /// JSON *string* rather than an object.
    static func parseArguments(_ raw: String) -> JSONValue {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object([:])
        }
        return decoded
    }

}

extension OpenAIMapper {
    /// The terminating chunk, carrying whatever the turn accumulated.
    ///
    /// Also used by the provider when the byte stream ends without a `[DONE]`
    /// or usage chunk, so a turn always finishes with `isComplete`.
    func finalChunk(state: OpenAIStreamState) -> AIStreamChunk {
        AIStreamChunk(
            delta: "",
            accumulatedContent: state.accumulated,
            isComplete: true,
            usage: state.usage,
            finishReason: state.finishReason,
            toolCalls: state.completedToolCalls.isEmpty ? nil : state.completedToolCalls,
            provider: .openAI
        )
    }
}

private extension OpenAIMapper {
    /// Fold `delta.tool_calls` fragments into the per-index accumulators.
    ///
    /// The first fragment for an index carries `id` and `function.name`;
    /// later ones carry only slices of the argument JSON string.
    func accumulateToolCallDeltas(_ delta: [String: Any], into state: inout OpenAIStreamState) {
        guard let rawCalls = delta["tool_calls"] as? [[String: Any]] else { return }

        for raw in rawCalls {
            let id = raw["id"] as? String
            let index: Int
            if let explicit = raw["index"] as? Int {
                index = explicit
            } else if let id, !id.isEmpty {
                // A new call's header with no `index`. Defaulting to 0 would
                // make a second parallel call overwrite the first and splice
                // their argument JSON together, so it gets its own slot.
                index = state.openToolCalls.keys.max().map { $0 + 1 } ?? 0
            } else {
                // A bare argument fragment continues the most recent call.
                index = state.openToolCalls.keys.max() ?? 0
            }
            var partial = state.openToolCalls[index] ?? OpenAIPartialToolCall()

            if let id, !id.isEmpty {
                partial.id = id
            }
            if let function = raw["function"] as? [String: Any] {
                if let name = function["name"] as? String, !name.isEmpty {
                    // OpenAI sends the whole name once, but some proxies repeat
                    // it on every argument fragment. Appending a repeat would
                    // produce `get_weatherget_weather`, so an identical value is
                    // ignored and only genuinely new text is appended.
                    if partial.name.isEmpty {
                        partial.name = name
                    } else if partial.name != name {
                        partial.name += name
                    }
                }
                if let arguments = function["arguments"] as? String {
                    partial.partialJSON += arguments
                }
            }
            state.openToolCalls[index] = partial
        }
    }

    func mapMessageToJSON(_ message: Message) -> [[String: Any]] {
        // System messages handled separately via systemPrompt injection
        guard message.role != .system else { return [] }

        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .tool: role = "tool"
        case .system: return []
        }

        switch message.content {
        case .text(let text):
            return [["role": role, "content": text]]

        case .image(let source):
            let contentParts = buildImageContentParts(source)
            return [["role": role, "content": contentParts]]

        case .document:
            // Document input is not mapped for this provider yet.
            logger.error("Dropping document content: unsupported by this provider")
            return []

        case .toolCalls(let calls):
            return calls.isEmpty ? [] : [assistantToolCallMessage(content: nil, calls: calls)]

        case .toolResults(let results):
            return results.map { toolResultMessage($0) }

        case .mixed(let parts):
            return mapMixedContentToJSON(parts, role: role)
        }
    }

    /// OpenAI carries text and tool calls on one assistant message, but each tool
    /// result on its own `role: "tool"` message — so a mixed turn fans out.
    ///
    /// Results come first: they answer the preceding assistant `tool_calls` turn and
    /// must not be separated from it. A turn containing tool calls is emitted as
    /// `assistant` whatever role the caller gave it, since only an assistant message
    /// may carry `tool_calls`.
    func mapMixedContentToJSON(_ parts: [MessageContent], role: String) -> [[String: Any]] {
        let contentParts = flattenedContentParts(parts)
        let calls = parts.flatMap(\.allToolCalls)
        let results = parts.flatMap(\.allToolResults)

        var messages: [[String: Any]] = results.map { toolResultMessage($0) }
        if !calls.isEmpty {
            messages.append(assistantToolCallMessage(content: contentParts, calls: calls))
        } else if !contentParts.isEmpty {
            messages.append(["role": role, "content": contentParts])
        }
        return messages
    }

    func flattenedContentParts(_ parts: [MessageContent]) -> [[String: Any]] {
        parts.flatMap { part -> [[String: Any]] in
            switch part {
            case .mixed(let nested): flattenedContentParts(nested)
            default: [mapContentPartToJSON(part)].compactMap { $0 }
            }
        }
    }

    func assistantToolCallMessage(content: [[String: Any]]?, calls: [ToolCall]) -> [String: Any] {
        var message: [String: Any] = [
            "role": "assistant",
            "tool_calls": calls.map { mapToolCallToJSON($0) },
        ]
        // OpenAI wants the key present; null when the turn is tool calls only.
        if let content, !content.isEmpty {
            message["content"] = content
        } else {
            message["content"] = NSNull()
        }
        return message
    }

    func toolResultMessage(_ result: ToolResult) -> [String: Any] {
        ["role": "tool", "tool_call_id": result.toolCallId, "content": result.content]
    }

    func buildImageContentParts(_ source: ImageSource) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        switch source {
        case .base64(let data, let mimeType):
            parts.append([
                "type": "image_url",
                "image_url": ["url": "data:\(mimeType);base64,\(data)"],
            ])
        case .url(let url):
            parts.append([
                "type": "image_url",
                "image_url": ["url": url.absoluteString],
            ])
        }
        return parts
    }

    func mapContentPartToJSON(_ part: MessageContent) -> [String: Any]? {
        switch part {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let source):
            return buildImageContentParts(source).first
        default:
            return nil
        }
    }

    func mapToolToJSON(_ tool: ToolDefinition) -> [String: Any] {
        var functionDef: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if let schemaData = try? JSONEncoder().encode(tool.inputSchema),
           let schemaObj = try? JSONSerialization.jsonObject(with: schemaData) {
            functionDef["parameters"] = schemaObj
        }
        return ["type": "function", "function": functionDef]
    }

    func mapToolCallToJSON(_ call: ToolCall) -> [String: Any] {
        var arguments = "{}"
        if let argData = try? JSONEncoder().encode(call.arguments),
           let argString = String(data: argData, encoding: .utf8) {
            arguments = argString
        }
        return [
            "id": call.id,
            "type": "function",
            "function": ["name": call.name, "arguments": arguments],
        ]
    }

    /// Reject an effort a model does not publish support for, before the
    /// request is sent. Models whose accepted set is not documented take
    /// whatever the caller asked for.
    func reasoningEffortValue(
        _ effort: OpenAIReasoningEffort,
        modelID: String,
        isReasoning: Bool
    ) throws -> String {
        guard isReasoning else {
            throw ArbiterError.invalidRequest(
                reason: "Model \(modelID) is not a reasoning model and does not accept reasoning_effort"
            )
        }
        if let supported = OpenAIModel.named(modelID)?.supportedReasoningEfforts,
           !supported.contains(effort) {
            let allowed = supported.map(\.rawValue).sorted().joined(separator: ", ")
            throw ArbiterError.invalidRequest(
                reason: "Model \(modelID) does not accept reasoning_effort '\(effort.rawValue)'; supported: \(allowed)"
            )
        }
        return effort.rawValue
    }

    func mapResponseFormat(_ format: ResponseFormat, options: OpenAIOptions?) throws -> [String: Any] {
        switch format {
        case .json:
            return ["type": "json_object"]
        case .text:
            return ["type": "text"]
        case .structured(let schema):
            let jsonSchema = try Self.strictJSONSchema(schema, options: options)
            return ["type": "json_schema", "json_schema": jsonSchema]
        }
    }

    func extractToolCalls(from message: [String: Any]) -> [ToolCall] {
        guard let rawCalls = message["tool_calls"] as? [[String: Any]] else { return [] }

        return rawCalls.compactMap { raw in
            guard let callId = raw["id"] as? String,
                  let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }

            let argumentsString = function["arguments"] as? String ?? "{}"
            return ToolCall(id: callId, name: name, arguments: Self.parseArguments(argumentsString))
        }
    }

    func extractUsage(from json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any],
              let promptTokens = usage["prompt_tokens"] as? Int,
              let completionTokens = usage["completion_tokens"] as? Int else {
            return nil
        }
        // `prompt_tokens` already includes any tokens served from OpenAI's
        // prompt cache, and it is reported here as-is. Splitting the cached
        // count into `TokenUsage.cacheReadInputTokens` is deliberately left
        // alone: `TokenUsage.cost` discounts cache reads by a single fixed
        // ratio, which is right for Anthropic but wrong for OpenAI, where the
        // discount is per-model (a tenth on the GPT-5 family, but only a half
        // on GPT-4o). Splitting them without per-model rates would understate
        // spend on cache-heavy traffic, so unified cache accounting is left to
        // the roadmap item that adds those rates. `costPerMillionCachedInput`
        // already carries them.
        return TokenUsage(inputTokens: promptTokens, outputTokens: completionTokens)
    }

    func mapFinishReason(_ reason: String?) -> FinishReason? {
        guard let reason else { return nil }
        switch reason {
        case "stop": return .complete
        case "length": return .maxTokens
        case "tool_calls", "function_call": return .toolCall
        case "content_filter": return .contentFilter
        default: return nil
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
            logger.error("Failed to parse response JSON")
            throw ArbiterError.decodingFailed(context: "Invalid JSON: \(error.localizedDescription)")
        }
    }
}

/// Partial work carried between SSE chunks of one OpenAI stream.
struct OpenAIStreamState: Sendable {
    var accumulated: String = ""
    var usage: TokenUsage?
    var finishReason: FinishReason?
    /// Tool calls whose arguments are still streaming, keyed by `index`.
    var openToolCalls: [Int: OpenAIPartialToolCall] = [:]
    /// Every tool call completed so far this turn, in index order.
    var completedToolCalls: [ToolCall] = []
    /// Whether the model streamed a safety refusal instead of an answer.
    var sawRefusal: Bool = false

    init() {}

    /// Parse every open accumulator and move it to `completedToolCalls`.
    ///
    /// Idempotent: calling it again after the accumulators have drained is a
    /// no-op, so the finish chunk and `[DONE]` can both call it.
    mutating func completeOpenToolCalls() {
        guard !openToolCalls.isEmpty else { return }
        for index in openToolCalls.keys.sorted() {
            guard let partial = openToolCalls[index], let call = partial.completed() else { continue }
            completedToolCalls.append(call)
        }
        openToolCalls.removeAll()
    }
}

/// An OpenAI tool call whose arguments are still arriving as string fragments.
struct OpenAIPartialToolCall: Sendable {
    var id: String = ""
    var name: String = ""
    var partialJSON: String = ""

    /// Parse the accumulated fragments.
    ///
    /// A call with no arguments streams no fragments at all, and a truncated
    /// stream leaves unparseable text — both degrade to empty arguments rather
    /// than dropping the call. A fragment run that never carried a name is not
    /// a call at all and is discarded.
    func completed() -> ToolCall? {
        guard !name.isEmpty else {
            logger.error("Discarding streamed tool call fragment with no function name")
            return nil
        }
        if !partialJSON.isEmpty,
           partialJSON.data(using: .utf8).flatMap({ try? JSONDecoder().decode(JSONValue.self, from: $0) }) == nil {
            logger.error("Tool call \(name, privacy: .public) had unparseable streamed arguments")
        }
        return ToolCall(id: id, name: name, arguments: OpenAIMapper.parseArguments(partialJSON))
    }
}
