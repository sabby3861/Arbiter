// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "AppleFoundationSchema")

/// Arbiter's own vocabulary for a Foundation Models generation schema.
///
/// Mirrors what `DynamicGenerationSchema` can express, and nothing more, so the whole
/// JSON-Schema translation — the part with all the edge cases — is decided and unit
/// tested without naming a `FoundationModels` symbol. `FMBridge` turns a tree into a real
/// `GenerationSchema` at one narrow boundary, exactly as it does for transcripts.
indirect enum FMSchemaNode: Sendable, Equatable {
    /// A named object. Every object needs a name: `GenerationSchema` identifies types by
    /// name and rejects duplicates.
    case object(name: String, description: String?, properties: [Property])
    /// `string` + `enum`, which Apple models as a choice between literal strings.
    case stringEnum(name: String, description: String?, choices: [String])
    /// `anyOf`/`oneOf` over two or more subschemas.
    case anyOf(name: String, description: String?, choices: [FMSchemaNode])
    case array(item: FMSchemaNode, minimumElements: Int?, maximumElements: Int?)
    /// `$ref` to a named dependency.
    case reference(name: String)
    /// `constant` and `pattern` become `GenerationGuide<String>` guides.
    case string(constant: String?, pattern: String?)
    case integer(minimum: Int?, maximum: Int?)
    case number(minimum: Double?, maximum: Double?)
    case boolean

    struct Property: Sendable, Equatable {
        let name: String
        let description: String?
        let schema: FMSchemaNode
        /// Not in `required`, or explicitly nullable. Apple has no null type for a value,
        /// so nullability is expressed as an optional property.
        let isOptional: Bool
    }

    /// The name this node registers, when it registers one.
    var declaredName: String? {
        switch self {
        case .object(let name, _, _), .stringEnum(let name, _, _), .anyOf(let name, _, _):
            name
        case .array, .reference, .string, .integer, .number, .boolean:
            nil
        }
    }
}

/// A root schema plus the named schemas it refers to, matching
/// `GenerationSchema(root:dependencies:)`.
struct FMSchemaTree: Sendable, Equatable {
    let root: FMSchemaNode
    /// `$defs`/`definitions`, sorted by name so a schema always converts identically.
    let dependencies: [FMSchemaNode]
}

/// Translates the JSON Schema a caller supplies into `FMSchemaTree`.
///
/// Parsing is delegated to `JSONSchemaNormalizer.parseObject`, which is the shared entry
/// point every provider's schema pass starts from.
///
/// Keywords Apple's constrained decoding cannot express — `additionalProperties`,
/// `allOf`, `not`, `patternProperties`, `exclusiveMinimum`/`exclusiveMaximum`, `$schema`
/// and friends — are dropped with a `notice` rather than failing the request: the
/// generation is still constrained by everything that *can* be expressed, and refusing a
/// schema over an annotation the model would have satisfied anyway helps nobody.
/// Structural mistakes (an unresolvable `$ref`, a duplicate type name, nesting past
/// ``maximumDepth``) do fail, locally, before a session is ever built.
enum FMSchemaConverter {
    /// Nesting cap for inline subschemas, counting every level a subschema is reached
    /// through — properties, array items and combinator branches alike. Recursion through
    /// `$ref` is unbounded by design, since that is how a recursive schema is legally
    /// expressed; literal nesting past this point is a mistake rather than a shape.
    static let maximumDepth = 12

    /// Keywords silently dropped, logged once per node that carries them.
    private static let unsupportedKeywords = [
        "additionalProperties", "allOf", "not", "patternProperties", "propertyNames",
        "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "uniqueItems",
        "minLength", "maxLength", "format", "if", "then", "else", "dependentSchemas",
    ]

    // MARK: - Entry points

    /// From `ResponseFormat.structured(schema:)`.
    static func tree(fromSchemaString schema: String, rootName: String) throws -> FMSchemaTree {
        try tree(from: try JSONSchemaNormalizer.parseObject(schema), rootName: rootName)
    }

