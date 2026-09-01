// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "OpenAIResponsesMapper")

/// Maps between Arbiter's unified types and OpenAI's Responses API
/// (`POST /v1/responses`).
///
/// Not a re-encoding of Chat Completions: the conversation is a flat `input`
/// list of typed items rather than a message list, the system prompt moves to
/// `instructions`, function tools lose their nested `function` wrapper, tool
/// results become their own `function_call_output` items, structured output
/// moves from `response_format` to `text.format`, and usage is reported as
/// `input_tokens`/`output_tokens`.
///
/// Verified 2026-09-01 against
/// https://developers.openai.com/api/docs/api-reference/responses/create
struct OpenAIResponsesMapper: Sendable {
    private let defaultModel: OpenAIModel

    init(defaultModel: OpenAIModel) {
        self.defaultModel = defaultModel
    }

    func buildRequestBody(_ request: AIRequest, stream: Bool) throws -> Data {
        let modelID = request.model ?? defaultModel.rawValue
        let options = request.providerOptions[.openAI] as? OpenAIOptions
        let isReasoning = OpenAIModel.isReasoningModel(id: modelID)

        var body: [String: Any] = [
            "model": modelID,
            "input": request.messages.flatMap { mapMessageToItems($0) },
        ]

        if let systemPrompt = request.systemPrompt {
            body["instructions"] = systemPrompt
        }
        if let maxTokens = request.maxTokens {
            // One name on this transport, whether or not the model reasons.
            body["max_output_tokens"] = maxTokens
        }
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
            body["reasoning"] = ["effort": effort.rawValue]
        }
        if let store = options?.store {
            body["store"] = store
        }
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { mapToolToJSON($0) }
        }
        if let format = request.responseFormat {
            body["text"] = ["format": try mapTextFormat(format, options: options)]
        }
        if stream {
            body["stream"] = true
        }

        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("Failed to serialize request body")
            throw ArbiterError.invalidRequest(reason: "Failed to serialize request: \(error.localizedDescription)")
        }
    }

    func parseResponse(_ data: Data) throws -> AIResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArbiterError.decodingFailed(context: "Response is not a JSON object")
        }

        let responseId = json["id"] as? String ?? ""
        let model = json["model"] as? String ?? defaultModel.rawValue
        let output = json["output"] as? [[String: Any]] ?? []

        var text = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var refusal: String?

        for item in output {
            switch item["type"] as? String {
            case "message":
                for part in item["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "output_text":
                        text += part["text"] as? String ?? ""
                    case "refusal":
                        refusal = part["refusal"] as? String
                    default:
                        continue
                    }
                }
            case "reasoning":
                // Only the summary is readable; `encrypted_content` is opaque
                // and has nowhere to live in the unified response.
                for part in item["summary"] as? [[String: Any]] ?? [] {
                    reasoning += part["text"] as? String ?? ""
                }
            case "function_call":
                guard let name = item["name"] as? String else { continue }
                // `call_id` is the handle a `function_call_output` must quote;
                // `id` identifies the output item itself, so it is the wrong
                // one to round-trip.
                let callId = item["call_id"] as? String ?? item["id"] as? String ?? ""
                let arguments = item["arguments"] as? String ?? "{}"
                toolCalls.append(
                    ToolCall(id: callId, name: name, arguments: OpenAIMapper.parseArguments(arguments))
                )
            default:
                continue
            }
        }

        return AIResponse(
            id: responseId,
            content: text.isEmpty ? (refusal ?? "") : text,
            model: model,
            provider: .openAI,
            toolCalls: toolCalls,
            usage: extractUsage(from: json),
            finishReason: finishReason(json: json, toolCalls: toolCalls, refusal: refusal),
            reasoning: reasoning.isEmpty ? nil : reasoning
        )
    }
}

private extension OpenAIResponsesMapper {
    /// Why the turn ended.
    ///
    /// The Responses API reports this as a `status` plus, when the turn was cut
    /// short, an `incomplete_details.reason` — there is no single
    /// `finish_reason` field to map.
    func finishReason(json: [String: Any], toolCalls: [ToolCall], refusal: String?) -> FinishReason? {
        if let reason = (json["incomplete_details"] as? [String: Any])?["reason"] as? String {
            switch reason {
            case "max_tokens": return .maxTokens
            case "content_filter": return .contentFilter
            default: break
            }
        }
        if refusal != nil { return .refusal }
        if !toolCalls.isEmpty { return .toolCall }

        switch json["status"] as? String {
        case "completed": return .complete
        case "incomplete": return .maxTokens
        case "failed": return .error
        default: return nil
        }
    }

