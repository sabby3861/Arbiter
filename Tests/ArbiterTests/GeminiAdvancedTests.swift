// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

// MARK: - Endpoint

@Suite("Gemini — endpoint")
struct GeminiEndpointTests {
    @Test func requestsGoToV1Beta() {
        #expect(
            GeminiProvider.endpointPath(model: "gemini-3.8-flash", stream: false)
                == "/v1beta/models/gemini-3.8-flash:generateContent"
        )
        #expect(
            GeminiProvider.endpointPath(model: "gemini-3.8-flash", stream: true)
                == "/v1beta/models/gemini-3.8-flash:streamGenerateContent"
        )
    }
}

// MARK: - Structured output

@Suite("Gemini — structured output")
struct GeminiStructuredOutputTests {
    let mapper = GeminiMapper(defaultModel: .flash38)

    /// The shape in the published REST example: a schema object under
    /// `generationConfig.responseFormat.text`, not the deprecated
    /// `responseSchema`, and not a string.
    @Test func structuredRequestMatchesDocumentedShape() throws {
        let schema = """
        {"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}
        """
        let request = AIRequest.chat("Where?").withResponseFormat(.structured(schema: schema))

        let json = try Self.body(mapper.buildRequestBody(request))
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["responseSchema"] == nil)

        let responseFormat = try #require(config["responseFormat"] as? [String: Any])
        let text = try #require(responseFormat["text"] as? [String: Any])
        #expect(text["mimeType"] as? String == "application/json")