    /// From `ToolDefinition.inputSchema`, which is already parsed.
    static func tree(from value: JSONValue, rootName: String) throws -> FMSchemaTree {
        guard case .object = value, let object = value.foundationValue as? [String: Any] else {
            throw ArbiterError.invalidRequest(reason: "A tool's input schema must be a JSON object.")
        }
        return try tree(from: object, rootName: rootName)
    }

    static func tree(from object: [String: Any], rootName: String) throws -> FMSchemaTree {
        var context = Context()
        let definitions = try definitions(in: object)

        // Names are reserved before anything is converted, so a synthesised name can never
        // collide with a definition that has not been reached yet — the error would
        // otherwise depend on traversal order. The caller's definition names go first and
        // the root gives way, because the root name is Arbiter's invention: a schema whose
        // `$defs` happens to contain a "Response" is perfectly legal and every other
        // provider accepts it.
        for name in definitions.keys.sorted() { try context.reserve(sanitised(name)) }
        let root = context.reserveSynthesised(sanitised(rootName))

        var dependencies: [FMSchemaNode] = []
        for name in definitions.keys.sorted() {
            guard let body = definitions[name] as? [String: Any] else {
                throw ArbiterError.invalidRequest(reason: "Schema definition '\(name)' is not a JSON object.")
            }
            // A definition must be a *named* node: `referenceTo` resolves by name, so a
            // bare scalar definition has nothing to resolve to.
            let resolved = try node(from: body, name: sanitised(name), depth: 0, context: &context)
            dependencies.append(named(resolved.node, as: sanitised(name), context: &context))
        }

        let rootNode = try node(from: object, name: root, depth: 0, context: &context).node
        let declared = Set(dependencies.compactMap(\.declaredName))
        let unresolved = context.referenced.subtracting(declared).sorted()
        guard unresolved.isEmpty else {
            throw ArbiterError.invalidRequest(
                reason: "Response schema references undefined definitions: \(unresolved.joined(separator: ", "))"
            )
        }

        return FMSchemaTree(root: rootNode, dependencies: dependencies)
    }

    // MARK: - Conversion

    /// Names registered so far, and `$ref` targets seen, so both can be validated once the
    /// whole tree is known.
    private struct Context {
        private(set) var usedNames: Set<String> = []
        private(set) var referenced: Set<String> = []

        mutating func reserve(_ name: String) throws {
            guard usedNames.insert(name).inserted else {
                throw ArbiterError.invalidRequest(
                    reason: """
                    Response schema declares the type name '\(name)' twice. Apple's generation \
                    schemas identify types by name, so every object, enum and union needs a \
                    distinct one.
                    """
                )
            }
        }

        /// Reserves a name that was synthesised rather than written by the caller, walking
        /// to the first free suffix. A synthesised collision is an artefact of this
        /// converter's naming, not a mistake in the caller's schema, so it must not fail.
        mutating func reserveSynthesised(_ name: String) -> String {
            var candidate = name
            var counter = 2
            while usedNames.contains(candidate) {
                candidate = "\(name)\(counter)"
                counter += 1
            }
            usedNames.insert(candidate)
            return candidate
        }

        mutating func reference(_ name: String) {
            referenced.insert(name)
        }
    }

    private struct Resolved {
        let node: FMSchemaNode
        /// `null` was one of the accepted types, so a property holding this is optional.
        let isNullable: Bool
    }

