// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("Anthropic — structured outputs")
struct AnthropicStructuredOutputTests {
    let mapper = AnthropicMapper(defaultModel: .claudeSonnet5)

    /// The shape in the published example: `output_config.format` with
    /// `type: "json_schema"` and the schema as an object. Generally available,
    /// so nothing here rides on a beta header.
    @Test func structuredRequestMatchesDocumentedShape() throws {
        let schema = """
        {"type":"object","properties":{"name":{"type":"string"},"email":{"type":"string"}},
         "required":["name","email"]}
        """
        let request = AIRequest.chat("Extract the contact")
            .withResponseFormat(.structured(schema: schema))

        let json = try Self.body(mapper.buildRequestBody(request, stream: false))
        let outputConfig = try #require(json["output_config"] as? [String: Any])
        let format = try #require(outputConfig["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")

        let sent = try #require(format["schema"] as? [String: Any])
        #expect(sent["type"] as? String == "object")
        #expect(sent["required"] as? [String] == ["name", "email"])
        // Objects must be closed, or the request is rejected.
        #expect(sent["additionalProperties"] as? Bool == false)
    }

    /// Anthropic allows optional properties, so — unlike OpenAI strict mode —
    /// `required` is left exactly as the caller wrote it.
    @Test func optionalPropertiesStayOptional() throws {
        let schema = """
        {"type":"object","properties":{"name":{"type":"string"},"nickname":{"type":"string"}},
         "required":["name"]}
        """
        let request = AIRequest.chat("Extract").withResponseFormat(.structured(schema: schema))

        let json = try Self.body(mapper.buildRequestBody(request, stream: false))
        let format = try #require(
            (json["output_config"] as? [String: Any])?["format"] as? [String: Any]
        )
        let sent = try #require(format["schema"] as? [String: Any])
        #expect(sent["required"] as? [String] == ["name"])

