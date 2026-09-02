// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "GeminiMapper")

/// What a Gemini stream has produced so far.
///
/// A Gemini stream reports a function call as one complete `functionCall` part
/// rather than as argument fragments, but the parts still arrive across events —
/// so the turn's calls have to be carried between them to be reported together
/// on the final chunk.
struct GeminiStreamState {
    /// Text emitted so far, thought summaries excluded.
    var accumulatedContent = ""
    /// Every function call seen this turn, in arrival order.
    var toolCalls: [ToolCall] = []
    /// The most recent usage report. Gemini repeats it as the turn grows.
    var usage: TokenUsage?

    init() {}
}

struct GeminiMapper: Sendable {
    /// Prefix marking a call id Arbiter invented because the API sent none.
    ///
    /// Gemini's `id` on a function call is optional, but when it is present the
    /// matching `functionResponse` must echo it. A synthesised id would not
    /// match anything, so this prefix is how the replay path tells the two
    /// apart.
    static let synthesisedCallIDPrefix = "gemini-call-"

    private let defaultModel: GeminiModel

    init(defaultModel: GeminiModel) {
        self.defaultModel = defaultModel
    }

    func buildRequestBody(_ request: AIRequest) throws -> Data {
        // A caller may name a model Arbiter does not know (a preview, or a
        // proxy's own alias). Per-model rules are only applied when the model
        // is recognised; otherwise the caller's values pass through untouched.
        let model = GeminiModel.named(request.model ?? defaultModel.rawValue)
        let options = request.providerOptions[.gemini] as? GeminiOptions

        var body: [String: Any] = [:]

        // Only ids the model itself issued may be echoed back on a function
        // response, so the replay path needs to know which ids this
        // conversation actually contains.
        let knownCallIDs = Set(
            request.messages
                .flatMap { $0.content.allToolCalls }
                .map(\.id)
        )
        body["contents"] = request.messages.flatMap {
            mapMessageToJSON($0, knownCallIDs: knownCallIDs)
        }

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
            try applyResponseFormat(format, to: &generationConfig)
        }
        if let thinkingConfig = try thinkingConfigJSON(options: options, model: model) {
            generationConfig["thinkingConfig"] = thinkingConfig
        }
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
        }

        var tools: [[String: Any]] = []
        if let requestTools = request.tools, !requestTools.isEmpty {
            tools.append(["functionDeclarations": requestTools.map { mapToolToJSON($0) }])
        }
        if options?.googleSearch == true {
            // Grounding is a tool of its own and does not need — or belong in —
            // the function-declaration entry, so it is appended whether or not
            // the caller declared any functions.
            tools.append(["google_search": [String: Any]()])
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }

        // `safetySettings` and `cachedContent` are request-level fields, not
        // members of `generationConfig`.
        if let safetySettings = options?.safetySettings, !safetySettings.isEmpty {
            body["safetySettings"] = safetySettings.map {
                ["category": $0.category.rawValue, "threshold": $0.threshold.rawValue]
            }
        }
        if let cachedContent = options?.cachedContent, !cachedContent.isEmpty {
            body["cachedContent"] = cachedContent
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

        let textContent = answerText(from: parts)
        let thinking = extractThinking(from: parts)
        let toolCalls = extractToolCalls(from: parts)
        let usage = extractUsage(from: json)
        let finishReason = mapFinishReason(
            firstCandidate["finishReason"] as? String,
            hasToolCalls: !toolCalls.isEmpty
        )

        let responseId = (json["responseId"] as? String)
            ?? (json["id"] as? String)
            ?? "gemini-\(UUID().uuidString)"

        return AIResponse(
            id: responseId,
            content: textContent,
            model: (json["modelVersion"] as? String) ?? defaultModel.rawValue,
            provider: .gemini,
            toolCalls: toolCalls,
            usage: usage,
            finishReason: finishReason,
            reasoning: thinking.isEmpty ? nil : thinking.map(\.text).joined(separator: "\n"),
            citations: extractCitations(from: firstCandidate),
            thinking: thinking
        )
    }

    /// Turn one SSE payload into a chunk, or `nil` when it carries nothing new.
    ///
    /// Grounding metadata arrives incrementally on a stream and
    /// ``AIStreamChunk`` has nowhere to carry citations, so streamed grounding
    /// sources are not surfaced; use `generate` when the citations matter.
    func parseStreamEvent(_ eventData: String, state: inout GeminiStreamState) -> AIStreamChunk? {
        guard let data = eventData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let candidates = json["candidates"] as? [[String: Any]] ?? []
        guard let firstCandidate = candidates.first else { return nil }

        let content = firstCandidate["content"] as? [String: Any] ?? [:]
        let parts = content["parts"] as? [[String: Any]] ?? []

        let deltaText = answerText(from: parts)
        let newCalls = extractToolCalls(from: parts)
        state.accumulatedContent += deltaText
        state.toolCalls += newCalls
        if let usage = extractUsage(from: json) {
            state.usage = usage
        }

        let finishReasonString = firstCandidate["finishReason"] as? String
        // A finish event can carry text of its own, so the terminal chunk is
        // built from this event's delta rather than instead of it.
        if finishReasonString != nil {
            return AIStreamChunk(
                delta: deltaText,
                accumulatedContent: state.accumulatedContent,
                isComplete: true,
                usage: state.usage,
                finishReason: mapFinishReason(
                    finishReasonString,
                    hasToolCalls: !state.toolCalls.isEmpty
                ),
                toolCalls: state.toolCalls.isEmpty ? nil : state.toolCalls,
                provider: .gemini
            )
        }

        guard !deltaText.isEmpty || !newCalls.isEmpty else { return nil }

        return AIStreamChunk(
            delta: deltaText,
            accumulatedContent: state.accumulatedContent,
            isComplete: false,
            toolCalls: newCalls.isEmpty ? nil : newCalls,
            provider: .gemini
        )
    }

    /// The terminal chunk for a stream that ended without a finish event, or
    /// `nil` when the turn produced nothing at all.
    ///
    /// The connection can simply close — no candidate ever carries a
    /// `finishReason` — and then nothing this turn is marked complete, which
    /// strands the accumulated usage and, worse, the tool calls the loop is
    /// waiting on.
    ///
    /// A turn that produced *nothing* is a different failure, and inventing an
    /// empty completed chunk for it would disguise a dead connection as a model
    /// that answered with silence. That case reports no chunk, which is what
    /// the runtime raises a stream error on.
    func finalChunk(state: GeminiStreamState) -> AIStreamChunk? {
        guard !state.accumulatedContent.isEmpty || !state.toolCalls.isEmpty || state.usage != nil
        else { return nil }

        return AIStreamChunk(
            delta: "",
            accumulatedContent: state.accumulatedContent,
            isComplete: true,
            usage: state.usage,
            // The turn was cut short, so the only finish reason that can be
            // asserted is the one the collected calls imply.
            finishReason: state.toolCalls.isEmpty ? nil : .toolCall,
            toolCalls: state.toolCalls.isEmpty ? nil : state.toolCalls,
            provider: .gemini
        )
    }
}