        let sent = try #require(text["schema"] as? [String: Any])
        #expect(sent["type"] as? String == "object")
        #expect(sent["required"] as? [String] == ["city"])
        #expect(sent["properties"] as? [String: Any] != nil)
    }

    @Test func unsupportedKeywordsAreStrippedAndOptionalityIsPreserved() throws {
        let schema = """
        {"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object",
         "properties":{"code":{"type":"string","pattern":"^[A-Z]+$"},
                       "note":{"type":"string"}},
         "required":["code"],"propertyOrdering":["code","note"],
         "additionalProperties":false}
        """
        let request = AIRequest.chat("Extract").withResponseFormat(.structured(schema: schema))

        let json = try Self.body(mapper.buildRequestBody(request))
        let config = try #require(json["generationConfig"] as? [String: Any])
        let responseFormat = try #require(config["responseFormat"] as? [String: Any])
        let text = try #require(responseFormat["text"] as? [String: Any])
        let sent = try #require(text["schema"] as? [String: Any])

        #expect(sent["$schema"] == nil)
        let properties = try #require(sent["properties"] as? [String: Any])
        let code = try #require(properties["code"] as? [String: Any])
        #expect(code["pattern"] == nil)
        // Gemini accepts optional properties, so `required` is left as written
        // rather than widened the way OpenAI strict mode needs.
        #expect(sent["required"] as? [String] == ["code"])
        #expect(sent["propertyOrdering"] as? [String] == ["code", "note"])
        #expect(sent["additionalProperties"] as? Bool == false)
    }

    @Test func plainJSONModeStillUsesResponseMimeType() throws {
        let json = try Self.body(mapper.buildRequestBody(AIRequest.chat("x").withResponseFormat(.json)))
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
        #expect(config["responseFormat"] == nil)
    }

    @Test func aSchemaThatIsNotAJSONObjectIsRejectedLocally() {
        let request = AIRequest.chat("x").withResponseFormat(.structured(schema: "[]"))
        #expect(throws: ArbiterError.self) {
            _ = try mapper.buildRequestBody(request)
        }
    }

    static func body(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - Thinking

@Suite("Gemini — thinking")
struct GeminiThinkingTests {
    @Test func aGemini3ModelTakesAThinkingLevel() throws {
        let mapper = GeminiMapper(defaultModel: .flash38)
        let request = AIRequest.chat("Think")
            .withProviderOptions(
                GeminiOptions(thinking: .level(.low), includeThoughts: true),
                for: .gemini
            )

        let json = try GeminiStructuredOutputTests.body(mapper.buildRequestBody(request))
        let config = try #require(json["generationConfig"] as? [String: Any])
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingLevel"] as? String == "low")
        #expect(thinking["includeThoughts"] as? Bool == true)
        #expect(thinking["thinkingBudget"] == nil)
    }

    @Test func aGemini25ModelTakesAThinkingBudget() throws {
        let mapper = GeminiMapper(defaultModel: .flash25)
        let request = AIRequest.chat("Think")
            .withProviderOptions(GeminiOptions(thinking: .budget(tokens: 1024)), for: .gemini)

        let json = try GeminiStructuredOutputTests.body(mapper.buildRequestBody(request))
        let config = try #require(json["generationConfig"] as? [String: Any])
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingBudget"] as? Int == 1024)
        #expect(thinking["thinkingLevel"] == nil)
    }

    @Test func dynamicThinkingIsAcceptedOutsideTheBudgetRange() throws {
        let mapper = GeminiMapper(defaultModel: .pro25)
        let request = AIRequest.chat("Think")
            .withProviderOptions(GeminiOptions(thinking: .dynamicBudget), for: .gemini)

        let json = try GeminiStructuredOutputTests.body(mapper.buildRequestBody(request))
        let config = try #require(json["generationConfig"] as? [String: Any])
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingBudget"] as? Int == -1)
    }

    @Test func aBudgetSentToAGemini3ModelIsRejected() {
        let mapper = GeminiMapper(defaultModel: .flash38)
        let request = AIRequest.chat("Think")
            .withProviderOptions(GeminiOptions(thinking: .budget(tokens: 1024)), for: .gemini)
        #expect(throws: ArbiterError.self) { _ = try mapper.buildRequestBody(request) }
    }

    @Test func aLevelSentToAGemini25ModelIsRejected() {
        let mapper = GeminiMapper(defaultModel: .flash25)
        let request = AIRequest.chat("Think")
            .withProviderOptions(GeminiOptions(thinking: .level(.high)), for: .gemini)
        #expect(throws: ArbiterError.self) { _ = try mapper.buildRequestBody(request) }
    }

    /// 3.8 Flash publishes low/medium/high and errors on `minimal`.
    @Test func aLevelTheModelDoesNotPublishIsRejected() {
        let mapper = GeminiMapper(defaultModel: .flash38)
        let request = AIRequest.chat("Think")
            .withProviderOptions(GeminiOptions(thinking: .level(.minimal)), for: .gemini)
        #expect(throws: ArbiterError.self) { _ = try mapper.buildRequestBody(request) }
    }

    @Test func minimalIsAcceptedByTheModelsThatPublishIt() throws {
        let mapper = GeminiMapper(defaultModel: .flashLite31)
        let request = AIRequest.chat("Think")
            .withProviderOptions(GeminiOptions(thinking: .level(.minimal)), for: .gemini)

        let json = try GeminiStructuredOutputTests.body(mapper.buildRequestBody(request))
        let config = try #require(json["generationConfig"] as? [String: Any])
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingLevel"] as? String == "minimal")
    }

    @Test func thinkingCannotBeDisabledOnProModels() {
        let mapper = GeminiMapper(defaultModel: .pro25)
        let request = AIRequest.chat("Think")
            .withProviderOptions(GeminiOptions(thinking: .budget(tokens: 0)), for: .gemini)
        #expect(throws: ArbiterError.self) { _ = try mapper.buildRequestBody(request) }
    }

    @Test func aBudgetOutsideTheModelsRangeIsRejected() {
        let mapper = GeminiMapper(defaultModel: .flash25)
        let request = AIRequest.chat("Think")
            .withProviderOptions(GeminiOptions(thinking: .budget(tokens: 99_999)), for: .gemini)
        #expect(throws: ArbiterError.self) { _ = try mapper.buildRequestBody(request) }
    }

    /// A model Arbiter does not know — a preview, or a proxy's own alias — has
    /// no published rules to check against, so the caller's value passes through.
    @Test func anUnknownModelIsNotSecondGuessed() throws {
        let mapper = GeminiMapper(defaultModel: .flash38)
        let request = AIRequest.chat("Think")
            .withModel("gemini-9-experimental")
            .withProviderOptions(GeminiOptions(thinking: .budget(tokens: 4096)), for: .gemini)

        let json = try GeminiStructuredOutputTests.body(mapper.buildRequestBody(request))
        let config = try #require(json["generationConfig"] as? [String: Any])
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingBudget"] as? Int == 4096)
    }

    @Test func noOptionsMeansNoThinkingConfig() throws {
        let mapper = GeminiMapper(defaultModel: .flash38)
        let json = try GeminiStructuredOutputTests.body(mapper.buildRequestBody(.chat("Hi")))
        let config = json["generationConfig"] as? [String: Any]
        #expect(config?["thinkingConfig"] == nil)
    }

    /// A thought summary is an ordinary text part flagged `thought`; folding it
    /// into the answer would corrupt both the text and anything decoding it.
    @Test func thoughtPartsStayOutOfTheAnswer() throws {
        let mapper = GeminiMapper(defaultModel: .flash38)
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[
          {"text":"The user wants a capital city.","thought":true,"thoughtSignature":"EpoGCpcG"},
          {"text":"Paris."}]},"finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":3,"thoughtsTokenCount":21}}
        """

        let response = try mapper.parseResponse(Data(fixture.utf8))

        #expect(response.content == "Paris.")
        #expect(response.reasoning == "The user wants a capital city.")
        #expect(response.thinking.count == 1)
        #expect(response.thinking[0].signature == "EpoGCpcG")
        // Thinking tokens are billed as output.
        #expect(response.usage?.outputTokens == 24)
    }
}

// MARK: - Grounding

@Suite("Gemini — search grounding")
struct GeminiGroundingTests {
    let mapper = GeminiMapper(defaultModel: .flash38)

    @Test func groundingIsSentAsAToolOfItsOwn() throws {
        let request = AIRequest.chat("Who won?")
            .withProviderOptions(GeminiOptions(googleSearch: true), for: .gemini)

        let json = try GeminiStructuredOutputTests.body(mapper.buildRequestBody(request))
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["google_search"] as? [String: Any] != nil)
    }

    @Test func groundingSitsAlongsideFunctionDeclarations() throws {
        let tool = ToolDefinition(
            name: "lookup", description: "Look something up", inputSchema: .object(["type": "object"])
        )
        let request = AIRequest.chat("Who won?")
            .withTools([tool])
            .withProviderOptions(GeminiOptions(googleSearch: true), for: .gemini)

        let json = try GeminiStructuredOutputTests.body(mapper.buildRequestBody(request))
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        #expect(tools.contains { $0["functionDeclarations"] != nil })
        #expect(tools.contains { $0["google_search"] != nil })
    }

    /// Fixture shape taken from the published grounding response.
    @Test func groundingMetadataBecomesCitations() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"Spain won Euro 2024."}]},
          "finishReason":"STOP",
          "groundingMetadata":{
            "webSearchQueries":["who won euro 2024"],
            "groundingChunks":[
              {"web":{"uri":"https://example.com/a","title":"aljazeera.com"}},
              {"web":{"uri":"https://example.com/b","title":"uefa.com"}}],
            "groundingSupports":[
              {"segment":{"startIndex":0,"endIndex":20,"text":"Spain won Euro 2024."},
               "groundingChunkIndices":[0,1]}]}}],
         "usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":6}}
        """

        let response = try mapper.parseResponse(Data(fixture.utf8))

        #expect(response.citations.count == 2)
        #expect(response.citations[0].url == URL(string: "https://example.com/a"))
        #expect(response.citations[0].title == "aljazeera.com")
        #expect(response.citations[0].citedText == "Spain won Euro 2024.")
        #expect(response.citations[0].startIndex == 0)
        #expect(response.citations[0].endIndex == 20)
        #expect(response.citations[1].title == "uefa.com")
    }

    /// Sources without per-span support are still worth reporting.
    @Test func chunksWithoutSupportsStillBecomeCitations() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"Yes."}]},"finishReason":"STOP",
          "groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.com/a","title":"a"}}]}}]}
        """
        let response = try mapper.parseResponse(Data(fixture.utf8))
        #expect(response.citations.count == 1)
        #expect(response.citations[0].citedText == nil)
    }

    @Test func anUngroundedResponseHasNoCitations() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"Yes."}]},"finishReason":"STOP"}]}
        """
        #expect(try mapper.parseResponse(Data(fixture.utf8)).citations.isEmpty)
    }
}

