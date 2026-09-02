// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

// MARK: - Strict structured outputs

@Suite("OpenAI strict structured outputs")
struct OpenAIStrictSchemaTests {
    let mapper = OpenAIMapper(defaultModel: .gpt4o)

    /// The schema arrives as a string and must reach the wire as an object,
    /// under the `name`/`strict`/`schema` keys OpenAI documents.
    @Test func structuredRequestMatchesDocumentedShape() throws {
        let schema = """
        {"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"]}
        """
        let request = AIRequest.chat("Answer").withResponseFormat(.structured(schema: schema))

        let json = try requestJSON(mapper.buildRequestBody(request, stream: false))
        let format = try #require(json["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")

        let jsonSchema = try #require(format["json_schema"] as? [String: Any])
        #expect(jsonSchema["name"] as? String == "arbiter_output")
        #expect(jsonSchema["strict"] as? Bool == true)

        // The schema must be an object, not the string the caller passed.
        let inner = try #require(jsonSchema["schema"] as? [String: Any])
        #expect(inner["type"] as? String == "object")
        #expect(inner["additionalProperties"] as? Bool == false)
        #expect(inner["required"] as? [String] == ["answer"])
    }

    @Test func structuredOutputNameIsConfigurable() throws {
        let request = AIRequest.chat("Answer")
            .withResponseFormat(.structured(schema: #"{"type":"object","properties":{}}"#))
            .withProviderOptions(
                OpenAIOptions(structuredOutputName: "weather_report"),
                for: .openAI
            )

        let json = try requestJSON(mapper.buildRequestBody(request, stream: false))
        let jsonSchema = try #require(
            (json["response_format"] as? [String: Any])?["json_schema"] as? [String: Any]
        )
        #expect(jsonSchema["name"] as? String == "weather_report")
    }

    /// Turning strict off must leave the caller's schema untouched — a host
    /// that accepts `json_schema` but not strict mode would otherwise receive a
    /// rewritten schema it never asked for.
    @Test func nonStrictModeLeavesSchemaUnrewritten() throws {
        let schema = """
        {"type":"object","properties":{"a":{"type":"string"},"b":{"type":"number"}},"required":["a"]}
        """
        let request = AIRequest.chat("Answer")
            .withResponseFormat(.structured(schema: schema))
            .withProviderOptions(OpenAIOptions(strictStructuredOutputs: false), for: .openAI)

        let json = try requestJSON(mapper.buildRequestBody(request, stream: false))
        let jsonSchema = try #require(
            (json["response_format"] as? [String: Any])?["json_schema"] as? [String: Any]
        )
        #expect(jsonSchema["strict"] as? Bool == false)

        let inner = try #require(jsonSchema["schema"] as? [String: Any])
        #expect(inner["additionalProperties"] == nil)
        #expect(inner["required"] as? [String] == ["a"])
    }

    @Test func invalidSchemaStringThrowsRatherThanSendingGarbage() {
        for broken in ["not json at all", "[1,2,3]", ""] {
            let request = AIRequest.chat("Answer")
                .withResponseFormat(.structured(schema: broken))
            #expect(throws: ArbiterError.self) {
                try mapper.buildRequestBody(request, stream: false)
            }
        }
    }
}