// MARK: - Request

private extension GeminiMapper {
    func mapMessageToJSON(_ message: Message, knownCallIDs: Set<String>) -> [[String: Any]] {
        guard message.role != .system else { return [] }

        switch message.content {
        case .text, .image, .document:
            let parts = plainContentParts(message.content)
            return parts.isEmpty ? [] : [["role": role(for: message.role), "parts": parts]]

        case .toolCalls(let calls):
            return calls.isEmpty ? [] : [functionCallContent(leadingParts: [], calls: calls)]

        case .toolResults(let results):
            return results.isEmpty ? [] : [functionResponseContent(results: results, knownCallIDs: knownCallIDs)]

        case .thinking:
            // A thought summary is not replayed. Gemini requires a signature
            // back unchanged only on the *function call* that produced it —
            // which rides on `ToolCall.signature` — and a `ThinkingBlock`
            // carries no record of which provider signed it, so replaying one
            // here would eventually send another provider's opaque signature to
            // Gemini, which validates it and rejects the request.
            return []

        case .mixed(let parts):
            return mapMixedContentToJSON(parts, role: message.role, knownCallIDs: knownCallIDs)
        }
    }

    /// Gemini expects `functionCall` parts on a `model` turn and `functionResponse`
    /// parts on a `user` turn, so a mixed turn carrying both is split in two.
    func mapMixedContentToJSON(
        _ parts: [MessageContent],
        role messageRole: Role,
        knownCallIDs: Set<String>
    ) -> [[String: Any]] {
        let plain = parts.flatMap { plainContentParts($0) }
        let calls = parts.flatMap(\.allToolCalls)
        let results = parts.flatMap(\.allToolResults)

        var contents: [[String: Any]] = []
        if !results.isEmpty {
            contents.append(functionResponseContent(
                results: results,
                knownCallIDs: knownCallIDs,
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

    /// Text and image parts only — tool parts are placed by the caller, which
    /// has to control the turn role they land on, and thinking is not replayed
    /// to this provider at all.
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
        case .toolCalls, .toolResults, .thinking:
            return []
        }
    }

    func functionCallContent(leadingParts: [[String: Any]], calls: [ToolCall]) -> [String: Any] {
        let callParts: [[String: Any]] = calls.map { call in
            var functionCall: [String: Any] = [
                "name": call.name,
                "args": call.arguments.foundationObject,
            ]
            if !call.id.hasPrefix(Self.synthesisedCallIDPrefix) {
                functionCall["id"] = call.id
            }
            var part: [String: Any] = ["functionCall": functionCall]
            // The signature belongs to this part alone; it is never merged with
            // another part or concatenated with a second signature.
            if let signature = call.signature {
                part["thoughtSignature"] = signature
            }
            return part
        }
        return ["role": "model", "parts": leadingParts + callParts]
    }

    func functionResponseContent(
        results: [ToolResult],
        knownCallIDs: Set<String>,
        trailingParts: [[String: Any]] = []
    ) -> [String: Any] {
        let responseParts: [[String: Any]] = results.map { result in
            var functionResponse: [String: Any] = [
                // Gemini also correlates a response to its call by function name.
                "name": result.name ?? result.toolCallId,
                "response": ["result": result.content],
            ]
            // An id is echoed only when this conversation's own model turn
            // issued it: an id Arbiter invented, or one carried over from
            // another provider's history, matches no call here.
            if !result.toolCallId.hasPrefix(Self.synthesisedCallIDPrefix),
               knownCallIDs.contains(result.toolCallId) {
                functionResponse["id"] = result.toolCallId
            }
            return ["functionResponse": functionResponse]
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
        // Sent as written: `parameters` is a `Schema`, the OpenAPI subset, which
        // implements `pattern` and the length bounds the response-schema pass
        // strips — so normalising here would drop constraints the field honours.
        if let schemaData = try? JSONEncoder().encode(tool.inputSchema),
           let schemaObj = try? JSONSerialization.jsonObject(with: schemaData) {
            toolJSON["parameters"] = schemaObj
        }
        return toolJSON
    }

    /// Map the requested response format onto `generationConfig`.
    ///
    /// A schema goes in `responseFormat.text`, the field that replaced the
    /// deprecated `responseSchema`; plain JSON and text still ride on
    /// `responseMimeType`, which is not deprecated. Verified 2 September 2026
    /// against https://ai.google.dev/gemini-api/docs/generate-content/structured-output
    /// and https://ai.google.dev/api/generate-content.
    func applyResponseFormat(_ format: ResponseFormat, to config: inout [String: Any]) throws {
        switch format {
        case .json:
            config["responseMimeType"] = "application/json"
        case .text:
            config["responseMimeType"] = "text/plain"
        case .structured(let schema):
            let parsed = try JSONSchemaNormalizer.parseObject(schema)
            config["responseFormat"] = [
                "text": [
                    "mimeType": "application/json",
                    "schema": JSONSchemaNormalizer.geminiSchema(parsed),
                ],
            ]
        }
    }

    /// Build `thinkingConfig`, rejecting a control the model does not take.
    ///
    /// Gemini 3 models accept a `thinkingLevel` and error on a budget; the 2.5
    /// series is the other way round. Sending the wrong one is a guaranteed
    /// HTTP 400, so the mismatch is caught here instead.
    func thinkingConfigJSON(options: GeminiOptions?, model: GeminiModel?) throws -> [String: Any]? {
        guard let options, options.thinking != nil || options.includeThoughts != nil else {
            return nil
        }

        var config: [String: Any] = [:]
        if let includeThoughts = options.includeThoughts {
            config["includeThoughts"] = includeThoughts
        }

        switch options.thinking {
        case .none:
            break

        case .level(let level):
            switch model?.thinkingSupport {
            case .budget:
                throw ArbiterError.invalidRequest(
                    reason: "\(model?.displayName ?? "This model") does not accept a thinking level; use a thinking budget"
                )
            case .levels(let supported) where !supported.contains(level):
                throw ArbiterError.invalidRequest(
                    reason: "\(model?.displayName ?? "This model") does not support the \(level.rawValue) thinking level"
                )
            case .levels, .none:
                break
            }
            config["thinkingLevel"] = level.rawValue

        case .budget(let tokens):
            switch model?.thinkingSupport {
            case .levels:
                throw ArbiterError.invalidRequest(
                    reason: "\(model?.displayName ?? "This model") does not accept a thinking budget; use a thinking level"
                )
            case .budget(let range, let canDisable):
                // -1 always means dynamic thinking, whatever the range is.
                if tokens == 0, !canDisable {
                    throw ArbiterError.invalidRequest(
                        reason: "\(model?.displayName ?? "This model") cannot disable thinking"
                    )
                }
                if tokens != -1, tokens != 0, !range.contains(tokens) {
                    throw ArbiterError.invalidRequest(
                        reason: "\(model?.displayName ?? "This model") accepts a thinking budget of \(range.lowerBound)–\(range.upperBound) tokens, -1 for dynamic"
                    )
                }
            case .none:
                break
            }
            config["thinkingBudget"] = tokens
        }

        return config
    }
}

// MARK: - Response

private extension GeminiMapper {
    /// The answer text, with reasoning and tool parts left out.
    ///
    /// A thought summary is returned as an ordinary text part flagged
    /// `thought`, so joining every text part would fold the model's reasoning
    /// into its answer — and into whatever tries to decode that answer as JSON.
    func answerText(from parts: [[String: Any]]) -> String {
        parts
            .filter { !isThought($0) && $0["functionCall"] == nil }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    func isThought(_ part: [String: Any]) -> Bool {
        part["thought"] as? Bool == true
    }

    func extractThinking(from parts: [[String: Any]]) -> [ThinkingBlock] {
        parts.filter { isThought($0) }.map { part in
            ThinkingBlock(
                text: part["text"] as? String ?? "",
                signature: part["thoughtSignature"] as? String
            )
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

            return ToolCall(
                id: functionCall["id"] as? String ?? "\(Self.synthesisedCallIDPrefix)\(UUID().uuidString)",
                name: name,
                arguments: arguments,
                signature: part["thoughtSignature"] as? String
            )
        }
    }

    /// Turn grounding metadata into citations.
    ///
    /// Each `groundingSupport` ties a span of the answer to the chunks that
    /// back it, so one support with two chunk indices becomes two citations
    /// over the same span — that is what lets a caller render both sources
    /// against the sentence they support.
    func extractCitations(from candidate: [String: Any]) -> [Citation] {
        guard let metadata = candidate["groundingMetadata"] as? [String: Any] else { return [] }
        let chunks = metadata["groundingChunks"] as? [[String: Any]] ?? []
        let supports = metadata["groundingSupports"] as? [[String: Any]] ?? []

        func web(at index: Int) -> [String: Any]? {
            guard chunks.indices.contains(index) else { return nil }
            return chunks[index]["web"] as? [String: Any]
        }

        var citations: [Citation] = []
        for support in supports {
            let segment = support["segment"] as? [String: Any] ?? [:]
            let indices = support["groundingChunkIndices"] as? [Int] ?? []
            for index in indices {
                guard let web = web(at: index) else { continue }
                citations.append(Citation(
                    citedText: segment["text"] as? String,
                    title: web["title"] as? String,
                    documentIndex: index,
                    startIndex: segment["startIndex"] as? Int,
                    endIndex: segment["endIndex"] as? Int,
                    url: (web["uri"] as? String).flatMap(URL.init(string:))
                ))
            }
        }

        // A grounded answer with no per-span support still names its sources,
        // and losing them would be worse than citations without spans.
        if citations.isEmpty {
            for (index, chunk) in chunks.enumerated() {
                guard let web = chunk["web"] as? [String: Any] else { continue }
                citations.append(Citation(
                    title: web["title"] as? String,
                    documentIndex: index,
                    url: (web["uri"] as? String).flatMap(URL.init(string:))
                ))
            }
        }
        return citations
    }

    /// Read usage, keeping cached and thinking tokens where they are billed.
    ///
    /// `promptTokenCount` already *includes* `cachedContentTokenCount`, so the
    /// cached share is subtracted back out rather than counted twice — Gemini
    /// prices a cached input token at a tenth of a fresh one across the whole
    /// catalogue, which is the ratio `TokenUsage.cost` applies. Thinking tokens
    /// are billed as output, so they are folded into `outputTokens`.
    func extractUsage(from json: [String: Any]) -> TokenUsage? {
        guard let metadata = json["usageMetadata"] as? [String: Any],
              let promptTokens = metadata["promptTokenCount"] as? Int else {
            return nil
        }
        let candidateTokens = metadata["candidatesTokenCount"] as? Int ?? 0
        let thoughtTokens = metadata["thoughtsTokenCount"] as? Int ?? 0
        let cachedTokens = metadata["cachedContentTokenCount"] as? Int ?? 0

        return TokenUsage(
            inputTokens: max(promptTokens - cachedTokens, 0),
            outputTokens: candidateTokens + thoughtTokens,
            cacheReadInputTokens: cachedTokens > 0 ? cachedTokens : nil
        )
    }

    /// Map Gemini's finish reason onto the unified one.
    ///
    /// Gemini has no tool-call finish reason: a turn that asks for a function
    /// finishes with `STOP` like any other. The agent loop keys on
    /// `FinishReason.toolCall`, so a `STOP` carrying calls is reported as one —
    /// without that, a Gemini tool call is never executed.
    func mapFinishReason(_ reason: String?, hasToolCalls: Bool) -> FinishReason? {
        guard let reason else {
            return hasToolCalls ? .toolCall : nil
        }
        switch reason {
        case "STOP": return hasToolCalls ? .toolCall : .complete
        case "MAX_TOKENS": return .maxTokens
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII",
             "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_RECITATION":
            return .contentFilter
        case "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS",
             "MISSING_THOUGHT_SIGNATURE", "MALFORMED_RESPONSE":
            return .error
        default:
            // `OTHER`, `LANGUAGE`, or a reason added after this was written.
            // Calls in hand still have to be run, and the loop only runs them
            // on `.toolCall`.
            return hasToolCalls ? .toolCall : nil
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
