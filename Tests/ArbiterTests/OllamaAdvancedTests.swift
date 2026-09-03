// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

// MARK: - Tools

@Suite("Ollama tool calling")
struct OllamaToolCallTests {
    let mapper = OllamaMapper(defaultModel: "llama3.2")

    static let weatherTool = ToolDefinition(
        name: "get_weather",
        description: "Get the weather in a given city",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object([
                    "type": .string("string"),
                    "description": .string("The city to get the weather for"),
                ]),
            ]),
            "required": .array([.string("city")]),
        ])
    )

    @Test func toolsAreSentInTheDocumentedFunctionShape() throws {
        let request = AIRequest.chat("what is the weather in tokyo?")
            .withTools([Self.weatherTool])

        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")

        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_weather")
        #expect(function["description"] as? String == "Get the weather in a given city")

        // The schema passes through as the caller wrote it.
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        #expect(parameters["required"] as? [String] == ["city"])
        let properties = try #require(parameters["properties"] as? [String: Any])
        let city = try #require(properties["city"] as? [String: Any])
        #expect(city["type"] as? String == "string")
    }

    @Test func anEmptyToolListSendsNoToolsKey() throws {
        let request = AIRequest.chat("Hello").withTools([])
        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["tools"] == nil)
    }

    @Test func toolCallsAreParsedWithObjectArguments() throws {
        // Ollama sends arguments as a JSON object, not the stringified JSON the
        // OpenAI wire format uses.
        let body = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"Tokyo"}}}]},
         "done":true,"done_reason":"stop","prompt_eval_count":169,"eval_count":15}
        """.utf8)

        let response = try mapper.parseResponse(body)

        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "get_weather")
        #expect(response.toolCalls[0].arguments == .object(["city": .string("Tokyo")]))
        #expect(response.usage?.inputTokens == 169)
    }

    @Test func aTurnWithToolCallsFinishesAsAToolCall() throws {
        // Ollama reports `done_reason: "stop"` for a tool turn too; a caller
        // branching on the reason has to see `.toolCall` or the conversation
        // ends with the call unanswered.
        let body = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"Tokyo"}}}]},
         "done":true,"done_reason":"stop"}
        """.utf8)

        #expect(try mapper.parseResponse(body).finishReason == .toolCall)
    }

    @Test func parallelToolCallsGetDistinctSynthesisedIDs() throws {
        // Ollama attaches no id, and Arbiter's tool loop pairs a result with the
        // call that asked for it — so two calls in one turn must not collide.
        let body = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[
          {"function":{"name":"get_weather","arguments":{"city":"Tokyo"}}},
          {"function":{"name":"get_weather","arguments":{"city":"Osaka"}}}]},
         "done":true}
        """.utf8)

        let calls = try mapper.parseResponse(body).toolCalls
        #expect(calls.count == 2)
        #expect(Set(calls.map(\.id)).count == 2)
        #expect(calls.allSatisfy { $0.id.hasPrefix(OllamaMapper.synthesisedCallIDPrefix) })
        #expect(calls[1].arguments == .object(["city": .string("Osaka")]))
    }

    @Test func aToolCallWithNoArgumentsBecomesAnEmptyObject() throws {
        let body = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"list_alarms"}}]},"done":true}
        """.utf8)

        let calls = try mapper.parseResponse(body).toolCalls
        #expect(calls.count == 1)
        #expect(calls[0].arguments == .object([:]))
    }

    @Test func aToolCallWithoutANameIsDropped() throws {
        let body = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"hi",
         "tool_calls":[{"function":{"arguments":{"city":"Tokyo"}}}]},"done":true}
        """.utf8)

        let response = try mapper.parseResponse(body)
        #expect(response.toolCalls.isEmpty)
        // Nothing to execute, so the turn is a plain answer.
        #expect(response.finishReason == .complete)
    }

    @Test func toolCallsArriveWholeInTheStreamAndAreReplayedOnTheFinalChunk() {
        // Ollama's NDJSON delivers a call in its own object with empty content,
        // and the final object carries neither the call nor a tool-flavoured
        // done_reason.
        var state = OllamaStreamState()
        let callLine = """
        {"model":"llama3.2","created_at":"2025-07-07T20:22:19.184789Z","message":{"role":"assistant",\
        "content":"","tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"Tokyo"}}}]},"done":false}
        """
        let doneLine = """
        {"model":"llama3.2","message":{"role":"assistant","content":""},"done_reason":"stop",\
        "done":true,"prompt_eval_count":169,"eval_count":15}
        """

        // An empty delta is not a reason to skip a line that carries a call.
        let callChunk = mapper.parseStreamLine(callLine, state: &state)
        #expect(callChunk?.delta == "")
        #expect(callChunk?.isComplete == false)
        #expect(callChunk?.toolCalls?.map(\.name) == ["get_weather"])

        let finalChunk = mapper.parseStreamLine(doneLine, state: &state)
        #expect(finalChunk?.isComplete == true)
        #expect(finalChunk?.finishReason == .toolCall)
        #expect(finalChunk?.toolCalls?.count == 1)
        #expect(finalChunk?.toolCalls?[0].arguments == .object(["city": .string("Tokyo")]))
        #expect(finalChunk?.usage?.outputTokens == 15)
    }

    @Test func callsStreamedOnSeparateLinesKeepDistinctIDs() throws {
        var state = OllamaStreamState()
        let first = """
        {"message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"Tokyo"}}}]},"done":false}
        """
        let second = """
        {"message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"Osaka"}}}]},"done":false}
        """
        let done = """
        {"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}
        """

        _ = mapper.parseStreamLine(first, state: &state)
        // The second line restarts its own indices; the state's offset is what
        // keeps the ids apart.
        let secondChunk = mapper.parseStreamLine(second, state: &state)
        #expect(secondChunk?.toolCalls?.count == 1)

        let finalChunk = mapper.parseStreamLine(done, state: &state)
        let calls = try #require(finalChunk?.toolCalls)
        #expect(calls.count == 2)
        #expect(Set(calls.map(\.id)).count == 2)
    }

    @Test func aDroppedCallDoesNotMakeALaterCallReuseItsID() throws {
        // Ids are numbered over the calls actually kept. Numbering by position
        // in the raw array would have the second line reuse the id the first
        // line already issued, and the tool loop pairs results by id.
        var state = OllamaStreamState()
        let first = """
        {"message":{"role":"assistant","content":"","tool_calls":[
          {"function":{"arguments":{"city":"Tokyo"}}},
          {"function":{"name":"get_weather","arguments":{"city":"Tokyo"}}}]},"done":false}
        """
        let second = """
        {"message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"Osaka"}}}]},"done":false}
        """
        let done = """
        {"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}
        """

        let firstChunk = mapper.parseStreamLine(first, state: &state)
        #expect(firstChunk?.toolCalls?.count == 1)
        _ = mapper.parseStreamLine(second, state: &state)

        let calls = try #require(mapper.parseStreamLine(done, state: &state)?.toolCalls)
        #expect(calls.count == 2)
        #expect(Set(calls.map(\.id)).count == 2)
        #expect(calls.map(\.arguments) == [
            .object(["city": .string("Tokyo")]), .object(["city": .string("Osaka")]),
        ])
    }

    @Test func aStreamWithNoToolCallsCarriesNoneOnTheFinalChunk() {
        var state = OllamaStreamState()
        let text = """
        {"message":{"role":"assistant","content":"Hello"},"done":false}
        """
        let done = """
        {"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}
        """

        _ = mapper.parseStreamLine(text, state: &state)
        let finalChunk = mapper.parseStreamLine(done, state: &state)
        #expect(finalChunk?.toolCalls == nil)
        #expect(finalChunk?.finishReason == .complete)
        #expect(finalChunk?.accumulatedContent == "Hello")
    }

    @Test func idsFromSeparateTurnsNeverCollide() throws {
        // The tool loop memoises a tool's output under a key built from the call
        // id and its arguments alone. If round two's first no-argument call
        // reused round one's id, the loop would answer a different tool with the
        // earlier tool's output instead of running it.
        let firstTurn = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"list_files","arguments":{}}}]},"done":true}
        """.utf8)
        let secondTurn = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_time","arguments":{}}}]},"done":true}
        """.utf8)

        let first = try #require(try mapper.parseResponse(firstTurn).toolCalls.first)
        let second = try #require(try mapper.parseResponse(secondTurn).toolCalls.first)

        #expect(first.id != second.id)
        #expect(ToolIdempotency.key(callID: first.id, arguments: first.arguments)
            != ToolIdempotency.key(callID: second.id, arguments: second.arguments))
    }

    @Test func idsWithinOneStreamedTurnShareTheTurnsNonce() {
        // Stable within a turn: the streaming loop dedups an already-yielded call
        // by id, so the final chunk has to repeat the same ids it streamed.
        var state = OllamaStreamState()
        let line = """
        {"message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_weather","arguments":{"city":"Tokyo"}}}]},"done":false}
        """
        let done = """
        {"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}
        """

        let streamed = mapper.parseStreamLine(line, state: &state)?.toolCalls
        let final = mapper.parseStreamLine(done, state: &state)?.toolCalls
        #expect(streamed?.map(\.id) == final?.map(\.id))
    }

    @Test func stringifiedArgumentsAreStillRead() throws {
        // The documented shape is an object, but some community templates emit
        // an encoded string — running the tool with no arguments would be worse.
        let body = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[
          {"function":{"name":"get_weather","arguments":"{\\"city\\":\\"Tokyo\\"}"}}]},"done":true}
        """.utf8)

        let calls = try mapper.parseResponse(body).toolCalls
        #expect(calls.count == 1)
        #expect(calls[0].arguments == .object(["city": .string("Tokyo")]))
    }

    @Test func nonObjectArgumentsFallBackToAnEmptyObject() throws {
        let body = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"get_weather","arguments":"not json"}}]},"done":true}
        """.utf8)
        #expect(try mapper.parseResponse(body).toolCalls[0].arguments == .object([:]))
    }

    @Test func theProviderAdvertisesToolCalling() {
        #expect(OllamaProvider().capabilities.supportsToolCalling)
    }
}

// MARK: - Structured output

@Suite("Ollama structured output")
struct OllamaStructuredOutputTests {
    let mapper = OllamaMapper(defaultModel: "llama3.2")

    @Test func aSchemaIsSentAsAFormatObject() throws {
        let schema = """
        {"type":"object","properties":{"age":{"type":"integer"},"available":{"type":"boolean"}},\
        "required":["age","available"]}
        """
        let request = AIRequest.chat("Ollama is 22 years old and is busy saving the world.")
            .withResponseFormat(.structured(schema: schema))

        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // The object, not the string "json" and not the schema as text.
        let format = try #require(json["format"] as? [String: Any])
        #expect(format["type"] as? String == "object")
        #expect(format["required"] as? [String] == ["age", "available"])
        let properties = try #require(format["properties"] as? [String: Any])
        #expect((properties["age"] as? [String: Any])?["type"] as? String == "integer")
    }

    @Test func plainJSONStillRidesOnTheFormatString() throws {
        let request = AIRequest.chat("JSON please").withResponseFormat(.json)
        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["format"] as? String == "json")
    }

    @Test func textFormatSendsNoFormatAtAll() throws {
        let request = AIRequest.chat("Prose please").withResponseFormat(.text)
        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["format"] == nil)
    }

    @Test func aSchemaThatIsNotJSONIsRefusedLocally() {
        let request = AIRequest.chat("Hi").withResponseFormat(.structured(schema: "not json"))
        #expect(throws: ArbiterError.self) {
            try mapper.buildChatBody(request, stream: false)
        }
    }

    @Test func ollamaIsInTheSchemaCapableSet() {
        #expect(NativeStructuredOutput.supports(.ollama))
    }
}

// MARK: - Options

@Suite("Ollama options")
struct OllamaOptionsTests {
    let mapper = OllamaMapper(defaultModel: "llama3.2")

    private func body(_ options: OllamaOptions) throws -> [String: Any] {
        let request = AIRequest.chat("Hi").withProviderOptions(options, for: .ollama)
        let data = try mapper.buildChatBody(request, stream: false)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func keepAliveInSecondsIsSentAtTheTopLevel() throws {
        let json = try body(OllamaOptions(keepAlive: .seconds(3600)))
        #expect(json["keep_alive"] as? Int == 3600)
    }

    @Test func indefiniteKeepAliveIsMinusOne() throws {
        // Any negative number keeps the model loaded; `0` unloads it at once.
        #expect(try body(OllamaOptions(keepAlive: .indefinite))["keep_alive"] as? Int == -1)
        #expect(try body(OllamaOptions(keepAlive: .unloadImmediately))["keep_alive"] as? Int == 0)
    }

    @Test func thinkTakesABooleanOrALevel() throws {
        #expect(try body(OllamaOptions(think: .enabled(true)))["think"] as? Bool == true)
        #expect(try body(OllamaOptions(think: .enabled(false)))["think"] as? Bool == false)
        #expect(try body(OllamaOptions(think: .level(.high)))["think"] as? String == "high")
        #expect(try body(OllamaOptions(think: .level(.max)))["think"] as? String == "max")
    }

    @Test func numCtxRidesInOptionsAlongsideSamplingSettings() throws {
        let request = AIRequest.chat("Hi")
            .withTemperature(0.4)
            .withProviderOptions(OllamaOptions(numCtx: 8192), for: .ollama)

        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])

        #expect(options["num_ctx"] as? Int == 8192)
        #expect(options["temperature"] as? Double == 0.4)
        // These two are request parameters, not model options.
        #expect(json["num_ctx"] == nil)
        #expect(json["keep_alive"] == nil)
    }

    @Test func noOptionsMeansNoExtraKeys() throws {
        let data = try mapper.buildChatBody(AIRequest.chat("Hi"), stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["keep_alive"] == nil)
        #expect(json["think"] == nil)
        #expect(json["options"] == nil)
    }

    @Test func anotherProvidersOptionsAreIgnored() throws {
        // One request can carry settings for every provider the router might pick.
        let request = AIRequest.chat("Hi")
            .withProviderOptions(GeminiOptions(googleSearch: true), for: .gemini)
        let data = try mapper.buildChatBody(request, stream: false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["think"] == nil)
        #expect(json["keep_alive"] == nil)
    }

    @Test func thinkingComesBackSeparatelyFromTheAnswer() throws {
        let body = Data("""
        {"model":"deepseek-r1","message":{"role":"assistant","thinking":"The sky scatters blue.",
         "content":"Because of Rayleigh scattering."},"done":true,"done_reason":"stop"}
        """.utf8)

        let response = try mapper.parseResponse(body)
        #expect(response.content == "Because of Rayleigh scattering.")
        #expect(response.reasoning == "The sky scatters blue.")
        // No signature to replay: Ollama takes no thinking back.
        #expect(response.thinking.isEmpty)
    }

    @Test func aResponseWithoutThinkingReportsNoReasoning() throws {
        let body = Data("""
        {"model":"llama3.2","message":{"role":"assistant","content":"Hi"},"done":true}
        """.utf8)
        #expect(try mapper.parseResponse(body).reasoning == nil)
    }

    @Test func thinkingDeltasNeverLeakIntoStreamedContent() {
        var state = OllamaStreamState()
        let thinkingLine = """
        {"message":{"role":"assistant","thinking":"Let me think.","content":""},"done":false}
        """
        let answerLine = """
        {"message":{"role":"assistant","content":"42"},"done":false}
        """

        #expect(mapper.parseStreamLine(thinkingLine, state: &state) == nil)
        let chunk = mapper.parseStreamLine(answerLine, state: &state)
        #expect(chunk?.accumulatedContent == "42")
    }
}

// MARK: - Embeddings

@Suite("Ollama embeddings")
struct OllamaEmbeddingTests {
    @Test func vectorsComeBackInRequestOrderWithInputOnlyUsage() throws {
        // `/api/embed` has no per-vector `index`, so request order is the only
        // ordering there is.
        let body = Data("""
        {"model":"all-minilm","embeddings":[[0.1,0.2],[0.3,0.4]],
         "total_duration":14143917,"load_duration":1019500,"prompt_eval_count":8}
        """.utf8)

        let response = try OllamaProvider.parseEmbeddingResponse(
            body, requestedModel: "all-minilm", inputCount: 2
        )

        #expect(response.embeddings == [[0.1, 0.2], [0.3, 0.4]])
        #expect(response.model == "all-minilm")
        #expect(response.usage?.inputTokens == 8)
        #expect(response.usage?.outputTokens == 0)
    }

    @Test func aResponseWithoutUsageIsStillValid() throws {
        // The multiple-input example in Ollama's own docs omits the counts.
        let body = Data("""
        {"model":"all-minilm","embeddings":[[0.1]]}
        """.utf8)
        let response = try OllamaProvider.parseEmbeddingResponse(
            body, requestedModel: "all-minilm", inputCount: 1
        )
        #expect(response.usage == nil)
        #expect(response.embeddings == [[0.1]])
    }

    @Test func aShortResponseIsAMismatchNotASilentPairing() {
        let body = Data("""
        {"model":"all-minilm","embeddings":[[0.1]]}
        """.utf8)
        #expect(throws: ArbiterError.self) {
            try OllamaProvider.parseEmbeddingResponse(
                body, requestedModel: "all-minilm", inputCount: 2
            )
        }
    }

    @Test func aResponseWithNoEmbeddingsArrayFails() {
        #expect(throws: ArbiterError.self) {
            try OllamaProvider.parseEmbeddingResponse(
                Data("{\"model\":\"all-minilm\"}".utf8),
                requestedModel: "all-minilm",
                inputCount: 1
            )
        }
    }

    /// Pointed at a port nothing serves, so a guard that stopped working would
    /// surface as `providerUnavailable` from a real connection attempt rather
    /// than quietly satisfying `throws: ArbiterError.self`.
    private static let unreachable = OllamaProvider(
        baseURL: URL(string: "http://127.0.0.1:1")!, defaultModel: "llama3.2"
    )

    @Test func embeddingWithNoModelIsRefusedBeforeTheRequest() async throws {
        // A chat model cannot embed and Ollama has no server-side default, so
        // guessing one would only produce a 404 the caller cannot interpret.
        let error = await #expect(throws: ArbiterError.self) {
            _ = try await Self.unreachable.embed(["Why is the sky blue?"], model: nil)
        }
        guard case .invalidRequest(let reason) = try #require(error) else {
            Issue.record("Expected invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("embedding model"))
    }

    @Test func embeddingWithNoInputIsRefusedBeforeTheRequest() async throws {
        let error = await #expect(throws: ArbiterError.self) {
            _ = try await Self.unreachable.embed([], model: "all-minilm")
        }
        guard case .invalidRequest = try #require(error) else {
            Issue.record("Expected invalidRequest, got \(String(describing: error))")
            return
        }
    }

    @Test func theRequestBodyMatchesTheDocumentedShape() throws {
        let body = OllamaProvider.buildEmbeddingBody(
            model: "all-minilm", texts: ["Why is the sky blue?"], dimensions: nil
        )
        // `input`, not the superseded /api/embeddings `prompt`; an array even
        // for one text, so the response shape does not change with the count.
        #expect(body["model"] as? String == "all-minilm")
        #expect(body["input"] as? [String] == ["Why is the sky blue?"])
        #expect(body["dimensions"] == nil)

        let truncated = OllamaProvider.buildEmbeddingBody(
            model: "all-minilm", texts: ["a", "b"], dimensions: 256
        )
        #expect(truncated["input"] as? [String] == ["a", "b"])
        #expect(truncated["dimensions"] as? Int == 256)
    }

    @Test func theProviderConformsToEmbeddingProvider() {
        let provider: any EmbeddingProvider = OllamaProvider()
        #expect(provider.id == .ollama)
    }
}

// MARK: - Errors

@Suite("Ollama error mapping")
struct OllamaErrorMappingTests {
    @Test func aMissingModelIsReportedAsModelNotFound() {
        let body = Data("""
        {"error":"model \\"llama9\\" not found, try pulling it first"}
        """.utf8)

        let error = OllamaProvider.mapHTTPError(statusCode: 404, body: body)
        guard case .modelNotFound(let message) = error else {
            Issue.record("Expected modelNotFound, got \(error)")
            return
        }
        // The name alone: `ArbiterError` renders it as `Model '<name>' not found`,
        // so passing the whole sentence would quote a sentence inside a sentence.
        #expect(message == "llama9")
    }

    @Test func aNotFoundBodyWithNoQuotedNameKeepsTheWholeMessage() {
        let error = OllamaProvider.mapHTTPError(
            statusCode: 404, body: Data("{\"error\":\"model not found\"}".utf8)
        )
        guard case .modelNotFound(let message) = error else {
            Issue.record("Expected modelNotFound, got \(error)")
            return
        }
        #expect(message == "model not found")
    }

    @Test func aMissingModelIsNotRetriedButAFullQueueIs() {
        // Pulling the model is the only fix for a 404, so retrying it wastes the
        // budget; a 503 is Ollama's queue being full, which clears on its own.
        let engine = RetryEngine()
        #expect(!engine.isRetryable(OllamaProvider.mapHTTPError(statusCode: 404, body: Data())))
        #expect(engine.isRetryable(OllamaProvider.mapHTTPError(statusCode: 503, body: Data())))
    }

    @Test func otherStatusesKeepTheirOwnMeaning() {
        let body = Data("{\"error\":\"invalid options\"}".utf8)
        guard case .invalidRequest(let reason) = OllamaProvider.mapHTTPError(statusCode: 400, body: body) else {
            Issue.record("Expected invalidRequest for 400")
            return
        }
        #expect(reason == "invalid options")

        // Ollama queues requests and answers 503 once the queue is full.
        guard case .overloaded(let provider) =
                OllamaProvider.mapHTTPError(statusCode: 503, body: Data()) else {
            Issue.record("Expected overloaded for 503")
            return
        }
        #expect(provider == .ollama)

        guard case .httpError(let status, _) =
                OllamaProvider.mapHTTPError(statusCode: 500, body: Data()) else {
            Issue.record("Expected httpError for 500")
            return
        }
        #expect(status == 500)
    }

    @Test func aBodyThatIsNotOllamasErrorShapeIsPassedThroughAsText() {
        let error = OllamaProvider.mapHTTPError(statusCode: 502, body: Data("<html>bad gateway".utf8))
        guard case .httpError(_, let body) = error else {
            Issue.record("Expected httpError")
            return
        }
        #expect(body.contains("bad gateway"))
    }

    @Test func modelNamesAreReadFromTheTagsBody() {
        let body = Data("""
        {"models":[{"name":"deepseek-r1:latest","model":"deepseek-r1:latest","size":4683075271,
          "details":{"family":"qwen2","parameter_size":"7.6B"}},
         {"name":"all-minilm:latest","model":"all-minilm:latest","size":45960996}]}
        """.utf8)

        #expect(OllamaProvider.parseModelList(body) == ["deepseek-r1:latest", "all-minilm:latest"])
    }

    @Test func aTagsBodyThatIsNotTheDocumentedShapeListsNothing() {
        #expect(OllamaProvider.parseModelList(Data("{}".utf8)).isEmpty)
        #expect(OllamaProvider.parseModelList(Data("nonsense".utf8)).isEmpty)
    }

    @Test func anEmptyBodyStillProducesAMessage() {
        #expect(OllamaProvider.extractErrorMessage(from: Data()) == "Unknown error")
    }

    @Test func aLongBodyIsCapped() {
        let long = String(repeating: "x", count: 2000)
        #expect(OllamaProvider.extractErrorMessage(from: Data(long.utf8)).count == 500)
    }
}
