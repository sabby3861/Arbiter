// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "GeminiMapper")

struct GeminiMapper: Sendable {
    private let defaultModel: GeminiModel

    init(defaultModel: GeminiModel) {
        self.defaultModel = defaultModel
    }

    func buildRequestBody(_ request: AIRequest) throws -> Data {
        var body: [String: Any] = [:]

        body["contents"] = request.messages.compactMap { mapMessageToJSON($0) }

        if let systemPrompt = request.systemPrompt {
            body["systemInstruction"] = [
                "parts": [["text": systemPrompt]],
            ]
        }

        var generationConfig: [String: Any] = [:]
        if let maxTokens = request.maxTokens {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if let temperature = request.temperature {
            generationConfig["temperature"] = temperature
        }
        if let topP = request.topP {
            generationConfig["topP"] = topP
        }
        if let format = request.responseFormat {
            applyResponseFormat(format, to: &generationConfig)
        }
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
        }

        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map { mapToolToJSON($0) }]]
        }

        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("Failed to serialize Gemini request body")
            throw SwiftAIError.invalidRequest(reason: "Failed to serialize: \(error.localizedDescription)")
        }
    }

    func parseResponse(_ data: Data) throws -> AIResponse {
        let json = try parseJSON(data)

        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let firstCandidate = candidates.first ?? [:]
        let content = firstCandidate["content"] as? [String: Any] ?? [:]
        let parts = content["parts"] as? [[String: Any]] ?? []

        let textContent = parts
            .filter { ($0["functionCall"] as? [String: Any]) == nil }
            .compactMap { $0["text"] as? String }
            .joined()

        let toolCalls = extractToolCalls(from: parts)
        let usage = extractUsage(from: json)
        let finishReason = mapFinishReason(firstCandidate["finishReason"] as? String)

        return AIResponse(
            id: UUID().uuidString,
            content: textContent,
            model: defaultModel.rawValue,
            provider: .gemini,
            toolCalls: toolCalls,
            usage: usage,
            finishReason: finishReason
        )
    }

    func parseStreamEvent(_ eventData: String, accumulated: inout String) -> AIStreamChunk? {
        guard let data = eventData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let candidates = json["candidates"] as? [[String: Any]] ?? []
        guard let firstCandidate = candidates.first else { return nil }

        let content = firstCandidate["content"] as? [String: Any] ?? [:]
        let parts = content["parts"] as? [[String: Any]] ?? []
        let deltaText = parts.compactMap { $0["text"] as? String }.joined()

        if !deltaText.isEmpty {
            accumulated += deltaText
            return AIStreamChunk(
                delta: deltaText,
                accumulatedContent: accumulated,
                isComplete: false,
                provider: .gemini
            )
        }

        let finishReason = firstCandidate["finishReason"] as? String
        if finishReason != nil {
            let usage = extractUsage(from: json)
            return AIStreamChunk(
                delta: "",
                accumulatedContent: accumulated,
                isComplete: true,
                usage: usage,
                provider: .gemini
            )
        }

        return nil
    }
}

private extension GeminiMapper {
    func mapMessageToJSON(_ message: Message) -> [String: Any]? {
        guard message.role != .system else { return nil }

        let role: String
        switch message.role {
        case .user, .tool: role = "user"
        case .assistant: role = "model"
        case .system: return nil
        }

        var parts: [[String: Any]] = []

        switch message.content {
        case .text(let text):
            parts.append(["text": text])

        case .image(let source):
            switch source {
            case .base64(let data, let mimeType):
                parts.append(["inlineData": ["mimeType": mimeType, "data": data]])
            case .url:
                break
            }

        case .toolCall(let call):
            var args: [String: Any] = [:]
            if let argData = try? JSONEncoder().encode(call.arguments),
               let argObj = try? JSONSerialization.jsonObject(with: argData) {
                args = argObj as? [String: Any] ?? [:]
            }
            parts.append(["functionCall": ["name": call.name, "args": args]])

        case .toolResult(let result):
            parts.append(["functionResponse": [
                "name": result.toolCallId,
                "response": ["result": result.content],
            ]])

        case .mixed(let contentParts):
            for part in contentParts {
                switch part {
                case .text(let text):
                    parts.append(["text": text])
                case .image(.base64(let data, let mimeType)):
                    parts.append(["inlineData": ["mimeType": mimeType, "data": data]])
                default:
                    break
                }
            }
        }

        guard !parts.isEmpty else { return nil }
        return ["role": role, "parts": parts]
    }

    func mapToolToJSON(_ tool: ToolDefinition) -> [String: Any] {
        var toolJSON: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if let schemaData = try? JSONEncoder().encode(tool.inputSchema),
           let schemaObj = try? JSONSerialization.jsonObject(with: schemaData) {
            toolJSON["parameters"] = schemaObj
        }
        return toolJSON
    }

    func applyResponseFormat(_ format: ResponseFormat, to config: inout [String: Any]) {
        switch format {
        case .json:
            config["responseMimeType"] = "application/json"
        case .text:
            config["responseMimeType"] = "text/plain"
        case .structured(let schema):
            config["responseMimeType"] = "application/json"
            config["responseSchema"] = schema
        }
    }

    func extractToolCalls(from parts: [[String: Any]]) -> [ToolCall] {
        parts.compactMap { part in
            guard let functionCall = part["functionCall"] as? [String: Any],
                  let name = functionCall["name"] as? String else { return nil }

            let arguments: JSONValue
            if let args = functionCall["args"],
               let argData = try? JSONSerialization.data(withJSONObject: args),
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: argData) {
                arguments = decoded
            } else {
                arguments = .object([:])
            }

            return ToolCall(id: UUID().uuidString, name: name, arguments: arguments)
        }
    }

    func extractUsage(from json: [String: Any]) -> TokenUsage? {
        guard let metadata = json["usageMetadata"] as? [String: Any],
              let promptTokens = metadata["promptTokenCount"] as? Int,
              let candidateTokens = metadata["candidatesTokenCount"] as? Int else {
            return nil
        }
        return TokenUsage(inputTokens: promptTokens, outputTokens: candidateTokens)
    }

    func mapFinishReason(_ reason: String?) -> FinishReason? {
        guard let reason else { return nil }
        switch reason {
        case "STOP": return .complete
        case "MAX_TOKENS": return .maxTokens
        case "SAFETY": return .contentFilter
        default: return nil
        }
    }

    func parseJSON(_ data: Data) throws -> [String: Any] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwiftAIError.decodingFailed(context: "Response is not a JSON object")
            }
            return json
        } catch let swiftAIError as SwiftAIError {
            throw swiftAIError
        } catch {
            logger.error("Failed to parse Gemini response JSON")
            throw SwiftAIError.decodingFailed(context: "Invalid JSON: \(error.localizedDescription)")
        }
    }
}
