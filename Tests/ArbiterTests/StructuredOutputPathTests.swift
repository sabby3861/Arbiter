// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

private struct Address: Codable, Sendable, Equatable {
    let city: String
    let postcode: String?
}

private struct Contact: Codable, Sendable, Equatable {
    let name: String
    let age: Int
    let score: Double
    let active: Bool
    let email: String?
    let tags: [String]
    let address: Address
    let previous: [Address]
}

private enum Priority: String, Codable, Sendable {
    case low, high
}

private struct Ticket: Codable, Sendable, Equatable {
    let title: String
    let priority: Priority
}

private final class Node: Codable, Sendable {
    let name: String
    let child: Node?
}

private struct Bag: Codable, Sendable {
    let values: [String: String]
}

@Suite("Schema builder")
struct JSONSchemaBuilderTests {
    private func schemaObject<T: Decodable>(for type: T.Type) throws -> [String: JSONValue] {
        let text = try JSONSchemaBuilder.schema(for: type)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard case .object(let fields) = value else {
            Issue.record("Schema is not an object")
            return [:]
        }
        return fields
    }

    @Test func aPlainCodableTypeBecomesAnObjectSchema() throws {
        let schema = try schemaObject(for: Contact.self)

        #expect(schema["type"] == .string("object"))
        #expect(schema["additionalProperties"] == .bool(false))

        guard case .object(let properties)? = schema["properties"] else {
            Issue.record("No properties")
            return
        }
        #expect(properties["name"] == .object(["type": .string("string")]))
        #expect(properties["age"] == .object(["type": .string("integer")]))
        #expect(properties["score"] == .object(["type": .string("number")]))
        #expect(properties["active"] == .object(["type": .string("boolean")]))
        #expect(properties["tags"] == .object([
            "type": .string("array"), "items": .object(["type": .string("string")]),
        ]))
        #expect(properties["address"] == .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("city")]),
            "properties": .object([
                "city": .object(["type": .string("string")]),
                "postcode": .object(["type": .string("string")]),
            ]),
        ]))
    }

    @Test func onlyNonOptionalPropertiesAreRequired() throws {
        let schema = try schemaObject(for: Contact.self)
        #expect(schema["required"] == .array([
            .string("active"), .string("address"), .string("age"), .string("name"),
            .string("previous"), .string("score"), .string("tags"),
        ]))
    }

    @Test func theSameTypeAlwaysProducesTheSameSchemaText() throws {
        #expect(try JSONSchemaBuilder.schema(for: Contact.self)
            == JSONSchemaBuilder.schema(for: Contact.self))
    }

    @Test func aTypeWithAnEnumCannotBeProbed() {
        // The synthesised initialiser decodes a string and then rejects the placeholder in
        // `init(rawValue:)`. Nothing can be learned about the type, so the caller has to
        // fall back to describing the shape in the prompt.
        #expect(throws: (any Error).self) { try JSONSchemaBuilder.schema(for: Ticket.self) }
    }

    @Test func aTypeThatRefersToItselfIsRefused() {
        #expect(throws: (any Error).self) { try JSONSchemaBuilder.schema(for: Node.self) }
    }

    @Test func dynamicKeysAreRefusedRatherThanRecordedAsAnEmptyObject() {
        #expect(throws: (any Error).self) { try JSONSchemaBuilder.schema(for: Bag.self) }
    }

    @Test func aDateBecomesTheNumberJSONDecoderExpects() throws {
        // `JSONDecoder`'s default date strategy is `deferredToDate` — seconds since 2001 as
        // a number — and `StructuredOutputHandler` decodes with a stock decoder, so the
        // schema has to ask for the same thing the decoder will accept.
        struct Event: Codable, Sendable { let name: String; let start: Date }
        let schema = try schemaObject(for: Event.self)
        guard case .object(let properties)? = schema["properties"] else {
            Issue.record("No properties")
            return
        }
        #expect(properties["start"] == .object(["type": .string("number")]))
    }

    @Test func aTopLevelArrayIsRefused() {
        // Every provider's schema mode wants an object at the root.
        #expect(throws: (any Error).self) { try JSONSchemaBuilder.schema(for: [Address].self) }
    }
}

@Suite("Structured output routing")
struct StructuredOutputPathTests {
    private static let contactJSON = """
        {"name":"Ada","age":36,"score":9.5,"active":true,"email":null,"tags":["maths"],\
        "address":{"city":"London","postcode":"NW1"},"previous":[]}
        """

    private static func provider(_ id: ProviderID) -> ScriptedProvider {
        ScriptedProvider(id: id, script: [.answerTurn(contactJSON, provider: id)])
    }

    @Test(arguments: [ProviderID.openAI, .anthropic, .gemini, .appleFoundation])
    func aProviderThatConstrainsDecodingIsSentTheSchema(id: ProviderID) async throws {
        let scripted = Self.provider(id)
        let ai = Arbiter(provider: scripted)

        let contact = try await ai.generate("Who is Ada?", as: Contact.self)

        #expect(contact.name == "Ada")
        let request = scripted.requests[0]
        guard case .structured(let schema)? = request.responseFormat else {
            Issue.record("Expected a schema-constrained request, got \(String(describing: request.responseFormat))")
            return
        }
        #expect(schema == (try JSONSchemaBuilder.schema(for: Contact.self)))
        // The prompt keeps the caller's wording: the schema does the constraining.
        #expect(request.messages.last?.content.text == "Who is Ada?")
    }