    func extractUsage(from json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any],
              let inputTokens = usage["input_tokens"] as? Int,
              let outputTokens = usage["output_tokens"] as? Int else {
            return nil
        }
        // `input_tokens` already includes cache hits and is reported as-is, for
        // the same reason as on Chat Completions: `TokenUsage.cost` applies one
        // fixed cache discount, and OpenAI's is per-model.
        return TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// Turn one unified message into Responses `input` items.
    ///
    /// A turn can produce several: tool results are their own items, and an
    /// assistant turn with both text and calls splits into a message item plus
    /// one `function_call` item per call.
    func mapMessageToItems(_ message: Message) -> [[String: Any]] {
        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .system: role = "system"
        // A tool result is not a role on this transport; it is an item type,
        // handled below from the content.
        case .tool: role = "user"
        }

        switch message.content {
        case .text(let text):
            return [messageItem(role: role, parts: [textPart(text, role: role)])]

        case .image(let source):
            return [messageItem(role: role, parts: [imagePart(source)])]

        case .document:
            logger.error("Dropping document content: unsupported by this provider")
            return []

        case .toolCalls(let calls):
            return calls.map { functionCallItem($0) }

        case .toolResults(let results):
            return results.map { functionCallOutputItem($0) }

        case .mixed(let parts):
            let results = parts.flatMap(\.allToolResults).map { functionCallOutputItem($0) }
            let contentParts = flattenedParts(parts, role: role)
            let calls = parts.flatMap(\.allToolCalls).map { functionCallItem($0) }

            // Results first: they answer the calls of the previous turn and
            // must not be separated from them.
            var items = results
            if !contentParts.isEmpty {
                items.append(messageItem(role: role, parts: contentParts))
            }
            items.append(contentsOf: calls)
            return items
        }
    }

    func flattenedParts(_ parts: [MessageContent], role: String) -> [[String: Any]] {
        parts.flatMap { part -> [[String: Any]] in
            switch part {
            case .text(let text): [textPart(text, role: role)]
            case .image(let source): [imagePart(source)]
            case .mixed(let nested): flattenedParts(nested, role: role)
            default: []
            }
        }
    }

    func messageItem(role: String, parts: [[String: Any]]) -> [String: Any] {
        ["type": "message", "role": role, "content": parts]
    }

    /// Text parts are discriminated by direction, not just by being text: an
    /// assistant turn being replayed carries `output_text`, everything the
    /// caller sends carries `input_text`.
    func textPart(_ text: String, role: String) -> [String: Any] {
        ["type": role == "assistant" ? "output_text" : "input_text", "text": text]
    }

    func imagePart(_ source: ImageSource) -> [String: Any] {
        switch source {
        case .base64(let data, let mimeType):
            ["type": "input_image", "image_url": "data:\(mimeType);base64,\(data)"]
        case .url(let url):
            ["type": "input_image", "image_url": url.absoluteString]
        }
    }

    func functionCallItem(_ call: ToolCall) -> [String: Any] {
        var arguments = "{}"
        if let argData = try? JSONEncoder().encode(call.arguments),
           let argString = String(data: argData, encoding: .utf8) {
            arguments = argString
        }
        return [
            "type": "function_call",
            "call_id": call.id,
            "name": call.name,
            "arguments": arguments,
        ]
    }

    func functionCallOutputItem(_ result: ToolResult) -> [String: Any] {
        ["type": "function_call_output", "call_id": result.toolCallId, "output": result.content]
    }

    /// Function tools are flat here — `name`/`description`/`parameters` sit at
    /// the top level rather than inside a nested `function` object.
    func mapToolToJSON(_ tool: ToolDefinition) -> [String: Any] {
        var toolDef: [String: Any] = [
            "type": "function",
            "name": tool.name,
            "description": tool.description,
        ]
        if let schemaData = try? JSONEncoder().encode(tool.inputSchema),
           let schemaObj = try? JSONSerialization.jsonObject(with: schemaData) {
            toolDef["parameters"] = schemaObj
        }
        return toolDef
    }

    /// `text.format` — the same three modes as `response_format`, but with the
    /// JSON-schema keys inline rather than nested under `json_schema`.
    func mapTextFormat(_ format: ResponseFormat, options: OpenAIOptions?) throws -> [String: Any] {
        switch format {
        case .text:
            return ["type": "text"]
        case .json:
            return ["type": "json_object"]
        case .structured(let schema):
            var payload = try OpenAIMapper.strictJSONSchema(schema, options: options)
            payload["type"] = "json_schema"
            return payload
        }
    }
}
