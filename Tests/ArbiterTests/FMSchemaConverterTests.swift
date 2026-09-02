// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

/// Unguarded on purpose: the converter names no `FoundationModels` symbol, so every
/// translation rule and rejection is exercised on any platform — including the ones where
/// Apple Intelligence cannot run.
@Suite("FMSchemaConverter")
struct FMSchemaConverterTests {

    private func tree(_ json: String, root: String = "Response") throws -> FMSchemaTree {
        try FMSchemaConverter.tree(fromSchemaString: json, rootName: root)
    }

    private func rootProperties(_ node: FMSchemaNode) throws -> [FMSchemaNode.Property] {
        guard case .object(_, _, let properties) = node else {
            Issue.record("Expected an object root, got \(node)")
            throw CancellationError()
        }
        return properties
    }

    // MARK: - Objects and properties

    @Test func objectPropertiesAreConvertedAndOptionalityFollowsRequired() throws {
        let tree = try tree("""
        {
          "type": "object",
          "description": "A person",
          "properties": {
            "name": {"type": "string", "description": "Full name"},
            "nickname": {"type": "string"}
          },
          "required": ["name"]
        }
        """)

        guard case .object(let name, let description, let properties) = tree.root else {
            Issue.record("Expected an object root")
            return
        }
        #expect(name == "Response")
        #expect(description == "A person")
        // Sorted by key: JSON objects have no order, so the converter imposes one.
        #expect(properties.map(\.name) == ["name", "nickname"])
        #expect(properties[0].isOptional == false)
        #expect(properties[0].description == "Full name")
        #expect(properties[1].isOptional)
        #expect(tree.dependencies.isEmpty)
    }