    /// Ollama gets both: its own structured-output guidance asks for the JSON instruction
    /// to stay in the prompt beside the schema, because the models it runs are small
    /// enough to need the hint.
    @Test func ollamaIsSentTheSchemaAndKeepsTheJSONInstruction() async throws {
        let scripted = Self.provider(.ollama)
        let ai = Arbiter(provider: scripted)

        let contact = try await ai.generate("Who is Ada?", as: Contact.self)

        #expect(contact.name == "Ada")
        let request = scripted.requests[0]
        guard case .structured(let schema)? = request.responseFormat else {
            Issue.record("Expected a schema-constrained request, got \(String(describing: request.responseFormat))")
            return
        }
        #expect(schema == (try JSONSchemaBuilder.schema(for: Contact.self)))

        let prompt = try #require(request.messages.last?.content.text)
        #expect(prompt.hasPrefix("Who is Ada?"))
        #expect(prompt.contains("JSON"))
    }

    /// MLX sits here rather than above because it runs an unconstrained local model and
    /// has nothing to send: the prompt is the only place the shape can be asked for.
    @Test(arguments: [ProviderID.mlx])
    func aProviderWithoutSchemaSupportIsAskedInThePrompt(id: ProviderID) async throws {
        let scripted = Self.provider(id)
        let ai = Arbiter(provider: scripted)

        let contact = try await ai.generate("Who is Ada?", as: Contact.self)

        #expect(contact.name == "Ada")
        let request = scripted.requests[0]
        #expect(request.responseFormat == .json)
        let prompt = try #require(request.messages.last?.content.text)
        #expect(prompt.hasPrefix("Who is Ada?"))
        #expect(prompt.contains("JSON"))
    }

    @Test func aTypeWhoseSchemaCannotBeDerivedTakesThePromptPathEverywhere() async throws {
        let scripted = ScriptedProvider(
            id: .openAI,
            script: [.answerTurn("{\"title\":\"Fix login\",\"priority\":\"high\"}", provider: .openAI)]
        )
        let ai = Arbiter(provider: scripted)

        let ticket = try await ai.generate("Summarise the bug", as: Ticket.self)

        #expect(ticket.priority == .high)
        #expect(scripted.requests[0].responseFormat == .json)
    }

    @Test func fallbackReshapesTheRequestForWhoeverActuallyServesIt() async throws {
        // The provider chosen first can constrain decoding; the one that picks up after it
        // fails cannot. Each has to be sent the form it understands, or the second answers
        // in prose and the decode fails.
        let failing = MockProvider(
            id: .openAI, shouldError: .networkError(underlying: URLError(.timedOut))
        )
        let fallback = ScriptedProvider(
            id: .mlx, script: [.answerTurn(Self.contactJSON, provider: .mlx)]
        )
        let ai = Arbiter {
            $0.cloud(failing)
            $0.cloud(fallback)
            $0.routing(.firstAvailable)
        }

        let contact = try await ai.generate("Who is Ada?", as: Contact.self)

        #expect(contact.name == "Ada")
        let request = fallback.requests[0]
        #expect(request.responseFormat == .json)
        #expect(try #require(request.messages.last?.content.text).contains("JSON"))
    }

    @Test func aRefusalIsReportedAsARefusalNotADecodingFailure() async throws {
        let scripted = ScriptedProvider(
            id: .openAI,
            script: [.answerTurn("I can't help with that.", provider: .openAI, finishReason: .refusal)]
        )
        let ai = Arbiter(provider: scripted)

        var thrown: (any Error)?
        do {
            _ = try await ai.generate("Who is Ada?", as: Contact.self)
        } catch {
            thrown = error
        }

        guard case .refused(let provider, let explanation)? = thrown as? ArbiterError else {
            Issue.record("Expected .refused, got \(String(describing: thrown))")
            return
        }
        #expect(provider == .openAI)
        #expect(explanation == "I can't help with that.")
    }

    @Test func theCallersSystemPromptSurvivesEitherPath() async throws {
        let native = Self.provider(.openAI)
        let prompted = Self.provider(.anthropic)
        let options = RequestOptions(systemPrompt: "You are terse.")

        _ = try await Arbiter(provider: native)
            .generate("Who is Ada?", as: Contact.self, options: options)
        _ = try await Arbiter(provider: prompted)
            .generate("Who is Ada?", as: Contact.self, options: options)

        #expect(native.requests[0].systemPrompt == "You are terse.")
        #expect(prompted.requests[0].systemPrompt == "You are terse.")
    }

    @Test func chatKeepsTheHistoryOnTheSchemaPath() async throws {
        let scripted = Self.provider(.openAI)
        let ai = Arbiter(provider: scripted)

        _ = try await ai.chat(
            [.user("Hello"), .assistant("Hi"), .user("Who is Ada?")], as: Contact.self
        )

        let request = scripted.requests[0]
        #expect(request.messages.count == 3)
        #expect(request.messages.last?.content.text == "Who is Ada?")
    }
}