        let properties = try #require(sent["properties"] as? [String: Any])
        let nickname = try #require(properties["nickname"] as? [String: Any])
        #expect(nickname["type"] as? String == "string")
    }

    /// Numeric and string constraints are a 400, not a silent ignore.
    @Test func unsupportedConstraintsAreRemoved() throws {
        let schema = """
        {"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object",
         "properties":{
           "age":{"type":"integer","minimum":0,"maximum":130},
           "name":{"type":"string","minLength":1,"maxLength":40,"format":"email"},
           "code":{"type":"string","format":"hostname"},
           "tags":{"type":"array","items":{"type":"string"},"minItems":3,"maxItems":9}},
         "required":["age","name","code","tags"]}
        """
        let request = AIRequest.chat("Extract").withResponseFormat(.structured(schema: schema))

        let json = try Self.body(mapper.buildRequestBody(request, stream: false))
        let format = try #require(
            (json["output_config"] as? [String: Any])?["format"] as? [String: Any]
        )
        let sent = try #require(format["schema"] as? [String: Any])
        #expect(sent["$schema"] == nil)

        let properties = try #require(sent["properties"] as? [String: Any])
        let age = try #require(properties["age"] as? [String: Any])
        #expect(age["minimum"] == nil)
        #expect(age["maximum"] == nil)
        #expect(age["type"] as? String == "integer")

        let name = try #require(properties["name"] as? [String: Any])
        #expect(name["minLength"] == nil)
        #expect(name["maxLength"] == nil)
        // `email` is on the supported format list; `hostname` too.
        #expect(name["format"] as? String == "email")
        let code = try #require(properties["code"] as? [String: Any])
        #expect(code["format"] as? String == "hostname")

        let tags = try #require(properties["tags"] as? [String: Any])
        #expect(tags["maxItems"] == nil)
        // Only 0 and 1 are implemented, so a larger minimum is dropped rather
        // than clamped down to one the caller did not ask for.
        #expect(tags["minItems"] == nil)
    }

    @Test func jsonAndTextFormatsSendNoOutputConfig() throws {
        for format in [ResponseFormat.json, .text] {
            let request = AIRequest.chat("Hi").withResponseFormat(format)
            let json = try Self.body(mapper.buildRequestBody(request, stream: false))
            #expect(json["output_config"] == nil)
        }
    }

    @Test func aSchemaThatIsNotAJSONObjectIsRejectedLocally() {
        let request = AIRequest.chat("Hi").withResponseFormat(.structured(schema: "not json"))
        #expect(throws: ArbiterError.self) {
            _ = try mapper.buildRequestBody(request, stream: false)
        }
    }

    /// A refusal is the model declining, not malformed JSON: the schema does
    /// not constrain the refusal message, so the caller has to be able to tell
    /// the two apart.
    @Test func aRefusalOnAStructuredTurnIsReportedAsARefusal() throws {
        // The turn that is refused is a schema-constrained one: the refusal
        // message is not bound by the schema, so a caller decoding the answer
        // has to be able to tell a refusal from malformed JSON.
        let request = AIRequest.chat("Do something disallowed")
            .withResponseFormat(.structured(schema: #"{"type":"object","properties":{}}"#))
        let sent = try Self.body(mapper.buildRequestBody(request, stream: false))
        #expect((sent["output_config"] as? [String: Any])?["format"] != nil)

        let fixture = """
        {"id":"msg_1","model":"claude-sonnet-5","role":"assistant",
         "content":[{"type":"text","text":"I can't help with that."}],
         "stop_reason":"refusal","usage":{"input_tokens":10,"output_tokens":8}}
        """
        let response = try mapper.parseResponse(Data(fixture.utf8))
        #expect(response.finishReason == .refusal)
        #expect(response.content == "I can't help with that.")
    }

    static func body(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite("JSONSchemaNormalizer provider dialects")
struct JSONSchemaNormalizerDialectTests {
    @Test func anthropicClosesNestedObjectsAndDefinitions() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object",
         "properties":{
           "address":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]},
           "history":{"type":"array","items":{"$ref":"#/$defs/entry"}}},
         "$defs":{"entry":{"type":"object","properties":{"when":{"type":"string"}}}},
         "required":["address"]}
        """)

        let normalised = JSONSchemaNormalizer.anthropicSchema(schema)

        #expect(normalised["additionalProperties"] as? Bool == false)
        let properties = try #require(normalised["properties"] as? [String: Any])
        let address = try #require(properties["address"] as? [String: Any])
        #expect(address["additionalProperties"] as? Bool == false)
        // An internal `$ref` is supported and left alone.
        let history = try #require(properties["history"] as? [String: Any])
        let items = try #require(history["items"] as? [String: Any])
        #expect(items["$ref"] as? String == "#/$defs/entry")
        let defs = try #require(normalised["$defs"] as? [String: Any])
        let entry = try #require(defs["entry"] as? [String: Any])
        #expect(entry["additionalProperties"] as? Bool == false)
    }

    /// An `allOf` branch is merged with its siblings, so closing one would
    /// forbid the properties the others contribute and leave the composition
    /// unsatisfiable.
    @Test func anthropicLeavesAllOfBranchesOpen() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object",
         "allOf":[
           {"type":"object","properties":{"a":{"type":"string"}}},
           {"type":"object","properties":{"b":{"type":"object","properties":{"c":{"type":"string"}}}}},
           {"type":"object","additionalProperties":{"type":"string"}}],
         "properties":{"top":{"type":"string"}}}
        """)

        let normalised = JSONSchemaNormalizer.anthropicSchema(schema)

        #expect(normalised["additionalProperties"] as? Bool == false)
        let branches = try #require(normalised["allOf"] as? [[String: Any]])
        #expect(branches[0]["additionalProperties"] == nil)
        #expect(branches[1]["additionalProperties"] == nil)
        // Leaving a branch open is about not *adding* a closure. A map type
        // already written into a branch is still coerced, since Anthropic
        // refuses any value but `false` wherever it appears.
        #expect(branches[2]["additionalProperties"] as? Bool == false)
        // A branch's own subschemas are standalone objects and are still closed.
        let properties = try #require(branches[1]["properties"] as? [String: Any])
        let nested = try #require(properties["b"] as? [String: Any])
        #expect(nested["additionalProperties"] as? Bool == false)
    }

    /// Anthropic documents which regex features it implements, so a `pattern`
    /// is enforced — dropping it would silently loosen the schema.
    @Test func anthropicKeepsPatterns() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object","properties":{"code":{"type":"string","pattern":"^[A-Z]+$"}}}
        """)
        let normalised = JSONSchemaNormalizer.anthropicSchema(schema)
        let properties = try #require(normalised["properties"] as? [String: Any])
        let code = try #require(properties["code"] as? [String: Any])
        #expect(code["pattern"] as? String == "^[A-Z]+$")
    }

    @Test func anthropicKeepsMinItemsOfZeroOrOne() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"},"minItems":1}}}
        """)
        let normalised = JSONSchemaNormalizer.anthropicSchema(schema)
        let properties = try #require(normalised["properties"] as? [String: Any])
        let tags = try #require(properties["tags"] as? [String: Any])
        #expect(tags["minItems"] as? Int == 1)
    }

    /// A schema-valued `additionalProperties` is a map type Anthropic cannot
    /// express, and anything other than `false` is refused outright.
    @Test func anthropicClosesAMapType() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object","additionalProperties":{"type":"string"}}
        """)
        let normalised = JSONSchemaNormalizer.anthropicSchema(schema)
        #expect(normalised["additionalProperties"] as? Bool == false)
    }

    @Test func geminiStripsOnlyWhatItCannotEnforce() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"x","type":"object",
         "properties":{
           "code":{"type":"string","pattern":"^[A-Z]+$","enum":["A","B"]},
           "age":{"type":"integer","minimum":0},
           "kind":{"anyOf":[{"type":"string","pattern":"x"},{"type":"null"}]}},
         "required":["code"],"propertyOrdering":["code","age","kind"]}
        """)

        let normalised = JSONSchemaNormalizer.geminiSchema(schema)

        #expect(normalised["$schema"] == nil)
        #expect(normalised["$id"] == nil)
        #expect(normalised["required"] as? [String] == ["code"])
        #expect(normalised["propertyOrdering"] as? [String] == ["code", "age", "kind"])

        let properties = try #require(normalised["properties"] as? [String: Any])
        let code = try #require(properties["code"] as? [String: Any])
        #expect(code["pattern"] == nil)
        #expect(code["enum"] as? [String] == ["A", "B"])
        // Gemini implements numeric bounds, so they stay.
        let age = try #require(properties["age"] as? [String: Any])
        #expect(age["minimum"] as? Int == 0)
        // Recursion reaches combinator branches too.
        let kind = try #require(properties["kind"] as? [String: Any])
        let branches = try #require(kind["anyOf"] as? [[String: Any]])
        #expect(branches[0]["pattern"] == nil)
        #expect(branches[0]["type"] as? String == "string")
    }

    /// The dialects are independent: neither pass may impose the other's rules.
    @Test func geminiDoesNotForceAdditionalPropertiesOrRequireEverything() throws {
        let schema = try JSONSchemaNormalizer.parseObject("""
        {"type":"object","properties":{"a":{"type":"string"},"b":{"type":"string"}},"required":["a"]}
        """)
        let normalised = JSONSchemaNormalizer.geminiSchema(schema)
        #expect(normalised["additionalProperties"] == nil)
        #expect(normalised["required"] as? [String] == ["a"])
    }
}