    private static func node(
        from object: [String: Any],
        name: String,
        depth: Int,
        context: inout Context
    ) throws -> Resolved {
        guard depth <= maximumDepth else {
            throw ArbiterError.invalidRequest(
                reason: """
                Response schema nests more than \(maximumDepth) levels deep. Use `$defs` and \
                `$ref` for deep or recursive structures.
                """
            )
        }
        noteUnsupportedKeywords(in: object, at: name)

        let description = object["description"] as? String

        if let reference = object["$ref"] as? String {
            let target = try referenceName(reference)
            context.reference(target)
            return Resolved(node: .reference(name: target), isNullable: false)
        }

        let types = declaredTypes(in: object)
        let nullable = types.contains("null") || (object["nullable"] as? Bool == true)
        let concrete = types.filter { $0 != "null" }

        if let branches = combinatorBranches(in: object) {
            let resolved = try union(
                branches, name: name, description: description, depth: depth, context: &context
            )
            // A `nullable` sitting alongside the combinator says the same thing a null
            // branch would, so it has to survive the union rather than be read past.
            return Resolved(node: resolved.node, isNullable: resolved.isNullable || nullable)
        }

        if let choices = stringChoices(in: object) {
            // `enum` pins the value set regardless of the declared type, so it wins over it.
            return Resolved(
                node: .stringEnum(name: name, description: description, choices: choices.values),
                isNullable: nullable || choices.includesNull
            )
        }

        if let constant = object["const"] as? String {
            return Resolved(node: .string(constant: constant, pattern: nil), isNullable: nullable)
        }
        if object["const"] != nil {
            logger.notice("Dropping non-string `const` in schema node '\(name, privacy: .public)'")
        }

        if concrete.count > 1 {
            // Apple's schema has no union of primitive types; the first is kept because
            // dropping the node entirely would constrain less, not more.
            logger.notice("""
                Schema node '\(name, privacy: .public)' declares several types \
                (\(concrete.joined(separator: ", "), privacy: .public)); generating \
                \(concrete[0], privacy: .public)
                """)
        }
        let type = concrete.first ?? (object["properties"] != nil ? "object" : nil)
        switch type {
        case "object":
            return Resolved(
                node: try objectNode(
                    from: object, name: name, description: description, depth: depth, context: &context
                ),
                isNullable: nullable
            )

        case "array":
            let item = try node(
                from: try itemsSchema(of: object, at: name),
                name: context.reserveSynthesised("\(name)Item"),
                depth: depth + 1,
                context: &context
            )
            if item.isNullable {
                // Apple's arrays have no per-element optionality: an element either matches
                // the item schema or the generation is invalid.
                logger.notice("Dropping element nullability in array '\(name, privacy: .public)'")
            }
            return Resolved(
                node: .array(
                    item: item.node,
                    minimumElements: intValue(object["minItems"]),
                    maximumElements: intValue(object["maxItems"])
                ),
                isNullable: nullable
            )

        case "integer":
            return Resolved(
                node: .integer(minimum: intValue(object["minimum"]), maximum: intValue(object["maximum"])),
                isNullable: nullable
            )

        case "number":
            return Resolved(
                node: .number(
                    minimum: doubleValue(object["minimum"]), maximum: doubleValue(object["maximum"])
                ),
                isNullable: nullable
            )

        case "boolean":
            return Resolved(node: .boolean, isNullable: nullable)

        case "string":
            return Resolved(
                node: .string(constant: nil, pattern: compilablePattern(in: object, at: name)),
                isNullable: nullable
            )

        default:
            // No usable type: `{}`, an annotation-only node, or a type this converter does
            // not model. A string is the least constrained thing Apple can generate, so the
            // model is left free rather than boxed into a shape the caller never asked for.
            if type != nil {
                logger.notice("Unsupported schema type '\(type ?? "", privacy: .public)'; generating a string")
            }
            return Resolved(node: .string(constant: nil, pattern: nil), isNullable: nullable)
        }
    }

    private static func objectNode(
        from object: [String: Any],
        name: String,
        description: String?,
        depth: Int,
        context: inout Context
    ) throws -> FMSchemaNode {
        let properties = object["properties"] as? [String: Any] ?? [:]
        let required = Set(object["required"] as? [String] ?? [])

        // Sorted because `JSONSerialization` does not preserve key order: without this the
        // same schema string would produce different property orders between runs, and the
        // schema is part of what the model is shown.
        var converted: [FMSchemaNode.Property] = []
        for key in properties.keys.sorted() {
            let body = try subschema(properties[key], at: "\(name).\(key)")
            let child = try node(
                from: body,
                name: context.reserveSynthesised("\(name)\(capitalised(key))"),
                depth: depth + 1,
                context: &context
            )
            converted.append(FMSchemaNode.Property(
                name: key,
                description: body["description"] as? String,
                schema: child.node,
                isOptional: !required.contains(key) || child.isNullable
            ))
        }
        return .object(name: name, description: description, properties: converted)
    }

