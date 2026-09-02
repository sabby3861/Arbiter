// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "GeminiMapper")

struct GeminiMapper: Sendable {
    private let defaultModel: GeminiModel

    init(defaultModel: GeminiModel) {
        self.defaultModel = defaultModel
    }

    func buildRequestBody(_ request: AIRequest) throws -> Data {
        var body: [String: Any] = [:]

        body["contents"] = request.messages.flatMap { mapMessageToJSON($0) }

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
            throw ArbiterError.invalidRequest(reason: "Failed to serialize: \(error.localizedDescription)")
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

        let responseId = (json["responseId"] as? String)
            ?? (json["id"] as? String)
            ?? "gemini-\(UUID().uuidString)"

        return AIResponse(
            id: responseId,
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

        let finishReasonStr = firstCandidate["finishReason"] as? String
        if finishReasonStr != nil {
            let usage = extractUsage(from: json)
            return AIStreamChunk(
                delta: "",
                accumulatedContent: accumulated,
                isComplete: true,
                usage: usage,
                finishReason: mapFinishReason(finishReasonStr),
                provider: .gemini
            )
        }

        return nil
    }
}

private extension GeminiMapper {
    func mapMessageToJSON(_ message: Message) -> [[String: Any]] {
        guard message.role != .system else { return [] }

        switch message.content {
        case .text, .image, .document:
            let parts = plainContentParts(message.content)
            return parts.isEmpty ? [] : [["role": role(for: message.role), "parts": parts]]

        case .toolCalls(let calls):
            return calls.isEmpty ? [] : [functionCallContent(leadingParts: [], calls: calls)]

        case .toolResults(let results):
            return results.isEmpty ? [] : [functionResponseContent(results: results)]

        case .mixed(let parts):
            return mapMixedContentToJSON(parts, role: message.role)
        }
    }

    /// Gemini expects `functionCall` parts on a `model` turn and `functionResponse`
    /// parts on a `user` turn, so a mixed turn carrying both is split in two.
    func mapMixedContentToJSON(_ parts: [MessageContent], role messageRole: Role) -> [[String: Any]] {
        let plain = parts.flatMap { plainContentParts($0) }
        let calls = parts.flatMap(\.allToolCalls)
        let results = parts.flatMap(\.allToolResults)

        var contents: [[String: Any]] = []
        if !results.isEmpty {
            contents.append(functionResponseContent(
                results: results,
                trailingParts: calls.isEmpty ? plain : []
            ))
        }
        if !calls.isEmpty {
            contents.append(functionCallContent(leadingParts: plain, calls: calls))
        } else if results.isEmpty, !plain.isEmpty {
            contents.append(["role": role(for: messageRole), "parts": plain])
        }
        return contents
    }

    /// Text and image parts only — tool parts are placed by the caller, which has
    /// to control the turn role they land on.
    func plainContentParts(_ content: MessageContent) -> [[String: Any]] {
        switch content {
        case .text(let text):
            return [["text": text]]
        case .image(.base64(let data, let mimeType)):
            return [["inlineData": ["mimeType": mimeType, "data": data]]]
        case .image(.url):
            return []
        case .document:
            // Document input is not mapped for this provider yet.
            logger.error("Dropping document content: unsupported by this provider")
            return []
        case .mixed(let parts):
            return parts.flatMap { plainContentParts($0) }
        case .toolCalls, .toolResults:
            return []
        }
    }

    func functionCallContent(leadingParts: [[String: Any]], calls: [ToolCall]) -> [String: Any] {
        let callParts: [[String: Any]] = calls.map { call in
            ["functionCall": ["name": call.name, "args": call.arguments.foundationObject]]
        }
        return ["role": "model", "parts": leadingParts + callParts]
    }

    func functionResponseContent(
        results: [ToolResult],
        trailingParts: [[String: Any]] = []
    ) -> [String: Any] {
        let responseParts: [[String: Any]] = results.map { result in
            // Gemini correlates a response to its call by function name, not call id.
            ["functionResponse": [
                "name": result.name ?? result.toolCallId,
                "response": ["result": result.content],
            ]]
        }
        return ["role": "user", "parts": responseParts + trailingParts]
    }

    func role(for role: Role) -> String {
        switch role {
        case .assistant: "model"
        case .user, .tool, .system: "user"
        }
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
                throw ArbiterError.decodingFailed(context: "Response is not a JSON object")
            }
            return json
        } catch let swiftAIError as ArbiterError {
            throw swiftAIError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Failed to parse Gemini response JSON")
            throw ArbiterError.decodingFailed(context: "Invalid JSON: \(error.localizedDescription)")
        }
    }
}
