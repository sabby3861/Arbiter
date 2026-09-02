// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "OllamaMapper")

struct OllamaMapper: Sendable {
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
        if !options.isEmpty {
            body["options"] = options
        }

        if let format = request.responseFormat, format == .json {
            body["format"] = "json"
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
        let usage = extractUsage(from: json)
        let finishReason = mapFinishReason(from: json)

        return AIResponse(
            id: "ollama-\(UUID().uuidString)",
            content: textContent,
            model: model,
            provider: .ollama,
            usage: usage,
            finishReason: finishReason
        )
    }

    func parseStreamLine(_ line: String, accumulated: inout String) -> AIStreamChunk? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let isDone = json["done"] as? Bool ?? false
        let message = json["message"] as? [String: Any] ?? [:]
        let deltaContent = message["content"] as? String ?? ""

        if !deltaContent.isEmpty {
            accumulated += deltaContent
        }

        if isDone {
            let usage = extractUsage(from: json)
            return AIStreamChunk(
                delta: deltaContent,
                accumulatedContent: accumulated,
                isComplete: true,
                usage: usage,
                provider: .ollama
            )
        }

        guard !deltaContent.isEmpty else { return nil }

        return AIStreamChunk(
            delta: deltaContent,
            accumulatedContent: accumulated,
            isComplete: false,
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

    func toolResultMessage(_ result: ToolResult) -> [String: Any] {
        var message: [String: Any] = ["role": "tool", "content": result.content]
        if let name = result.name {
            message["tool_name"] = name
        }
        return message
    }

    func mapFinishReason(from json: [String: Any]) -> FinishReason {
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