    /// `anyOf`/`oneOf`. A `null` branch is the standard way to write "optional", so it is
    /// lifted into nullability rather than becoming a branch Apple cannot represent.
    private static func union(
        _ branches: [[String: Any]],
        name: String,
        description: String?,
        depth: Int,
        context: inout Context
    ) throws -> Resolved {
        var nullable = false
        var alternatives: [[String: Any]] = []
        for branch in branches {
            if declaredTypes(in: branch) == ["null"] {
                nullable = true
            } else {
                alternatives.append(branch)
            }
        }

        guard let first = alternatives.first else {
            throw ArbiterError.invalidRequest(
                reason: "Schema node '\(name)' has no branch other than null in its anyOf/oneOf."
            )
        }
        guard alternatives.count > 1 else {
            // A single surviving branch is the `["X", null]` idiom: the union adds nothing,
            // so the branch takes the union's name and the nullability travels upward. It
            // still costs a level: a chain of single-branch unions is nesting like any
            // other, and leaving depth alone would let it recurse without bound.
            let only = try node(from: first, name: name, depth: depth + 1, context: &context)
            return Resolved(node: only.node, isNullable: nullable || only.isNullable)
        }

        var choices: [FMSchemaNode] = []
        for (index, branch) in alternatives.enumerated() {
            let resolved = try node(
                from: branch,
                name: context.reserveSynthesised("\(name)Choice\(index + 1)"),
                depth: depth + 1,
                context: &context
            )
            nullable = nullable || resolved.isNullable
            choices.append(resolved.node)
        }
        return Resolved(
            node: .anyOf(name: name, description: description, choices: choices),
            isNullable: nullable
        )
    }

    /// Gives a `$defs` entry the name it is referenced by.
    ///
    /// A definition that converts to an unnamed node (a bare `{"type": "string"}`) is
    /// wrapped in a single-branch union, which is the only named container that adds no
    /// structure of its own — `referenceTo(name:)` has nothing to resolve otherwise.
    private static func named(
        _ node: FMSchemaNode,
        as name: String,
        context: inout Context
    ) -> FMSchemaNode {
        switch node {
        case .object(_, let description, let properties):
            .object(name: name, description: description, properties: properties)
        case .stringEnum(_, let description, let choices):
            .stringEnum(name: name, description: description, choices: choices)
        case .anyOf(_, let description, let choices):
            .anyOf(name: name, description: description, choices: choices)
        case .array, .reference, .string, .integer, .number, .boolean:
            .anyOf(name: name, description: nil, choices: [node])
        }
    }

    // MARK: - Reading JSON Schema

    /// `items` is normally one subschema. The tuple form (an array of subschemas, from
    /// draft-07) has no counterpart in Apple's arrays, so the first entry is used and the
    /// rest are reported rather than silently governing nothing.
    private static func itemsSchema(of object: [String: Any], at name: String) throws -> [String: Any] {
        guard let items = object["items"] else { return [:] }
        if let tuple = items as? [Any] {
            logger.notice("""
                Array '\(name, privacy: .public)' uses tuple-form items; constraining every \
                element to the first entry
                """)
            return try subschema(tuple.first, at: name)
        }
        return try subschema(items, at: name)
    }

    /// Reads a subschema, accepting JSON Schema 2020-12's boolean form: `true` admits
    /// anything, `false` admits nothing.
    private static func subschema(_ value: Any?, at name: String) throws -> [String: Any] {
        switch value {
        case let object as [String: Any]:
            return object
        case let always as Bool where always:
            return [:]
        case is Bool:
            throw ArbiterError.invalidRequest(
                reason: """
                Schema node '\(name)' is `false`, which nothing can satisfy, so no response \
                could ever be generated for it.
                """
            )
        case .none:
            return [:]
        default:
            throw ArbiterError.invalidRequest(
                reason: "Schema node '\(name)' is not a JSON object."
            )
        }
    }

    private static func definitions(in object: [String: Any]) throws -> [String: Any] {
        var merged: [String: Any] = [:]
        for key in ["$defs", "definitions"] {
            guard let defs = object[key] as? [String: Any] else { continue }
            for (name, body) in defs {
                guard merged[name] == nil else {
                    throw ArbiterError.invalidRequest(
                        reason: "Response schema defines '\(name)' in both $defs and definitions."
                    )
                }
                merged[name] = body
            }
        }
        return merged
    }

