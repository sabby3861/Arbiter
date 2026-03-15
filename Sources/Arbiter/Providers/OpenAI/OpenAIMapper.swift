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
        var body: [String: Any] = [
            "model": request.model ?? defaultModel.rawValue,
        ]

        if let maxTokens = request.maxTokens {
            body["max_tokens"] = maxTokens
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if let topP = request.topP {
            body["top_p"] = topP
        }
        if stream {
            body["stream"] = true
            // Required to receive token usage data in the final streaming chunk
            body["stream_options"] = ["include_usage": true]
        }

        body["messages"] = request.messages.map { mapMessageToJSON($0) }
            .flatMap { $0 }

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
            body["response_format"] = mapResponseFormat(format)
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

        let textContent = message["content"] as? String ?? ""
        let toolCalls = extractToolCalls(from: message)
        let usage = extractUsage(from: json)
        let finishReason = mapFinishReason(firstChoice["finish_reason"] as? String)

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

    func parseStreamEvent(_ eventData: String, accumulated: inout String) -> AIStreamChunk? {
        if eventData == "[DONE]" {
            return AIStreamChunk(
                delta: "",
                accumulatedContent: accumulated,
                isComplete: true,
                provider: .openAI
            )
        }

        guard let data = eventData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any] else {
            return nil
        }

        return parseStreamDelta(delta, firstChoice: firstChoice, json: json, accumulated: &accumulated)
    }

    private func parseStreamDelta(
        _ delta: [String: Any],
        firstChoice: [String: Any],
        json: [String: Any],
        accumulated: inout String
    ) -> AIStreamChunk? {
        if let content = delta["content"] as? String, !content.isEmpty {
            accumulated += content
            return AIStreamChunk(
                delta: content,
                accumulatedContent: accumulated,
                isComplete: false,
                provider: .openAI
            )
        }

        if firstChoice["finish_reason"] as? String != nil {
            let usage = extractUsage(from: json)
            return AIStreamChunk(
                delta: "",
                accumulatedContent: accumulated,
                isComplete: true,
                usage: usage,
                provider: .openAI
            )
        }

        return nil
    }
}

private extension OpenAIMapper {
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

        case .toolCall(let call):
            return [["role": "assistant", "tool_calls": [mapToolCallToJSON(call)]]]

        case .toolResult(let result):
            return [["role": "tool", "tool_call_id": result.toolCallId, "content": result.content]]

        case .mixed(let parts):
            let contentParts = parts.compactMap { mapContentPartToJSON($0) }
            return [["role": role, "content": contentParts]]
        }
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

    func mapResponseFormat(_ format: ResponseFormat) -> [String: Any] {
        switch format {
        case .json:
            return ["type": "json_object"]
        case .text:
            return ["type": "text"]
        case .structured(let schema):
            return ["type": "json_schema", "json_schema": ["schema": schema]]
        }
    }

    func extractToolCalls(from message: [String: Any]) -> [ToolCall] {
        guard let rawCalls = message["tool_calls"] as? [[String: Any]] else { return [] }

        return rawCalls.compactMap { raw in
            guard let callId = raw["id"] as? String,
                  let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }

            let argumentsString = function["arguments"] as? String ?? "{}"
            let arguments: JSONValue
            if let argData = argumentsString.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: argData) {
                arguments = decoded
            } else {
                arguments = .object([:])
            }

            return ToolCall(id: callId, name: name, arguments: arguments)
        }
    }

    func extractUsage(from json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any],
              let promptTokens = usage["prompt_tokens"] as? Int,
              let completionTokens = usage["completion_tokens"] as? Int else {
            return nil
        }
        return TokenUsage(inputTokens: promptTokens, outputTokens: completionTokens)
    }

    func mapFinishReason(_ reason: String?) -> FinishReason? {
        guard let reason else { return nil }
        switch reason {
        case "stop": return .complete
        case "length": return .maxTokens
        case "tool_calls": return .toolCall
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