// MARK: - Safety settings and caching

@Suite("Gemini — request-level options")
struct GeminiRequestOptionTests {
    let mapper = GeminiMapper(defaultModel: .flash38)

    @Test func safetySettingsAndCachedContentAreRequestLevel() throws {
        let request = AIRequest.chat("Hi")
            .withProviderOptions(
                GeminiOptions(
                    safetySettings: [
                        GeminiSafetySetting(category: .harassment, threshold: .blockOnlyHigh),
                    ],
                    cachedContent: "cachedContents/abc123"
                ),
                for: .gemini
            )

        let json = try GeminiStructuredOutputTests.body(mapper.buildRequestBody(request))
        let settings = try #require(json["safetySettings"] as? [[String: Any]])
        #expect(settings[0]["category"] as? String == "HARM_CATEGORY_HARASSMENT")
        #expect(settings[0]["threshold"] as? String == "BLOCK_ONLY_HIGH")
        #expect(json["cachedContent"] as? String == "cachedContents/abc123")

        // Neither belongs to generationConfig.
        let config = json["generationConfig"] as? [String: Any]
        #expect(config?["safetySettings"] == nil)
        #expect(config?["cachedContent"] == nil)
    }

    /// `promptTokenCount` already includes the cached share, so counting both
    /// would bill the cached tokens twice.
    @Test func cachedTokensAreSplitOutOfTheInputCount() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"Hi"}]},"finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":1000,"cachedContentTokenCount":800,
                          "candidatesTokenCount":10,"totalTokenCount":1010}}
        """
        let usage = try #require(mapper.parseResponse(Data(fixture.utf8)).usage)

        #expect(usage.inputTokens == 200)
        #expect(usage.cacheReadInputTokens == 800)
        #expect(usage.billedInputTokens == 1000)
    }

    @Test func theResponsesOwnModelVersionIsReported() throws {
        let fixture = """
        {"modelVersion":"gemini-3.8-flash-001",
         "candidates":[{"content":{"role":"model","parts":[{"text":"Hi"}]},"finishReason":"STOP"}]}
        """
        #expect(try mapper.parseResponse(Data(fixture.utf8)).model == "gemini-3.8-flash-001")
    }
}

// MARK: - Tool calling

@Suite("Gemini — tool calling")
struct GeminiToolCallTests {
    let mapper = GeminiMapper(defaultModel: .flash38)

    /// Gemini has no tool-call finish reason: a turn asking for a function
    /// finishes `STOP`. The agent loop keys on `.toolCall`, so without this the
    /// call is never executed.
    @Test func aStopThatCarriesCallsIsReportedAsAToolCall() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[
          {"functionCall":{"id":"call_1","name":"get_weather","args":{"city":"Tokyo"}},
           "thoughtSignature":"SIGA"}]},"finishReason":"STOP"}]}
        """
        let response = try mapper.parseResponse(Data(fixture.utf8))

        #expect(response.finishReason == .toolCall)
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].id == "call_1")
        #expect(response.toolCalls[0].signature == "SIGA")
    }

    @Test func aStopWithoutCallsStaysComplete() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"Done."}]},"finishReason":"STOP"}]}
        """
        #expect(try mapper.parseResponse(Data(fixture.utf8)).finishReason == .complete)
    }

    /// A finish reason Arbiter does not recognise must not strand calls the
    /// model already made: the loop only runs them on `.toolCall`.
    @Test func anUnrecognisedFinishReasonWithCallsStillReportsAToolCall() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[
          {"functionCall":{"name":"get_weather","args":{}}}]},"finishReason":"OTHER"}]}
        """
        #expect(try mapper.parseResponse(Data(fixture.utf8)).finishReason == .toolCall)
    }

    @Test func anUnrecognisedFinishReasonWithoutCallsStaysUnknown() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"Hi"}]},"finishReason":"OTHER"}]}
        """
        #expect(try mapper.parseResponse(Data(fixture.utf8)).finishReason == nil)
    }

    /// Tool schemas keep the constraints the `parameters` field honours; only
    /// the response schema goes through the structured-output dialect.
    @Test func toolParametersAreSentAsWritten() throws {
        let tool = ToolDefinition(
            name: "lookup",
            description: "Look something up",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object(["type": .string("string"), "pattern": .string("^[A-Z]+$")]),
                ]),
            ])
        )
        let json = try GeminiStructuredOutputTests.body(
            mapper.buildRequestBody(AIRequest.chat("Look up").withTools([tool]))
        )
        let tools = try #require(json["tools"] as? [[String: Any]])
        let declarations = try #require(tools[0]["functionDeclarations"] as? [[String: Any]])
        let parameters = try #require(declarations[0]["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: Any])
        let code = try #require(properties["code"] as? [String: Any])
        #expect(code["pattern"] as? String == "^[A-Z]+$")
    }

    @Test func aMalformedCallIsAnError() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[]},"finishReason":"MALFORMED_FUNCTION_CALL"}]}
        """
        #expect(try mapper.parseResponse(Data(fixture.utf8)).finishReason == .error)
    }

    @Test func aCallWithoutAnIDGetsASynthesisedOne() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[
          {"functionCall":{"name":"get_weather","args":{}}}]},"finishReason":"STOP"}]}
        """
        let call = try #require(mapper.parseResponse(Data(fixture.utf8)).toolCalls.first)
        #expect(call.id.hasPrefix(GeminiMapper.synthesisedCallIDPrefix))
    }

    /// The signature that authenticates the model's reasoning has to come back
    /// inside the part it was issued for, and the call's id has to come back on
    /// the response that answers it.
    @Test func aSignedCallRoundTripsThroughHistory() throws {
        let fixture = """
        {"candidates":[{"content":{"role":"model","parts":[
          {"functionCall":{"id":"call_1","name":"get_weather","args":{"city":"Tokyo"}},
           "thoughtSignature":"SIGA"},
          {"functionCall":{"id":"call_2","name":"get_time","args":{}},
           "thoughtSignature":"SIGB"}]},"finishReason":"STOP"}]}
        """
        let response = try mapper.parseResponse(Data(fixture.utf8))

        let messages: [Message] = [
            .user("Weather and time in Tokyo?"),
            Message(role: .assistant, content: .toolCalls(response.toolCalls)),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "call_1", name: "get_weather", content: "18C"),
                ToolResult(toolCallId: "call_2", name: "get_time", content: "09:00"),
            ])),
        ]

        let json = try GeminiStructuredOutputTests.body(
            mapper.buildRequestBody(AIRequest(messages: messages))
        )
        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.count == 3)

        let modelTurn = contents[1]
        #expect(modelTurn["role"] as? String == "model")
        let callParts = try #require(modelTurn["parts"] as? [[String: Any]])
        #expect(callParts.count == 2)
        // One signature per part, never merged.
        #expect(callParts[0]["thoughtSignature"] as? String == "SIGA")
        #expect(callParts[1]["thoughtSignature"] as? String == "SIGB")
        let firstCall = try #require(callParts[0]["functionCall"] as? [String: Any])
        #expect(firstCall["id"] as? String == "call_1")
        #expect(firstCall["name"] as? String == "get_weather")

        let resultTurn = contents[2]
        #expect(resultTurn["role"] as? String == "user")
        let resultParts = try #require(resultTurn["parts"] as? [[String: Any]])
        let firstResponse = try #require(resultParts[0]["functionResponse"] as? [String: Any])
        #expect(firstResponse["id"] as? String == "call_1")
        #expect(firstResponse["name"] as? String == "get_weather")
    }

    /// An id Arbiter invented matches no call on the wire, so sending it back
    /// would ask the API to correlate against something it never issued.
    @Test func synthesisedIDsAreNotSentBack() throws {
        let synthesised = "\(GeminiMapper.synthesisedCallIDPrefix)abc"
        let messages: [Message] = [
            .user("Weather?"),
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: synthesised, name: "get_weather", arguments: .object([:])),
            ])),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: synthesised, name: "get_weather", content: "18C"),
            ])),
        ]

        let json = try GeminiStructuredOutputTests.body(
            mapper.buildRequestBody(AIRequest(messages: messages))
        )
        let contents = try #require(json["contents"] as? [[String: Any]])
        let callParts = try #require(contents[1]["parts"] as? [[String: Any]])
        let call = try #require(callParts[0]["functionCall"] as? [String: Any])
        #expect(call["id"] == nil)

        let resultParts = try #require(contents[2]["parts"] as? [[String: Any]])
        let response = try #require(resultParts[0]["functionResponse"] as? [String: Any])
        #expect(response["id"] == nil)
        #expect(response["name"] as? String == "get_weather")
    }

    /// A result carried over from another provider's history names a call this
    /// conversation never made, so its id is left off rather than sent.
    @Test func anIDFromAnotherProvidersHistoryIsNotEchoed() throws {
        let messages: [Message] = [
            .user("Weather?"),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "toolu_01AnthropicStyle", name: "get_weather", content: "18C"),
            ])),
        ]

        let json = try GeminiStructuredOutputTests.body(
            mapper.buildRequestBody(AIRequest(messages: messages))
        )
        let contents = try #require(json["contents"] as? [[String: Any]])
        let resultParts = try #require(contents[1]["parts"] as? [[String: Any]])
        let response = try #require(resultParts[0]["functionResponse"] as? [String: Any])
        #expect(response["id"] == nil)
    }

    /// A thought summary is never replayed. The signature Gemini *requires*
    /// back rides on the function call; a `ThinkingBlock`'s signature has no
    /// provenance, so after a fallback it could be another provider's — which
    /// Gemini validates and rejects.
    @Test func thinkingIsNotReplayed() throws {
        let messages: [Message] = [
            .user("Why?"),
            Message(role: .assistant, content: .mixed([
                .thinking([ThinkingBlock(text: "Reasoning", signature: "SIGA")]),
                .text("Because."),
            ])),
            Message(role: .assistant, content: .thinking([
                ThinkingBlock(text: "More reasoning", signature: "SIGB"),
            ])),
        ]

        let json = try GeminiStructuredOutputTests.body(
            mapper.buildRequestBody(AIRequest(messages: messages))
        )
        let contents = try #require(json["contents"] as? [[String: Any]])

        // The thinking-only turn contributes no content at all.
        #expect(contents.count == 2)
        let parts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(parts.count == 1)
        #expect(parts[0]["text"] as? String == "Because.")
        #expect(!contents.contains { content in
            (content["parts"] as? [[String: Any]] ?? []).contains { $0["thought"] != nil }
        })
    }
}

// MARK: - Streaming

@Suite("Gemini — streaming")
struct GeminiStreamingTests {
    let mapper = GeminiMapper(defaultModel: .flash38)

    @Test func streamedFunctionCallsSurface() throws {
        var state = GeminiStreamState()

        let textChunk = mapper.parseStreamEvent(
            """
            {"candidates":[{"content":{"role":"model","parts":[{"text":"Checking. "}]}}]}
            """,
            state: &state
        )
        #expect(textChunk?.delta == "Checking. ")
        #expect(textChunk?.toolCalls == nil)

        let callChunk = try #require(mapper.parseStreamEvent(
            """
            {"candidates":[{"content":{"role":"model","parts":[
              {"functionCall":{"id":"call_1","name":"get_weather","args":{"city":"Tokyo"}},
               "thoughtSignature":"SIGA"}]}}]}
            """,
            state: &state
        ))
        #expect(callChunk.toolCalls?.count == 1)
        #expect(callChunk.toolCalls?[0].signature == "SIGA")
        #expect(callChunk.isComplete == false)

        let final = try #require(mapper.parseStreamEvent(
            """
            {"candidates":[{"content":{"role":"model","parts":[]},"finishReason":"STOP"}],
             "usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":4}}
            """,
            state: &state
        ))
        #expect(final.isComplete)
        #expect(final.finishReason == .toolCall)
        #expect(final.toolCalls?.count == 1)
        #expect(final.accumulatedContent == "Checking. ")
    }

    /// A finish event may carry text of its own; dropping it truncated the answer.
    @Test func aFinishEventKeepsItsOwnText() throws {
        var state = GeminiStreamState()
        let chunk = try #require(mapper.parseStreamEvent(
            """
            {"candidates":[{"content":{"role":"model","parts":[{"text":"the end."}]},
             "finishReason":"STOP"}]}
            """,
            state: &state
        ))
        #expect(chunk.delta == "the end.")
        #expect(chunk.accumulatedContent == "the end.")
        #expect(chunk.isComplete)
        #expect(chunk.finishReason == .complete)
    }

    /// A host that just closes the connection leaves no finish event behind.
    /// Without a terminal chunk the turn's tool calls and usage never reach the
    /// caller, and an agent loop waits on a round that already ended.
    @Test func aStreamThatEndsWithoutAFinishEventStillTerminates() throws {
        var state = GeminiStreamState()
        _ = mapper.parseStreamEvent(
            """
            {"candidates":[{"content":{"role":"model","parts":[
              {"functionCall":{"id":"call_1","name":"get_weather","args":{}}}]}}],
             "usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":2}}
            """,
            state: &state
        )

        let final = try #require(mapper.finalChunk(state: state))
        #expect(final.isComplete)
        #expect(final.finishReason == .toolCall)
        #expect(final.toolCalls?.count == 1)
        #expect(final.usage?.inputTokens == 7)
    }

    /// A stream that produced nothing at all is a dead connection, not a model
    /// that answered with silence. Manufacturing a completed empty chunk here
    /// would hide it from the runtime's own "stream produced no chunk" error.
    @Test func aStreamThatProducedNothingHasNoTerminalChunk() {
        #expect(mapper.finalChunk(state: GeminiStreamState()) == nil)
    }

    @Test func streamedThoughtsStayOutOfTheAnswer() throws {
        var state = GeminiStreamState()
        let chunk = mapper.parseStreamEvent(
            """
            {"candidates":[{"content":{"role":"model","parts":[
              {"text":"Reasoning...","thought":true},{"text":"Answer"}]}}]}
            """,
            state: &state
        )
        #expect(chunk?.delta == "Answer")
        #expect(state.accumulatedContent == "Answer")
    }
}