    @Test func propertiesWithoutATypeButWithNestedPropertiesAreObjects() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"address": {"properties": {"city": {"type": "string"}}}}}
        """)
        let properties = try rootProperties(tree.root)
        guard case .object(let name, _, let nested) = properties[0].schema else {
            Issue.record("Expected a nested object, got \(properties[0].schema)")
            return
        }
        // Nested objects need names of their own; they are synthesised from the path so the
        // same schema always produces the same names.
        #expect(name == "ResponseAddress")
        #expect(nested.map(\.name) == ["city"])
    }

    // MARK: - Scalars and guides

    @Test func stringEnumBecomesAChoiceList() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"size": {"type": "string", "enum": ["small", "large"]}},
         "required": ["size"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].schema == .stringEnum(name: "ResponseSize", description: nil, choices: ["small", "large"]))
    }

    @Test func nonStringEnumIsDroppedAndTheBaseTypeSurvives() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"count": {"type": "integer", "enum": [1, 2, 3]}},
         "required": ["count"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].schema == .integer(minimum: nil, maximum: nil))
    }

    @Test func stringConstBecomesAConstantGuide() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"kind": {"const": "invoice"}}, "required": ["kind"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].schema == .string(constant: "invoice", pattern: nil))
    }

    @Test func stringPatternIsCarried() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"code": {"type": "string", "pattern": "^[A-Z]{3}$"}},
         "required": ["code"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].schema == .string(constant: nil, pattern: "^[A-Z]{3}$"))
    }

    /// A pattern the engine will not accept must not fail the request: it is one constraint
    /// among several, and the generation is still shaped by the rest.
    @Test func uncompilablePatternIsDroppedRatherThanThrowing() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"code": {"type": "string", "pattern": "[unterminated"}},
         "required": ["code"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].schema == .string(constant: nil, pattern: nil))
    }

    @Test func numericBoundsAreCarriedPerType() throws {
        let tree = try tree("""
        {"type": "object",
         "properties": {
           "age": {"type": "integer", "minimum": 0, "maximum": 120},
           "score": {"type": "number", "minimum": 0.5},
           "active": {"type": "boolean"}
         },
         "required": ["age", "score", "active"]}
        """)
        let properties = try rootProperties(tree.root)
        // Sorted by name: active, age, score.
        #expect(properties[0].schema == .boolean)
        #expect(properties[1].schema == .integer(minimum: 0, maximum: 120))
        #expect(properties[2].schema == .number(minimum: 0.5, maximum: nil))
    }

    @Test func arraysCarryTheirItemSchemaAndCountBounds() throws {
        let tree = try tree("""
        {"type": "object",
         "properties": {"tags": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 5}},
         "required": ["tags"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].schema == .array(
            item: .string(constant: nil, pattern: nil), minimumElements: 1, maximumElements: 5
        ))
    }

    @Test func aTypelessNodeGeneratesAString() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"anything": {}}, "required": ["anything"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].schema == .string(constant: nil, pattern: nil))
    }

    // MARK: - Nullability

    @Test func aNullableTypeArrayMakesThePropertyOptional() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"note": {"type": ["string", "null"]}}, "required": ["note"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].isOptional)
        #expect(properties[0].schema == .string(constant: nil, pattern: nil))
    }

    @Test func aNullBranchInAnyOfCollapsesIntoOptionality() throws {
        let tree = try tree("""
        {"type": "object",
         "properties": {"note": {"anyOf": [{"type": "string"}, {"type": "null"}]}},
         "required": ["note"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].isOptional)
        // The union added nothing, so it does not survive as one.
        #expect(properties[0].schema == .string(constant: nil, pattern: nil))
    }

    @Test func nullableKeywordMakesThePropertyOptional() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"note": {"type": "string", "nullable": true}},
         "required": ["note"]}
        """)
        #expect(try rootProperties(tree.root)[0].isOptional)
    }

    // MARK: - Unions

    @Test func anyOfOfObjectsBecomesANamedUnion() throws {
        let tree = try tree("""
        {"type": "object",
         "properties": {
           "payment": {"anyOf": [
             {"type": "object", "properties": {"card": {"type": "string"}}},
             {"type": "object", "properties": {"iban": {"type": "string"}}}
           ]}
         },
         "required": ["payment"]}
        """)
        let properties = try rootProperties(tree.root)
        guard case .anyOf(let name, _, let choices) = properties[0].schema else {
            Issue.record("Expected a union, got \(properties[0].schema)")
            return
        }
        #expect(name == "ResponsePayment")
        #expect(choices.compactMap(\.declaredName) == ["ResponsePaymentChoice1", "ResponsePaymentChoice2"])
    }

    @Test func aUnionWithOnlyNullBranchesIsRejected() {
        #expect(throws: ArbiterError.self) {
            _ = try tree("""
            {"type": "object", "properties": {"x": {"anyOf": [{"type": "null"}]}}}
            """)
        }
    }

    // MARK: - Definitions and references

    @Test func defsBecomeDependenciesAndRefsBecomeReferences() throws {
        let tree = try tree("""
        {"type": "object",
         "$defs": {"Address": {"type": "object", "properties": {"city": {"type": "string"}}}},
         "properties": {"home": {"$ref": "#/$defs/Address"}},
         "required": ["home"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].schema == .reference(name: "Address"))
        #expect(tree.dependencies.compactMap(\.declaredName) == ["Address"])
    }

    /// The whole point of emitting dependencies: a type that contains itself is legal, and
    /// must not send the converter into infinite recursion.
    @Test func aRecursiveDefinitionConvertsWithoutRecursingForever() throws {
        let tree = try tree("""
        {"$ref": "#/$defs/Node",
         "$defs": {"Node": {"type": "object",
           "properties": {"child": {"$ref": "#/$defs/Node"}}}}}
        """)
        #expect(tree.root == .reference(name: "Node"))
        guard case .object(_, _, let properties)? = tree.dependencies.first else {
            Issue.record("Expected the Node dependency")
            return
        }
        #expect(properties[0].schema == .reference(name: "Node"))
    }

    @Test func aScalarDefinitionIsWrappedSoItHasANameToResolveTo() throws {
        let tree = try tree("""
        {"type": "object",
         "$defs": {"Code": {"type": "string"}},
         "properties": {"code": {"$ref": "#/$defs/Code"}}}
        """)
        #expect(tree.dependencies == [.anyOf(
            name: "Code", description: nil, choices: [.string(constant: nil, pattern: nil)]
        )])
    }

    @Test func legacyDefinitionsKeywordIsAccepted() throws {
        let tree = try tree("""
        {"type": "object",
         "definitions": {"Address": {"type": "object", "properties": {"city": {"type": "string"}}}},
         "properties": {"home": {"$ref": "#/definitions/Address"}}}
        """)
        #expect(tree.dependencies.compactMap(\.declaredName) == ["Address"])
    }

    @Test func anUnresolvedReferenceIsRejected() {
        #expect(throws: ArbiterError.self) {
            _ = try tree("""
            {"type": "object", "properties": {"home": {"$ref": "#/$defs/Missing"}}}
            """)
        }
    }

    @Test func aRemoteReferenceIsRejected() {
        #expect(throws: ArbiterError.self) {
            _ = try tree("""
            {"type": "object", "properties": {"home": {"$ref": "https://example.com/address.json"}}}
            """)
        }
    }

    /// "Response" is Arbiter's name for the root, not the caller's, so a schema that happens
    /// to define a type by that name — legal, and accepted by every other provider — must
    /// convert rather than be blamed for a collision it did not cause.
    @Test func aDefinitionMayUseTheNameArbiterWouldHaveGivenTheRoot() throws {
        let tree = try tree("""
        {"type": "object", "$defs": {"Response": {"type": "object", "properties": {}}},
         "properties": {"x": {"$ref": "#/$defs/Response"}}, "required": ["x"]}
        """)

        // The caller's definition keeps the name; the root is the one that moves.
        #expect(tree.dependencies.compactMap(\.declaredName) == ["Response"])
        #expect(tree.root.declaredName == "Response2")
        #expect(try rootProperties(tree.root)[0].schema == .reference(name: "Response"))
    }

    /// A collision between two *synthesised* names is this converter's own doing, so it
    /// disambiguates rather than blaming the caller's schema. `a.b` and `aB` both synthesise
    /// "ResponseAB", one nested a level below the other.
    @Test func synthesisedNameCollisionsAreDisambiguated() throws {
        let tree = try tree("""
        {"type": "object",
         "properties": {
           "a": {"type": "object", "properties": {"b": {"type": "object", "properties": {}}}},
           "aB": {"type": "object", "properties": {}}
         },
         "required": ["a", "aB"]}
        """)

        let properties = try rootProperties(tree.root)
        let nested = try rootProperties(properties[0].schema)
        let names = [properties[0].schema, properties[1].schema, nested[0].schema]
            .compactMap(\.declaredName)
        #expect(names == ["ResponseA", "ResponseAB2", "ResponseAB"])
    }

    // MARK: - Structural limits

    @Test func nestingPastTheDepthCapIsRejected() {
        var schema = #"{"type": "string"}"#
        for _ in 0...FMSchemaConverter.maximumDepth {
            schema = #"{"type": "object", "properties": {"next": \#(schema)}}"#
        }
        #expect(throws: ArbiterError.self) { _ = try tree(schema) }
    }

    @Test func unsupportedKeywordsAreDroppedRatherThanRejected() throws {
        let tree = try tree("""
        {"$schema": "https://json-schema.org/draft/2020-12/schema",
         "type": "object",
         "additionalProperties": false,
         "properties": {"name": {"type": "string", "minLength": 2, "format": "email"}},
         "required": ["name"]}
        """)
        let properties = try rootProperties(tree.root)
        #expect(properties[0].schema == .string(constant: nil, pattern: nil))
    }

    @Test func nullableSurvivesAlongsideACombinator() throws {
        let tree = try tree("""
        {"type": "object",
         "properties": {"payment": {
            "nullable": true,
            "anyOf": [
              {"type": "object", "properties": {"card": {"type": "string"}}},
              {"type": "object", "properties": {"iban": {"type": "string"}}}
            ]}},
         "required": ["payment"]}
        """)
        #expect(try rootProperties(tree.root)[0].isOptional)
    }

    /// A chain of single-branch unions is nesting, and used to cost nothing — so the depth
    /// cap could be walked straight past.
    @Test func singleBranchUnionsCountTowardsTheDepthCap() {
        var schema = #"{"type": "string"}"#
        for _ in 0...FMSchemaConverter.maximumDepth {
            schema = #"{"anyOf": [\#(schema), {"type": "null"}]}"#
        }
        #expect(throws: ArbiterError.self) { _ = try tree(schema) }
    }

    /// JSON booleans bridge to `NSNumber`, so an unfixed reader turns `true` into the
    /// bound `1` and silently constrains a value the caller never bounded.
    @Test func booleanBoundsAreNotReadAsNumbers() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"age": {"type": "integer", "minimum": true, "maximum": false}},
         "required": ["age"]}
        """)
        #expect(try rootProperties(tree.root)[0].schema == .integer(minimum: nil, maximum: nil))
    }

    /// `intValue` saturates, which would turn an out-of-range bound into `Int.max` — a
    /// minimum no generation could ever satisfy.
    @Test func boundsOutsideIntAreDroppedRatherThanSaturated() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"n": {"type": "integer", "minimum": 1e30}}, "required": ["n"]}
        """)
        #expect(try rootProperties(tree.root)[0].schema == .integer(minimum: nil, maximum: nil))
    }

    /// `true` and `false` are legal subschemas in 2020-12: one admits anything, the other
    /// admits nothing — and nothing is not something a generation can satisfy.
    @Test func booleanSubschemasAreUnderstood() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"anything": true}, "required": ["anything"]}
        """)
        #expect(try rootProperties(tree.root)[0].schema == .string(constant: nil, pattern: nil))

        #expect(throws: ArbiterError.self) {
            _ = try self.tree(#"{"type": "object", "properties": {"nothing": false}}"#)
        }
    }

    @Test func tupleFormArrayItemsConstrainEveryElementToTheFirstEntry() throws {
        let tree = try tree("""
        {"type": "object",
         "properties": {"pair": {"type": "array", "items": [{"type": "integer"}, {"type": "string"}]}},
         "required": ["pair"]}
        """)
        #expect(try rootProperties(tree.root)[0].schema
                == .array(item: .integer(minimum: nil, maximum: nil), minimumElements: nil, maximumElements: nil))
    }

    @Test func aMultiTypeNodeKeepsTheFirstType() throws {
        let tree = try tree("""
        {"type": "object", "properties": {"x": {"type": ["string", "integer"]}}, "required": ["x"]}
        """)
        #expect(try rootProperties(tree.root)[0].schema == .string(constant: nil, pattern: nil))
    }

    @Test func aNonObjectSchemaStringIsRejected() {
        #expect(throws: ArbiterError.self) {
            _ = try tree("[1, 2, 3]")
        }
    }

    // MARK: - JSONValue entry point (tool parameters)

    @Test func toolInputSchemaConvertsThroughTheJSONValueEntryPoint() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["city": ["type": "string"], "days": ["type": "integer", "maximum": 7]],
            "required": ["city"],
        ]
        let tree = try FMSchemaConverter.tree(from: schema, rootName: "get_weatherArguments")

        guard case .object(let name, _, let properties) = tree.root else {
            Issue.record("Expected an object root")
            return
        }
        #expect(name == "get_weatherArguments")
        #expect(properties.map(\.name) == ["city", "days"])
        #expect(properties[0].isOptional == false)
        #expect(properties[1].isOptional)
        #expect(properties[1].schema == .integer(minimum: nil, maximum: 7))
    }

    @Test func aToolSchemaThatIsNotAnObjectIsRejected() {
        #expect(throws: ArbiterError.self) {
            _ = try FMSchemaConverter.tree(from: .array([.string("x")]), rootName: "Arguments")
        }
    }

    /// Type names reach the model and Apple's are identifiers, so punctuation cannot survive.
    @Test func namesAreSanitisedIntoIdentifiers() throws {
        let tree = try tree(#"{"type": "object", "properties": {"first name": {"type": "object", "properties": {}}}}"#)
        #expect(try rootProperties(tree.root)[0].schema.declaredName == "ResponseFirst_name")
        #expect(FMSchemaConverter.sanitised("9lives") == "_9lives")
    }
}
