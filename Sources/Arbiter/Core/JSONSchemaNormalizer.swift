// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Reshapes a caller's JSON Schema into the dialect a provider will accept.
///
/// `ResponseFormat.structured(schema:)` carries a schema as a string, because
/// that is what a caller can paste. Providers want a parsed object in their own
/// restricted subset of JSON Schema, and each subset differs — so parsing lives
/// here once and each provider applies its own pass on top.
///
/// Shared between providers on purpose: OpenAI strict mode and Gemini's
/// OpenAPI subset both start from the same parse step.
enum JSONSchemaNormalizer {
    /// Parse a schema string into a JSON object.
    ///
    /// - Throws: `ArbiterError.invalidRequest` when the string is not a JSON
    ///   object. Providers reject anything else outright, so failing here turns
    ///   a guaranteed HTTP 400 into a local error the caller can act on.
    static func parseObject(_ schema: String) throws -> [String: Any] {
        guard let data = schema.data(using: .utf8) else {
            throw ArbiterError.invalidRequest(reason: "Response schema is not valid UTF-8")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ArbiterError.invalidRequest(
                reason: "Response schema is not valid JSON: \(error.localizedDescription)"
            )
        }
        guard let object = parsed as? [String: Any] else {
            throw ArbiterError.invalidRequest(reason: "Response schema must be a JSON object")
        }
        return object
    }

    /// Rewrite a schema to satisfy OpenAI's structured-output strict mode.
    ///
    /// Strict mode requires every object to set `additionalProperties: false`
    /// and to list *all* of its properties in `required`. A property the caller
    /// left optional therefore cannot simply be dropped from `required`; the
    /// documented way to keep it optional is to widen its type to include
    /// `null`. That is what this does, so an optional field arrives as an
    /// explicit `null` rather than being absent.
    ///
    /// Rewriting is applied recursively through `properties`, `items`,
    /// `$defs`/`definitions` and the `anyOf`/`oneOf` combinators. `allOf` is
    /// left untouched — see the note at the recursion. Keywords the schema
    /// already sets are preserved.
    static func openAIStrict(_ schema: [String: Any]) -> [String: Any] {
        strictified(schema) as? [String: Any] ?? schema
    }

    private static func strictified(_ node: Any) -> Any {
        guard var object = node as? [String: Any] else {
            // An array node is a combinator's branch list; a scalar is a
            // constraint value like `"string"` or `3`. Only the former holds
            // subschemas worth descending into.
            if let array = node as? [Any] {
                return array.map { strictified($0) }
            }
            return node
        }

        for key in ["$defs", "definitions"] {
            if let defs = object[key] as? [String: Any] {
                object[key] = defs.mapValues { strictified($0) }
            }
        }
        // `anyOf`/`oneOf` branches are standalone alternatives, so closing each
        // one is correct. `allOf` is deliberately left alone: its branches are
        // merged, and giving each `additionalProperties: false` would forbid
        // the properties contributed by its siblings, making a valid schema
        // unsatisfiable. OpenAI's published subset does not commit to
        // supporting `allOf`, so passing it through unchanged is the option
        // that cannot silently change what the caller asked for.
        for key in ["anyOf", "oneOf"] {
            if let branches = object[key] as? [Any] {
                object[key] = branches.map { strictified($0) }
            }
        }
        if let items = object["items"] {
            object["items"] = strictified(items)
        }
        if let prefixItems = object["prefixItems"] as? [Any] {
            object["prefixItems"] = prefixItems.map { strictified($0) }
        }

        guard var properties = object["properties"] as? [String: Any] else {
            // An object with no `properties` key still has to be closed, or
            // strict mode rejects it. An explicit schema-valued
            // `additionalProperties` (a map type) is left alone: strict mode
            // cannot express it, and rewriting it to `false` would silently
            // turn a map into an empty object. Letting the API reject it says
            // more than quietly changing what was asked for.
            if isObjectTyped(object), object["additionalProperties"] == nil {
                object["additionalProperties"] = false
                object["properties"] = [String: Any]()
                object["required"] = [String]()
            }
            return object
        }

        // Only the properties the caller listed stay non-nullable; every other
        // one becomes nullable so that requiring all of them changes nothing
        // about which values are legal.
        let originallyRequired = Set(object["required"] as? [String] ?? [])
        for (name, subschema) in properties {
            let descended = strictified(subschema)
            properties[name] = originallyRequired.contains(name)
                ? descended
                : nullable(descended)
        }

        object["properties"] = properties
        // Every property is required, plus any name the caller required that
        // this node does not itself declare — an `allOf` sibling may contribute
        // it, and dropping it would loosen the schema.
        //
        // Sorted so the emitted schema is stable across runs, which keeps
        // request bodies comparable in tests and cacheable by prefix.
        object["required"] = Set(properties.keys).union(originallyRequired).sorted()
        object["additionalProperties"] = false
        return object
    }

    /// Whether a subschema declares itself an object.
    private static func isObjectTyped(_ object: [String: Any]) -> Bool {
        if let type = object["type"] as? String { return type == "object" }
        if let types = object["type"] as? [String] { return types.contains("object") }
        return false
    }

    /// Widen a subschema so `null` is a legal value for it.
    ///
    /// Widening the `type` alone is not enough. A value must satisfy *every*
    /// keyword, so an `enum` or `const` that does not list `null` keeps
    /// rejecting it — and since strict mode also requires the property, an
    /// optional field would silently become mandatory.
    private static func nullable(_ node: Any) -> Any {
        guard var object = node as? [String: Any] else { return node }

        // `const` pins a single value and cannot be widened in place, so the
        // whole subschema becomes one branch of a union.
        if object["const"] != nil {
            return ["anyOf": [object, ["type": "null"]]]
        }

        var widened = false
        if let type = object["type"] as? String {
            object["type"] = type == "null" ? type : [type, "null"]
            widened = true
        } else if let types = object["type"] as? [String] {
            object["type"] = types.contains("null") ? types : types + ["null"]
            widened = true
        }

        if let values = object["enum"] as? [Any] {
            if !values.contains(where: { $0 is NSNull }) {
                object["enum"] = values + [NSNull()]
            }
            return object
        }
        if widened { return object }

        if var branches = object["anyOf"] as? [Any] {
            guard !branches.contains(where: { ($0 as? [String: Any])?["type"] as? String == "null" })
            else { return object }
            branches.append(["type": "null"])
            object["anyOf"] = branches
            return object
        }
        // A `$ref` carries no type of its own to widen, so the reference is
        // wrapped in a union instead. Sibling keywords are dropped by design:
        // alongside `$ref` they are not evaluated in JSON Schema 2020-12.
        if let reference = object["$ref"] as? String {
            return ["anyOf": [["$ref": reference], ["type": "null"]]]
        }
        // A subschema constraining nothing (`{}`) already admits null.
        return object
    }
}