    /// Only local definition references are resolvable: Apple's dependencies are a flat,
    /// name-keyed list, so a pointer into a document or another file has no counterpart.
    private static func referenceName(_ reference: String) throws -> String {
        for prefix in ["#/$defs/", "#/definitions/"] where reference.hasPrefix(prefix) {
            let name = String(reference.dropFirst(prefix.count))
            guard !name.isEmpty, !name.contains("/") else { break }
            return sanitised(name)
        }
        throw ArbiterError.invalidRequest(
            reason: """
            Unsupported schema reference '\(reference)'. Apple Foundation Models resolves only \
            local definitions, written as '#/$defs/Name'.
            """
        )
    }

    private static func combinatorBranches(in object: [String: Any]) -> [[String: Any]]? {
        for key in ["anyOf", "oneOf"] {
            guard let branches = object[key] as? [Any] else { continue }
            let objects = branches.compactMap { $0 as? [String: Any] }
            guard !objects.isEmpty else { continue }
            return objects
        }
        return nil
    }

    private static func declaredTypes(in object: [String: Any]) -> [String] {
        if let type = object["type"] as? String { return [type] }
        if let types = object["type"] as? [String] { return types }
        return []
    }

    /// `enum` is usable only when every non-null value is a string — Apple's choice list is
    /// `[String]`.
    private static func stringChoices(in object: [String: Any]) -> (values: [String], includesNull: Bool)? {
        guard let values = object["enum"] as? [Any], !values.isEmpty else { return nil }
        let includesNull = values.contains { $0 is NSNull }
        let strings = values.compactMap { $0 as? String }
        guard strings.count == values.count - (includesNull ? 1 : 0), !strings.isEmpty else {
            logger.notice("Dropping non-string `enum`; the values cannot be expressed as choices")
            return nil
        }
        return (strings, includesNull)
    }

    /// A `pattern` that this platform's regex engine will not accept is dropped rather than
    /// failing the request: the pattern is one constraint among several, and the alternative
    /// is rejecting a schema the model could still have been usefully guided by.
    private static func compilablePattern(in object: [String: Any], at name: String) -> String? {
        guard let pattern = object["pattern"] as? String else { return nil }
        guard (try? Regex(pattern)) != nil else {
            logger.notice("Dropping uncompilable pattern in schema node '\(name, privacy: .public)'")
            return nil
        }
        return pattern
    }

    private static func noteUnsupportedKeywords(in object: [String: Any], at name: String) {
        let present = unsupportedKeywords.filter { object[$0] != nil }
        guard !present.isEmpty else { return }
        logger.notice("""
            Dropping unsupported schema keywords in '\(name, privacy: .public)': \
            \(present.joined(separator: ", "), privacy: .public)
            """)
    }

    /// JSON booleans bridge to `NSNumber`, so `true` would otherwise read as the bound `1`.
    /// A magnitude outside `Int` is dropped rather than saturated: `NSNumber.intValue`
    /// clamps `1e30` to `Int.max`, which Apple would then enforce as an unsatisfiable
    /// minimum.
    private static func intValue(_ value: Any?) -> Int? {
        guard let number = numberValue(value) else { return nil }
        let double = number.doubleValue
        guard double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        numberValue(value)?.doubleValue
    }

    private static func numberValue(_ value: Any?) -> NSNumber? {
        guard let value else { return nil }
        let object = value as AnyObject
        guard object !== kCFBooleanTrue, object !== kCFBooleanFalse else { return nil }
        return value as? NSNumber
    }

    /// Type names reach the model, and Apple's schema names are identifiers rather than
    /// arbitrary text, so anything else is folded to an underscore.
    static func sanitised(_ name: String) -> String {
        var result = ""
        for character in name {
            result.append(character.isLetter || character.isNumber || character == "_" ? character : "_")
        }
        if result.isEmpty { result = "Schema" }
        if let first = result.first, first.isNumber { result = "_" + result }
        return result
    }

    private static func capitalised(_ name: String) -> String {
        let sanitised = sanitised(name)
        guard let first = sanitised.first else { return sanitised }
        return first.uppercased() + sanitised.dropFirst()
    }
}
