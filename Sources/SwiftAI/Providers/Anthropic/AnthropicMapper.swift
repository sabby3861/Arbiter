// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "AnthropicMapper")

/// Maps between SwiftAI's unified types and Anthropic API JSON
struct AnthropicMapper: Sendable {
    private let defaultModel: AnthropicModel

    init(defaultModel: AnthropicModel) {
        self.defaultModel = defaultModel
    }

    func buildRequestBody(_ request: AIRequest, stream: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": request.model ?? defaultModel.rawValue,
            "max_tokens": request.maxTokens ?? 1024,
        ]

        if stream {
            body["stream"] = true
        }

        if let temperature = request.temperature {
            body["temperature"] = temperature
        }

        if let topP = request.topP {
            body["top_p"] = topP
        }

        if let systemPrompt = request.systemPrompt {
            body["system"] = systemPrompt
        }

        body["messages"] = request.messages.compactMap { mapMessageToJSON($0) }

        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { mapToolToJSON($0) }
        }

        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("Failed to serialize request body")
            throw SwiftAIError.invalidRequest(reason: "Failed to serialize request: \(error.localizedDescription)")
        }
    }

    func parseResponse(_ data: Data) throws -> AIResponse {
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwiftAIError.decodingFailed(context: "Response is not a JSON object")
            }
            json = parsed
        } catch let swiftAIError as SwiftAIError {
            throw swiftAIError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Failed to parse response JSON")
            throw SwiftAIError.decodingFailed(context: "Invalid JSON: \(error.localizedDescription)")
        }

        let responseId = json["id"] as? String ?? ""
        let model = json["model"] as? String ?? defaultModel.rawValue

        let textContent = extractTextContent(from: json)
        let toolCalls = extractToolCalls(from: json)
        let usage = extractUsage(from: json)
        let finishReason = mapStopReason(json["stop_reason"] as? String)

        return AIResponse(
            id: responseId,
            content: textContent,
            model: model,
            provider: .anthropic,
            toolCalls: toolCalls,
            usage: usage,
            finishReason: finishReason
        )
    }

    /// Parse a single SSE event during streaming.
    ///
    /// Anthropic's streaming API splits usage across two events:
    /// - `message_start` contains `input_tokens` in `message.usage`
    /// - `message_delta` contains `output_tokens` in `usage`
    /// We capture both to build a complete `TokenUsage`.
    func parseStreamEvent(
        _ eventData: String,
        accumulated: inout String,
        streamInputTokens: inout Int?
    ) -> AIStreamChunk? {
        guard let data = eventData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["type"] as? String else {
            return nil
        }

        switch eventType {
        case "message_start":
            // Capture input token count from the initial message event
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               let inputTokens = usage["input_tokens"] as? Int {
                streamInputTokens = inputTokens
            }
            return nil

        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any],
                  let text = delta["text"] as? String else {
                return nil
            }
            accumulated += text
            return AIStreamChunk(
                delta: text,
                accumulatedContent: accumulated,
                isComplete: false,
                provider: .anthropic
            )

        case "message_delta":
            let outputTokens = (json["usage"] as? [String: Any])?["output_tokens"] as? Int
            let usage: TokenUsage?
            if let output = outputTokens {
                usage = TokenUsage(
                    inputTokens: streamInputTokens ?? 0,
                    outputTokens: output
                )
            } else {
                usage = nil
            }
            let stopReason = (json["delta"] as? [String: Any])?["stop_reason"] as? String
            return AIStreamChunk(
                delta: "",
                accumulatedContent: accumulated,
                isComplete: true,
                usage: usage,
                finishReason: mapStopReason(stopReason),
                provider: .anthropic
            )

        default:
            return nil
        }
    }
}

// Helpers for JSON mapping
private extension AnthropicMapper {
    func mapMessageToJSON(_ message: Message) -> [String: Any]? {
        guard message.role != .system else { return nil }

        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .tool: role = "user"
        case .system: return nil
        }

        let content: Any
        switch message.content {
        case .text(let text):
            content = text

        case .image(let source):
            content = [imageContentBlock(source)].compactMap { $0 }

        case .toolCall:
            return nil

        case .toolResult(let result):
            content = [[
                "type": "tool_result",
                "tool_use_id": result.toolCallId,
                "content": result.content,
            ]]

        case .mixed(let parts):
            content = parts.compactMap { mapContentPartToJSON($0) }
        }

        return ["role": role, "content": content]
    }

    func mapContentPartToJSON(_ part: MessageContent) -> [String: Any]? {
        switch part {
        case .text(let text):
            return textContentBlock(text)
        case .image(let source):
            return imageContentBlock(source)
        default:
            return nil
        }
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
            // Anthropic API requires base64 for images
            return nil
        }
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

    func extractTextContent(from json: [String: Any]) -> String {
        guard let contentBlocks = json["content"] as? [[String: Any]] else {
            return ""
        }

        return contentBlocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    func extractToolCalls(from json: [String: Any]) -> [ToolCall] {
        guard let contentBlocks = json["content"] as? [[String: Any]] else {
            return []
        }

        return contentBlocks
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

        return TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
    }

    func mapStopReason(_ reason: String?) -> FinishReason? {
        guard let reason else { return nil }
        switch reason {
        case "end_turn": return .complete
        case "max_tokens": return .maxTokens
        case "tool_use": return .toolCall
        case "content_filter": return .contentFilter
        default: return nil
        }
    }
}
