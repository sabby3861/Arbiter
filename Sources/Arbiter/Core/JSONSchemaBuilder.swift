// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Which providers can constrain decoding to a JSON Schema.
///
/// A request sent as ``ResponseFormat/structured(schema:)`` to a provider outside this set
/// is not refused — it is silently answered without the constraint, and the caller gets
/// prose where they asked for JSON. So the runtime asks this before choosing the schema
/// path over the prompt path, per candidate provider rather than once per request, because
/// fallback can move a request from one to the other mid-flight.
enum NativeStructuredOutput {
    /// OpenAI compiles the schema into strict structured outputs, Anthropic into
    /// `output_config.format`, Gemini into `generationConfig.responseFormat.text.schema`,
    /// Ollama into `format` as a schema object, and Apple Foundation Models into a
    /// `GenerationSchema` that drives constrained decoding on device.
    ///
    /// MLX is the one absentee, and it is absent because of the runtime rather than the
    /// mapper: it runs an unconstrained local model and has nothing to send, so the prompt
    /// path is the only one that works there.
    static let providers: Set<ProviderID> = [
        .openAI, .anthropic, .gemini, .ollama, .appleFoundation,
    ]

    /// Providers that want the JSON instruction left in the prompt even though a
    /// schema is being sent.
    ///
    /// The schema constrains decoding, so for the cloud models the prompt is
    /// free to keep the caller's own wording. Ollama's structured-output
    /// guidance asks for both — "Add 'return as JSON' to the prompt to help the
    /// model understand the request" — and it runs small local models where that
    /// help counts for more. Verified 3 September 2026 against
    /// https://ollama.com/blog/structured-outputs.
    static let providersWantingInstructedPrompt: Set<ProviderID> = [.ollama]

    static func supports(_ provider: ProviderID) -> Bool {
        providers.contains(provider)
    }

    static func wantsInstructedPrompt(_ provider: ProviderID) -> Bool {
        providersWantingInstructedPrompt.contains(provider)
    }
}

/// Derives a JSON Schema from a `Decodable` Swift type.
///
/// There is no way to reflect a type in Swift without an instance of it, so the type is
/// asked to decode itself from a decoder that answers every request with a placeholder and
/// records what was asked for. Property names, their types, which are optional, array
/// element types and nested objects all fall out of that.
///
/// What it cannot do is the reason every caller must have a fallback: a type whose
/// `init(from:)` validates its input rejects the placeholder and the probe fails. The
/// common case is an enum — the synthesised initialiser decodes a string and then fails
/// `init(rawValue:)` — so any type containing one throws here. Dictionaries with dynamic
/// keys and self-referencing types are refused for the same reason: the shape recorded
/// would not be the shape the type really has. ``StructuredOutputHandler``'s prompt path
/// handles all of them.
///
/// Placeholders match what `JSONDecoder` will accept when the answer comes back, not what
/// reads best: a `Date` asks for a *number*, because the decoder's default strategy is
/// `deferredToDate`. Models are poor at seconds-since-2001, so a type with a date is often
/// better served by the prompt path with an `example`.
enum JSONSchemaBuilder {
    /// The schema for `type`, as the JSON text ``ResponseFormat/structured(schema:)`` carries.
    ///
    /// - Throws: ``SchemaProbeError`` when the type's shape cannot be established.
    static func schema<T: Decodable>(for type: T.Type) throws -> String {
        let root = SchemaNode()
        let state = ProbeState()
        _ = try SchemaProbe.value(of: type, into: root, state: state, codingPath: [])
        guard root.kind == .object else {
            throw SchemaProbeError.unsupported(
                "\(type) is not a JSON object at the top level; providers require one"
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(try root.jsonValue())
        return String(decoding: data, as: UTF8.self)
    }
}

/// Why a type's schema could not be derived.
enum SchemaProbeError: Error, Equatable {
    case unsupported(String)

    var reason: String {
        switch self {
        case .unsupported(let detail): detail
        }
    }
}

// MARK: - The recorded shape

/// A node of the schema being recorded, shared by reference with the decoder that fills it.
final class SchemaNode {
    enum Kind {
        case unknown, object, array, string, number, integer, boolean
    }

    var kind: Kind = .unknown
    /// Set when something asked this node for the keys it holds — see
    /// `SchemaProbeKeyedContainer.allKeys`.
    var sawDynamicKeys = false
    /// In declaration order, as the type asked for them.
    private(set) var propertyOrder: [String] = []
    private var properties: [String: SchemaNode] = [:]
    private var required: Set<String> = []
    var items: SchemaNode?

    func property(_ name: String, required isRequired: Bool) -> SchemaNode {
        let node: SchemaNode
        if let existing = properties[name] {
            node = existing
        } else {
            node = SchemaNode()
            properties[name] = node
            propertyOrder.append(name)
        }
        if isRequired { required.insert(name) }
        return node
    }

    func element() -> SchemaNode {
        if let items { return items }
        let node = SchemaNode()
        items = node
        return node
    }

    func jsonValue() throws -> JSONValue {
        switch kind {
        case .string: return .object(["type": .string("string")])
        case .number: return .object(["type": .string("number")])
        case .integer: return .object(["type": .string("integer")])
        case .boolean: return .object(["type": .string("boolean")])
        case .array:
            guard let items else {
                throw SchemaProbeError.unsupported("an array whose element type never decoded")
            }
            return .object(["type": .string("array"), "items": try items.jsonValue()])
        case .object:
            guard !sawDynamicKeys else {
                throw SchemaProbeError.unsupported(
                    "an object with dynamic keys, such as a dictionary"
                )
            }
            var fields: [String: JSONValue] = [:]
            for name in propertyOrder {
                fields[name] = try properties[name]?.jsonValue() ?? .object([:])
            }
            return .object([
                "type": .string("object"),
                "properties": .object(fields),
                // Sorted so the same type always produces byte-identical schema text,
                // which keeps request bodies comparable and cacheable.
                "required": .array(required.sorted().map { .string($0) }),
                "additionalProperties": .bool(false),
            ])
        case .unknown:
            throw SchemaProbeError.unsupported("a value whose type could not be determined")
        }
    }
}

/// Guards against a probe that would not terminate.
final class ProbeState {
    static let maxDepth = 16
    var typeStack: [String] = []

    func enter<T>(_ type: T.Type) throws {
        let name = String(reflecting: type)
        guard !typeStack.contains(name) else {
            throw SchemaProbeError.unsupported("\(type) refers to itself")
        }
        guard typeStack.count < Self.maxDepth else {
            throw SchemaProbeError.unsupported("nesting deeper than \(Self.maxDepth) levels")
        }
        typeStack.append(name)
    }

    func leave() {
        typeStack.removeLast()
    }
}