@Suite("JSONSchemaNormalizer strict mode")
struct JSONSchemaNormalizerTests {
    /// Strict mode requires every property in `required`. A property the caller
    /// left optional therefore has to become nullable, or requiring it would
    /// change which values are legal.
    @Test func optionalPropertiesBecomeNullableAndRequired() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object",
         "properties":{"name":{"type":"string"},"nickname":{"type":"string"}},
         "required":["name"]}
        """)

        let strict = JSONSchemaNormalizer.openAIStrict(schema)
        #expect(strict["required"] as? [String] == ["name", "nickname"])
        #expect(strict["additionalProperties"] as? Bool == false)

        let properties = try #require(strict["properties"] as? [String: Any])
        // The originally-required property keeps its plain type…
        #expect((properties["name"] as? [String: Any])?["type"] as? String == "string")
        // …while the optional one is widened to admit null.
        #expect((properties["nickname"] as? [String: Any])?["type"] as? [String] == ["string", "null"])
    }

    @Test func nestedObjectsAndArrayItemsAreRewrittenToo() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object",
         "properties":{
           "user":{"type":"object","properties":{"id":{"type":"string"},"tag":{"type":"string"}},"required":["id"]},
           "items":{"type":"array","items":{"type":"object","properties":{"sku":{"type":"string"}},"required":["sku"]}}
         },
         "required":["user","items"]}
        """)

        let strict = JSONSchemaNormalizer.openAIStrict(schema)
        let properties = try #require(strict["properties"] as? [String: Any])

        let user = try #require(properties["user"] as? [String: Any])
        #expect(user["additionalProperties"] as? Bool == false)
        #expect(user["required"] as? [String] == ["id", "tag"])
        let tag = try #require((user["properties"] as? [String: Any])?["tag"] as? [String: Any])
        #expect(tag["type"] as? [String] == ["string", "null"])

        let items = try #require(properties["items"] as? [String: Any])
        let itemSchema = try #require(items["items"] as? [String: Any])
        #expect(itemSchema["additionalProperties"] as? Bool == false)
        #expect(itemSchema["required"] as? [String] == ["sku"])
    }

    @Test func definitionsAndCombinatorBranchesAreRewritten() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object",
         "$defs":{"node":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}},
         "properties":{"root":{"$ref":"#/$defs/node"},
                       "either":{"anyOf":[{"type":"object","properties":{"x":{"type":"number"}},"required":["x"]},
                                          {"type":"string"}]}},
         "required":["root","either"]}
        """)

        let strict = JSONSchemaNormalizer.openAIStrict(schema)

        let defs = try #require(strict["$defs"] as? [String: Any])
        let node = try #require(defs["node"] as? [String: Any])
        #expect(node["additionalProperties"] as? Bool == false)

        let properties = try #require(strict["properties"] as? [String: Any])
        let either = try #require(properties["either"] as? [String: Any])
        let branches = try #require(either["anyOf"] as? [Any])
        let objectBranch = try #require(branches.first as? [String: Any])
        #expect(objectBranch["additionalProperties"] as? Bool == false)
    }

    /// A `$ref` carries no `type` to widen, so an optional one is wrapped in a
    /// union rather than left non-nullable.
    @Test func optionalReferenceIsWrappedInAnyOf() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object",
         "$defs":{"node":{"type":"object","properties":{"v":{"type":"string"}},"required":["v"]}},
         "properties":{"child":{"$ref":"#/$defs/node"}},
         "required":[]}
        """)

        let strict = JSONSchemaNormalizer.openAIStrict(schema)
        let child = try #require((strict["properties"] as? [String: Any])?["child"] as? [String: Any])
        let branches = try #require(child["anyOf"] as? [Any])
        #expect(branches.count == 2)
        #expect((branches[0] as? [String: Any])?["$ref"] as? String == "#/$defs/node")
        #expect((branches[1] as? [String: Any])?["type"] as? String == "null")
    }

    /// Rewriting must be idempotent: an already-strict schema is unchanged, so
    /// a caller who did the work themselves is not penalised.
    @Test func rewritingAnAlreadyStrictSchemaChangesNothing() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object","properties":{"a":{"type":["string","null"]}},
         "required":["a"],"additionalProperties":false}
        """)

        let once = JSONSchemaNormalizer.openAIStrict(schema)
        let twice = JSONSchemaNormalizer.openAIStrict(once)
        let a = try #require((twice["properties"] as? [String: Any])?["a"] as? [String: Any])
        #expect(a["type"] as? [String] == ["string", "null"])
        #expect(twice["required"] as? [String] == ["a"])
    }

    /// `allOf` branches are merged, so closing each one would forbid the
    /// properties its siblings contribute and make a valid schema
    /// unsatisfiable. They are passed through untouched.
    @Test func allOfBranchesAreLeftUntouched() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object",
         "properties":{"thing":{"allOf":[{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]},
                                         {"type":"object","properties":{"b":{"type":"string"}},"required":["b"]}]}},
         "required":["thing"]}
        """)

        let strict = JSONSchemaNormalizer.openAIStrict(schema)
        let thing = try #require((strict["properties"] as? [String: Any])?["thing"] as? [String: Any])
        let branches = try #require(thing["allOf"] as? [Any])
        for branch in branches {
            #expect((branch as? [String: Any])?["additionalProperties"] == nil)
        }
    }

    /// Widening only `type` is not enough: a value must satisfy every keyword,
    /// so an `enum` that does not list `null` keeps rejecting it — which would
    /// turn an optional property into a mandatory one.
    @Test func optionalEnumAdmitsNull() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object",
         "properties":{"status":{"type":"string","enum":["on","off"]},
                       "bare":{"enum":["x","y"]}},
         "required":[]}
        """)

        let strict = JSONSchemaNormalizer.openAIStrict(schema)
        let properties = try #require(strict["properties"] as? [String: Any])

        let status = try #require(properties["status"] as? [String: Any])
        #expect(status["type"] as? [String] == ["string", "null"])
        #expect((status["enum"] as? [Any])?.contains { $0 is NSNull } == true)

        // An enum with no `type` key still has to admit null.
        let bare = try #require(properties["bare"] as? [String: Any])
        #expect((bare["enum"] as? [Any])?.contains { $0 is NSNull } == true)
    }

    /// A `const` pins one value and cannot be widened in place, so the whole
    /// subschema becomes a branch of a union.
    @Test func optionalConstIsWrappedInAnyOf() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object","properties":{"kind":{"const":"fixed"}},"required":[]}
        """)

        let kind = try #require(
            (JSONSchemaNormalizer.openAIStrict(schema)["properties"] as? [String: Any])?["kind"]
                as? [String: Any]
        )
        let branches = try #require(kind["anyOf"] as? [Any])
        #expect((branches[0] as? [String: Any])?["const"] as? String == "fixed")
        #expect((branches[1] as? [String: Any])?["type"] as? String == "null")
    }

    /// An object declaring no `properties` key still has to be closed, or
    /// strict mode rejects it.
    @Test func objectWithoutPropertiesIsStillClosed() throws {
        let schema = try JSONSchemaNormalizer.parseObject(
            #"{"type":"object","description":"free-form"}"#
        )
        let strict = JSONSchemaNormalizer.openAIStrict(schema)
        #expect(strict["additionalProperties"] as? Bool == false)
        #expect(strict["required"] as? [String] == [])

        // An explicit map-typed `additionalProperties` is left alone rather
        // than silently reinterpreted as an empty object.
        let map = try JSONSchemaNormalizer.parseObject(
            #"{"type":"object","additionalProperties":{"type":"string"}}"#
        )
        #expect(JSONSchemaNormalizer.openAIStrict(map)["additionalProperties"] as? [String: Any] != nil)
    }

    /// `allOf` siblings can supply a required name this node does not declare;
    /// dropping it from `required` would loosen the schema.
    @Test func requiredNamesFromSiblingsSurvive() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object",
         "allOf":[{"type":"object","properties":{"a":{"type":"string"}}}],
         "properties":{"b":{"type":"string"}},
         "required":["a","b"]}
        """)

        let strict = JSONSchemaNormalizer.openAIStrict(schema)
        #expect(strict["required"] as? [String] == ["a", "b"])
    }

    @Test func nonObjectSchemaIsRejected() {
        #expect(throws: ArbiterError.self) { try JSONSchemaNormalizer.parseObject("[1,2]") }
        #expect(throws: ArbiterError.self) { try JSONSchemaNormalizer.parseObject("{oops}") }
    }
}

// MARK: - Reasoning models

@Suite("OpenAI reasoning models")
struct OpenAIReasoningModelTests {
    let mapper = OpenAIMapper(defaultModel: .gpt4o)

    /// The `o` in `gpt-4o` must never be read as the o-series: doing so would
    /// strip temperature from a model that accepts it.
    @Test(arguments: [
        ("gpt-5.6-sol", true), ("gpt-5", true), ("gpt-5-mini", true),
        ("gpt-5-2025-08-07", true), ("o1", true), ("o1-pro", true),
        ("o3", true), ("o3-mini", true), ("o4-mini", true),
        ("gpt-4o", false), ("gpt-4o-mini", false), ("gpt-4.1", false),
        ("gpt-4-turbo", false), ("llama-3.3-70b", false),
        // A real non-reasoning member of a family whose prefix implies otherwise.
        ("gpt-5-chat-latest", false),
    ])
    func reasoningFamilyDetectedFromRawID(model: String, isReasoning: Bool) {
        #expect(OpenAIModel.isReasoningModel(id: model) == isReasoning)
    }

    @Test func reasoningModelSendsMaxCompletionTokensAndDropsSampling() throws {
        let request = AIRequest.chat("Think")
            .withModel("gpt-5.6-sol")
            .withMaxTokens(2048)
            .withTemperature(0.7)
            .withTopP(0.9)

        let json = try requestJSON(mapper.buildRequestBody(request, stream: false))
        #expect(json["max_completion_tokens"] as? Int == 2048)
        // Sending any of these to a reasoning model is a 400.
        #expect(json["max_tokens"] == nil)
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
    }

    @Test func nonReasoningModelKeepsMaxTokensAndSampling() throws {
        let request = AIRequest.chat("Write")
            .withModel("gpt-4o")
            .withMaxTokens(512)
            .withTemperature(0.7)
            .withTopP(0.9)

        let json = try requestJSON(mapper.buildRequestBody(request, stream: false))
        #expect(json["max_tokens"] as? Int == 512)
        #expect(json["max_completion_tokens"] == nil)
        #expect(json["temperature"] as? Double == 0.7)
        #expect(json["top_p"] as? Double == 0.9)
    }

    @Test func reasoningEffortIsSent() throws {
        let request = AIRequest.chat("Think hard")
            .withModel("gpt-5.6-sol")
            .withProviderOptions(OpenAIOptions.reasoning(.xhigh), for: .openAI)

        let json = try requestJSON(mapper.buildRequestBody(request, stream: false))
        #expect(json["reasoning_effort"] as? String == "xhigh")
    }

    @Test func reasoningEffortOnNonReasoningModelIsRejected() {
        let request = AIRequest.chat("Think")
            .withModel("gpt-4o")
            .withProviderOptions(OpenAIOptions.reasoning(.high), for: .openAI)

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    /// `gpt-5` documents `minimal|low|medium|high` only, so `xhigh` — valid on
    /// the 5.6 family — is caught locally rather than as a 400.
    @Test func effortOutsideAModelsPublishedSetIsRejected() {
        let request = AIRequest.chat("Think")
            .withModel("gpt-5")
            .withProviderOptions(OpenAIOptions.reasoning(.xhigh), for: .openAI)

        #expect(throws: ArbiterError.self) {
            try mapper.buildRequestBody(request, stream: false)
        }
    }

    /// A model whose accepted set is not published takes whatever the caller
    /// asked for — refusing would block the model from being used correctly.
    @Test func effortPassesThroughForModelsWithNoPublishedSet() throws {
        let request = AIRequest.chat("Think")
            .withModel("o4-mini")
            .withProviderOptions(OpenAIOptions.reasoning(.max), for: .openAI)

        let json = try requestJSON(mapper.buildRequestBody(request, stream: false))
        #expect(json["reasoning_effort"] as? String == "max")
    }
}

// MARK: - Streaming

@Suite("OpenAI streaming")
struct OpenAIStreamingTests {
    let mapper = OpenAIMapper(defaultModel: .gpt4o)

    /// A recorded stream: text, then two parallel tool calls whose arguments
    /// arrive as fragments, then finish_reason, then the usage-only chunk.
    static let toolCallStream = [
        #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#,
        #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Checking"},"finish_reason":null}]}"#,
        #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}"#,
        #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]},"finish_reason":null}]}"#,
        #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]},"finish_reason":null}]}"#,
        #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"get_time","arguments":"{}"}}]},"finish_reason":null}]}"#,
        #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        #"{"id":"chatcmpl-1","choices":[],"usage":{"prompt_tokens":42,"completion_tokens":17,"total_tokens":59}}"#,
        "[DONE]",
    ]

    /// Replay a recorded stream the way the provider does, stopping at the
    /// first chunk that says the stream is over.
    private func replay(_ events: [String]) -> [AIStreamChunk] {
        var state = OpenAIStreamState()
        var chunks: [AIStreamChunk] = []
        for event in events {
            guard let chunk = mapper.parseStreamEvent(event, state: &state) else { continue }
            chunks.append(chunk)
            if chunk.isComplete { break }
        }
        return chunks
    }

    @Test func streamedToolCallsSurfaceWithParsedArguments() throws {
        let chunks = replay(Self.toolCallStream)

        let final = try #require(chunks.last)
        #expect(final.isComplete)
        let calls = try #require(final.toolCalls)
        #expect(calls.count == 2)

        // Ordered by the stream's own `index`, not by arrival.
        #expect(calls[0].id == "call_a")
        #expect(calls[0].name == "get_weather")
        #expect(calls[0].arguments == .object(["city": .string("Paris")]))
        #expect(calls[1].id == "call_b")
        #expect(calls[1].name == "get_time")
        #expect(calls[1].arguments == .object([:]))
    }

    /// The regression this item exists to fix: with `include_usage` the final
    /// chunk has no choices, so a parser that requires `choices.first` loses
    /// every streamed token count.
    @Test func usageOnlyFinalChunkIsCaptured() throws {
        let chunks = replay(Self.toolCallStream)

        let final = try #require(chunks.last)
        #expect(final.isComplete)
        let usage = try #require(final.usage)
        #expect(usage.inputTokens == 42)
        #expect(usage.outputTokens == 17)
        #expect(final.finishReason == .toolCall)
    }

    @Test func textDeltasAccumulateInOrder() throws {
        let chunks = replay([
            #"{"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"lo "},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"world"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}"#,
        ])

        #expect(chunks.map(\.delta).prefix(3) == ["Hel", "lo ", "world"])
        let final = try #require(chunks.last)
        #expect(final.accumulatedContent == "Hello world")
        #expect(final.finishReason == .complete)
        #expect(final.usage?.outputTokens == 3)
    }

    /// OpenAI-compatible hosts often omit the usage chunk entirely. The stream
    /// must still terminate, carrying whatever it did collect.
    @Test func streamWithoutUsageChunkStillTerminatesOnDone() throws {
        let chunks = replay([
            #"{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])

        let final = try #require(chunks.last)
        #expect(final.isComplete)
        #expect(final.accumulatedContent == "Hi")
        #expect(final.finishReason == .complete)
        #expect(final.usage == nil)
    }

    /// A host that omits `index` on a single streamed call must still produce
    /// one call rather than dropping it.
    @Test func toolCallWithoutIndexIsStillAccumulated() throws {
        let chunks = replay([
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"id":"call_x","function":{"name":"ping","arguments":"{\"n\":"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"1}"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ])

        let calls = try #require(chunks.last?.toolCalls)
        #expect(calls.count == 1)
        #expect(calls[0].name == "ping")
        #expect(calls[0].arguments == .object(["n": .number(1)]))
    }

    /// A truncated stream leaves unparseable argument text. The call is still
    /// surfaced — losing it silently would strand the tool loop.
    @Test func truncatedArgumentsDegradeToEmptyRatherThanDroppingTheCall() throws {
        let chunks = replay([
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_t","function":{"name":"search","arguments":"{\"q\":\"un"}}]},"finish_reason":null}]}"#,
            "[DONE]",
        ])

        let calls = try #require(chunks.last?.toolCalls)
        #expect(calls.count == 1)
        #expect(calls[0].name == "search")
        #expect(calls[0].arguments == .object([:]))
    }

    @Test func streamedRefusalIsReportedAsRefusal() throws {
        let chunks = replay([
            #"{"choices":[{"index":0,"delta":{"refusal":"I can't help with that."},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])

        #expect(chunks.last?.finishReason == .refusal)
    }

    /// OpenAI puts `finish_reason` on its own chunk, but proxies and
    /// compatible hosts sometimes attach it to the last content chunk. Reading
    /// the content and returning early would lose the reason entirely.
    @Test func finishReasonOnTheSameChunkAsContentIsNotLost() throws {
        let chunks = replay([
            #"{"choices":[{"index":0,"delta":{"content":"Done"},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])

        #expect(chunks.first?.delta == "Done")
        #expect(chunks.first?.finishReason == .complete)
        #expect(chunks.last?.isComplete == true)
        #expect(chunks.last?.finishReason == .complete)
    }

    /// A host that sends usage alongside choices rather than on its own trailing
    /// chunk must not end the stream early — there is still content to come.
    @Test func usageArrivingWithChoicesDoesNotEndTheStream() throws {
        let chunks = replay([
            #"{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}"#,
            #"{"choices":[{"index":0,"delta":{"content":" there"},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])

        #expect(chunks.count == 3)
        let final = try #require(chunks.last)
        #expect(final.accumulatedContent == "Hi there")
        #expect(final.usage?.inputTokens == 3)
    }

    /// Parallel calls that arrive without an `index` must not collapse onto one
    /// slot: their ids would overwrite each other and their argument JSON would
    /// splice into unparseable text.
    @Test func parallelCallsWithoutIndexGetSeparateSlots() throws {
        let chunks = replay([
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"id":"call_a","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"id":"call_b","function":{"name":"get_time","arguments":"{}"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ])

        let calls = try #require(chunks.last?.toolCalls)
        #expect(calls.count == 2)
        #expect(calls.map(\.id) == ["call_a", "call_b"])
        #expect(calls[0].arguments == .object(["city": .string("Paris")]))
    }

    /// Some proxies repeat the whole function name on every argument fragment.
    /// Appending each one would yield `get_weatherget_weather`.
    @Test func repeatedFunctionNameIsNotConcatenated() throws {
        let chunks = replay([
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"get_weather","arguments":"{\"city\":"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"get_weather","arguments":"\"Paris\"}"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]",
        ])

        let calls = try #require(chunks.last?.toolCalls)
        #expect(calls.count == 1)
        #expect(calls[0].name == "get_weather")
        #expect(calls[0].arguments == .object(["city": .string("Paris")]))
    }

    /// A choice-less frame that carries no usage (Azure's
    /// `prompt_filter_results`, proxy keep-alives) must not be mistaken for the
    /// end of the turn.
    @Test func choicelessFrameWithoutUsageDoesNotEndTheStream() throws {
        let chunks = replay([
            #"{"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}"#,
            #"{"choices":[],"prompt_filter_results":[{"prompt_index":0}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":" there"},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])

        #expect(chunks.last?.accumulatedContent == "Hi there")
    }

    /// The finish chunk and the terminating chunk both list every call of the
    /// turn — the contract consumers are documented to rely on.
    @Test func finishAndFinalChunksCarryTheSameCallSet() throws {
        let chunks = replay(Self.toolCallStream)
        let withCalls = chunks.filter { $0.toolCalls != nil }

        #expect(withCalls.count == 2)
        #expect(withCalls[0].isComplete == false)
        #expect(withCalls[1].isComplete == true)
        #expect(withCalls[0].toolCalls?.map(\.id) == withCalls[1].toolCalls?.map(\.id))
    }

    @Test func streamRequestAsksForUsage() throws {
        let json = try requestJSON(mapper.buildRequestBody(AIRequest.chat("Hi"), stream: true))
        #expect(json["stream"] as? Bool == true)
        let options = try #require(json["stream_options"] as? [String: Any])
        #expect(options["include_usage"] as? Bool == true)
    }
}

// MARK: - Non-streaming response parsing

@Suite("OpenAI response parsing")
struct OpenAIResponseParsingTests {
    let mapper = OpenAIMapper(defaultModel: .gpt4o)

    /// `prompt_tokens` already includes cache hits and is reported as-is.
    /// Splitting the cached count out would make `TokenUsage.cost` apply its
    /// single fixed cache discount — right for Anthropic, but an undercount for
    /// OpenAI, whose discount is per-model. Spend must not be understated.
    @Test func cachedPromptTokensStayInsideTheInputTotal() throws {
        let body = Data("""
        {"id":"chatcmpl-1","model":"gpt-4o",
         "choices":[{"index":0,"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":1000,"completion_tokens":10,"total_tokens":1010,
                  "prompt_tokens_details":{"cached_tokens":800}}}
        """.utf8)

        let usage = try #require(mapper.parseResponse(body).usage)
        #expect(usage.inputTokens == 1000)
        #expect(usage.cacheReadInputTokens == nil)
        #expect(usage.billedInputTokens == 1000)
        // Priced at the full input rate: never cheaper than reality.
        #expect(usage.cost(inputPerMillion: 2.50, outputPerMillion: 10.0) == 0.0026)
    }

    /// A safety refusal arrives in its own field alongside `finish_reason: stop`,
    /// so it would otherwise read as an ordinary empty answer.
    @Test func refusalIsSurfacedAsRefusalNotAnEmptyAnswer() throws {
        let body = Data("""
        {"id":"chatcmpl-1","model":"gpt-4o",
         "choices":[{"index":0,"message":{"role":"assistant","content":null,
                     "refusal":"I'm sorry, I can't help with that."},"finish_reason":"stop"}]}
        """.utf8)

        let response = try mapper.parseResponse(body)
        #expect(response.finishReason == .refusal)
        #expect(response.content == "I'm sorry, I can't help with that.")
    }
}

// MARK: - Responses API transport

@Suite("OpenAI Responses API")
struct OpenAIResponsesAPITests {
    let mapper = OpenAIResponsesMapper(defaultModel: .gpt56Terra)

    @Test func chatCompletionsRemainsTheDefaultTransport() {
        #expect(OpenAIProvider.api(for: AIRequest.chat("Hi")) == .chatCompletions)
        #expect(
            OpenAIProvider.api(
                for: AIRequest.chat("Hi").withProviderOptions(OpenAIOptions.responsesAPI(), for: .openAI)
            ) == .responses
        )
    }

    @Test func requestUsesInputItemsAndInstructions() throws {
        let request = AIRequest(
            messages: [.user("What is the weather?")],
            maxTokens: 1024,
            systemPrompt: "You are terse."
        )

        let json = try requestJSON(mapper.buildRequestBody(request, stream: false))
        #expect(json["model"] as? String == "gpt-5.6-terra")
        // The system prompt becomes `instructions`, not an input item.
        #expect(json["instructions"] as? String == "You are terse.")
        #expect(json["max_output_tokens"] as? Int == 1024)
        #expect(json["messages"] == nil)

        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[0]["role"] as? String == "user")
        let parts = try #require(input[0]["content"] as? [[String: Any]])
        #expect(parts[0]["type"] as? String == "input_text")
        #expect(parts[0]["text"] as? String == "What is the weather?")
    }

    /// An assistant turn being replayed carries `output_text`, not `input_text`.
    @Test func replayedAssistantTextUsesOutputTextParts() throws {
        let request = AIRequest(messages: [.user("Hi"), .assistant("Hello!")])
        let input = try #require(
            requestJSON(mapper.buildRequestBody(request, stream: false))["input"] as? [[String: Any]]
        )

        let assistantParts = try #require(input[1]["content"] as? [[String: Any]])
        #expect(assistantParts[0]["type"] as? String == "output_text")
    }

    /// Function tools are flat here — no nested `function` wrapper.
    @Test func toolsAreFlatRatherThanNested() throws {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Get weather",
            inputSchema: .object(["type": .string("object")])
        )
        let json = try requestJSON(
            mapper.buildRequestBody(AIRequest.chat("Weather?").withTools([tool]), stream: false)
        )

        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "function")
        #expect(tools[0]["name"] as? String == "get_weather")
        #expect(tools[0]["function"] == nil)
        #expect(tools[0]["parameters"] != nil)
    }

    /// Tool calls and their results are their own input items, keyed by
    /// `call_id` — not `tool_calls` on a message and a `tool` role reply.
    @Test func toolCallsAndResultsBecomeTheirOwnItems() throws {
        let calls = [
            ToolCall(id: "call_a", name: "get_weather", arguments: .object(["city": .string("Paris")])),
            ToolCall(id: "call_b", name: "get_time", arguments: .object([:])),
        ]
        let request = AIRequest(messages: [
            .user("Weather and time?"),
            Message(role: .assistant, content: .toolCalls(calls)),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "call_a", content: "18C"),
                ToolResult(toolCallId: "call_b", content: "14:00"),
            ])),
        ])

        let input = try #require(
            requestJSON(mapper.buildRequestBody(request, stream: false))["input"] as? [[String: Any]]
        )
        #expect(input.map { $0["type"] as? String }
            == ["message", "function_call", "function_call", "function_call_output", "function_call_output"])

        #expect(input[1]["call_id"] as? String == "call_a")
        #expect(input[1]["name"] as? String == "get_weather")
        // Arguments travel as a JSON string, as on Chat Completions.
        #expect(input[1]["arguments"] as? String == #"{"city":"Paris"}"#)

        #expect(input[3]["call_id"] as? String == "call_a")
        #expect(input[3]["output"] as? String == "18C")
    }

    /// Structured output moves from `response_format` to `text.format`, with
    /// the schema keys inline rather than under a `json_schema` wrapper.
    @Test func structuredOutputUsesTextFormat() throws {
        let request = AIRequest.chat("Answer")
            .withResponseFormat(.structured(schema: #"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}"#))

        let json = try requestJSON(mapper.buildRequestBody(request, stream: false))
        #expect(json["response_format"] == nil)

        let format = try #require((json["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["name"] as? String == "arbiter_output")
        #expect(format["strict"] as? Bool == true)
        #expect(format["json_schema"] == nil)
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test func reasoningEffortIsNestedUnderReasoning() throws {
        let request = AIRequest.chat("Think")
            .withModel("gpt-5.6-sol")
            .withProviderOptions(
                OpenAIOptions(api: .responses, reasoningEffort: .high, store: false),
                for: .openAI
            )

        let json = try requestJSON(mapper.buildRequestBody(request, stream: false))
        #expect((json["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(json["store"] as? Bool == false)
        #expect(json["reasoning_effort"] == nil)
    }

    @Test func parsesOutputItemsIntoAUnifiedResponse() throws {
        let body = Data("""
        {"id":"resp_1","model":"gpt-5.6-terra","status":"completed",
         "output":[
           {"type":"reasoning","id":"rs_1","summary":[{"type":"text","text":"Weighing options."}],"status":"completed"},
           {"type":"message","id":"msg_1","role":"assistant","status":"completed",
            "content":[{"type":"output_text","text":"It is 18C in Paris."}]}
         ],
         "usage":{"input_tokens":120,"output_tokens":14,"total_tokens":134,
                  "input_tokens_details":{"cached_tokens":100}}}
        """.utf8)

        let response = try mapper.parseResponse(body)
        #expect(response.id == "resp_1")
        #expect(response.content == "It is 18C in Paris.")
        #expect(response.reasoning == "Weighing options.")
        #expect(response.finishReason == .complete)
        // Cache hits stay inside the input total — see
        // `cachedPromptTokensStayInsideTheInputTotal`.
        #expect(response.usage?.inputTokens == 120)
        #expect(response.usage?.cacheReadInputTokens == nil)
        #expect(response.usage?.outputTokens == 14)
    }

    /// `call_id` is the handle a result must quote; `id` names the output item,
    /// so round-tripping the wrong one breaks the next request.
    @Test func parsesFunctionCallItemsUsingCallID() throws {
        let body = Data("""
        {"id":"resp_2","model":"gpt-5.6-terra","status":"completed",
         "output":[{"type":"function_call","id":"fc_1","call_id":"call_abc",
                    "name":"get_weather","arguments":"{\\"city\\":\\"Paris\\"}","status":"completed"}]}
        """.utf8)

        let response = try mapper.parseResponse(body)
        #expect(response.finishReason == .toolCall)
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].id == "call_abc")
        #expect(response.toolCalls[0].name == "get_weather")
        #expect(response.toolCalls[0].arguments == .object(["city": .string("Paris")]))
    }

    @Test func parsesRefusalAndIncompleteTurns() throws {
        let refusalBody = Data("""
        {"id":"resp_3","model":"gpt-5.6-terra","status":"completed",
         "output":[{"type":"message","id":"m","role":"assistant","status":"completed",
                    "content":[{"type":"refusal","refusal":"I can't help with that."}]}]}
        """.utf8)
        let refusal = try mapper.parseResponse(refusalBody)
        #expect(refusal.finishReason == .refusal)
        #expect(refusal.content == "I can't help with that.")

        let truncatedBody = Data("""
        {"id":"resp_4","model":"gpt-5.6-terra","status":"incomplete",
         "incomplete_details":{"reason":"max_tokens"},
         "output":[{"type":"message","id":"m","role":"assistant","status":"incomplete",
                    "content":[{"type":"output_text","text":"Partial"}]}]}
        """.utf8)
        let truncated = try mapper.parseResponse(truncatedBody)
        #expect(truncated.finishReason == .maxTokens)
        #expect(truncated.content == "Partial")
    }
}

// MARK: - Embeddings

@Suite("OpenAI embeddings")
struct OpenAIEmbeddingTests {
    @Test func parsesVectorsInInputOrder() throws {
        // Deliberately out of order to prove the `index` is honoured.
        let body = Data("""
        {"object":"list","model":"text-embedding-3-small",
         "data":[{"object":"embedding","index":1,"embedding":[0.3,0.4]},
                 {"object":"embedding","index":0,"embedding":[0.1,0.2]}],
         "usage":{"prompt_tokens":8,"total_tokens":8}}
        """.utf8)

        let response = try OpenAIProvider.parseEmbeddingResponse(
            body, requestedModel: "text-embedding-3-small", inputCount: 2
        )
        #expect(response.embeddings == [[0.1, 0.2], [0.3, 0.4]])
        #expect(response.model == "text-embedding-3-small")
        #expect(response.usage?.inputTokens == 8)
        // Embedding endpoints bill input only.
        #expect(response.usage?.outputTokens == 0)
    }

    /// A short response would silently misalign vectors with their inputs, so
    /// it fails instead.
    @Test func mismatchedVectorCountThrows() {
        let body = Data("""
        {"object":"list","model":"text-embedding-3-small",
         "data":[{"object":"embedding","index":0,"embedding":[0.1]}]}
        """.utf8)

        #expect(throws: ArbiterError.self) {
            try OpenAIProvider.parseEmbeddingResponse(
                body, requestedModel: "text-embedding-3-small", inputCount: 2
            )
        }
    }

    @Test func malformedResponseThrows() {
        #expect(throws: ArbiterError.self) {
            try OpenAIProvider.parseEmbeddingResponse(
                Data(#"{"error":"nope"}"#.utf8),
                requestedModel: "text-embedding-3-small",
                inputCount: 1
            )
        }
    }
}

// MARK: - Model catalogue

@Suite("OpenAI model catalogue")
struct OpenAIModelCatalogueTests {
    /// Values verified 2026-09-01 against developers.openai.com/api/docs/models
    /// and /api/docs/pricing.
    @Test func currentModelsCarryVerifiedLimitsAndPricing() {
        #expect(OpenAIModel.gpt56Sol.contextWindow == 1_050_000)
        #expect(OpenAIModel.gpt56Sol.maxOutputTokens == 128_000)
        #expect(OpenAIModel.gpt56Sol.costPerMillionInput == 4.00)
        #expect(OpenAIModel.gpt56Sol.costPerMillionOutput == 20.00)
        #expect(OpenAIModel.gpt56Sol.costPerMillionCachedInput == 0.40)

        #expect(OpenAIModel.gpt5.contextWindow == 400_000)
        #expect(OpenAIModel.gpt41.contextWindow == 1_047_576)
        #expect(OpenAIModel.gpt4o.contextWindow == 128_000)
        #expect(OpenAIModel.o3.contextWindow == 200_000)
    }

    @Test func reasoningFlagMatchesTheFamily() {
        #expect(OpenAIModel.gpt56Sol.isReasoningModel)
        #expect(OpenAIModel.gpt5Nano.isReasoningModel)
        #expect(OpenAIModel.o3.isReasoningModel)
        #expect(!OpenAIModel.gpt4o.isReasoningModel)
        #expect(!OpenAIModel.gpt41.isReasoningModel)
    }

    /// The retired ID this catalogue replaced must no longer resolve.
    @Test func supersededAndInventedIDsBehaveAsExpected() {
        #expect(OpenAIModel.named("gpt-4o-2024-05-13") == nil)
        // A superseded ID still resolves so stored conversations keep working…
        #expect(OpenAIModel.named("o1-mini") != nil)
        // …but is not offered as a default.
        #expect(!OpenAIModel.allCases.contains { $0.rawValue == "o1-mini" })
    }

    @Test func publishedReasoningEffortSetsMatchTheDocs() {
        #expect(OpenAIModel.gpt56Sol.supportedReasoningEfforts?.contains(.xhigh) == true)
        #expect(OpenAIModel.gpt5.supportedReasoningEfforts?.contains(.xhigh) == false)
        #expect(OpenAIModel.gpt5.supportedReasoningEfforts?.contains(.minimal) == true)
        // Not published for the o-series, so nothing is rejected locally.
        #expect(OpenAIModel.o4Mini.supportedReasoningEfforts == nil)
    }
}

// MARK: - Helpers

private func requestJSON(_ data: Data) throws -> [String: Any] {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ArbiterError.decodingFailed(context: "Request body is not a JSON object")
    }
    return json
}
