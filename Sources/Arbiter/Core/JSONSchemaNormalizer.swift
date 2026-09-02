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
/// Shared between providers on purpose: OpenAI strict mode, Anthropic's
/// `output_config.format` and Gemini's `responseFormat` all start from the same
/// parse step and then diverge — strict mode requires every property, the other
/// two allow optional ones; Anthropic rejects an unsupported keyword where
/// Gemini ignores it.
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

// MARK: - Gemini

extension JSONSchemaNormalizer {
    /// Metadata and validation keywords Gemini's structured-output subset does
    /// not implement.
    ///
    /// The API ignores what it does not understand rather than rejecting it, so
    /// dropping these changes nothing on the wire — but it keeps the request
    /// body honest about what is actually being enforced, and keeps a caller
    /// from believing a `pattern` constrains the answer when it does not.
    /// Verified 2 September 2026 against
    /// https://ai.google.dev/gemini-api/docs/generate-content/structured-output.
    private static let geminiUnsupportedKeywords = [
        "$schema", "$id", "$comment", "pattern", "patternProperties",
    ]

    /// Rewrite a schema into the subset Gemini's structured output supports.
    ///
    /// Unlike OpenAI's strict mode this is a *subtractive* pass: Gemini accepts
    /// optional properties, so which properties are required is left exactly as
    /// the caller wrote it, and `additionalProperties` — supported since the
    /// `responseFormat` field replaced the OpenAPI-subset `responseSchema` — is
    /// passed through rather than forced.
    ///
    /// This is the *response* schema's dialect only. A tool's `parameters` is a
    /// different field with a different type (`Schema`, the OpenAPI subset),
    /// which does implement `pattern` and the length bounds this drops — so a
    /// tool schema must not be run through here.
    static func geminiSchema(_ schema: [String: Any]) -> [String: Any] {
        geminified(schema) as? [String: Any] ?? schema
    }

    private static func geminified(_ node: Any) -> Any {
        guard var object = node as? [String: Any] else {
            if let array = node as? [Any] { return array.map { geminified($0) } }
            return node
        }
        for keyword in geminiUnsupportedKeywords {
            object.removeValue(forKey: keyword)
        }
        if let branches = object["allOf"] as? [Any] {
            object["allOf"] = branches.map { geminified($0) }
        }
        return descend(object, using: geminified)
    }
}

// MARK: - Anthropic

extension JSONSchemaNormalizer {
    /// Keywords Anthropic's structured outputs reject with an HTTP 400.
    ///
    /// Numeric constraints and the string *length* bounds are unsupported
    /// outright; `minItems` is supported only for the values 0 and 1, so it is
    /// handled separately. `pattern` is deliberately absent from this list:
    /// Anthropic documents which regex features it implements, so a pattern is
    /// enforced rather than rejected and dropping it would silently loosen the
    /// schema.
    ///
    /// Keywords the docs mention neither way — `oneOf`, `not`, `if`/`then` —
    /// are passed through untouched. `JSONSchemaBuilder` never emits them, so
    /// they only arrive in a schema a caller pasted, and a 400 naming the
    /// keyword tells that caller more than quietly deleting a constraint they
    /// wrote.
    /// Verified 2 September 2026 against
    /// https://platform.claude.com/docs/en/build-with-claude/structured-outputs.
    private static let anthropicUnsupportedKeywords = [
        "$schema", "$id", "$comment",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength",
        "maxItems", "uniqueItems",
    ]

    /// The string `format` values Anthropic's structured outputs implement.
    private static let anthropicSupportedFormats: Set<String> = [
        "date-time", "time", "date", "duration",
        "email", "hostname", "uri", "ipv4", "ipv6", "uuid",
    ]

    /// Rewrite a schema into the subset Anthropic's `output_config.format` accepts.
    ///
    /// Anthropic differs from OpenAI strict mode in the one way that matters
    /// most: optional properties are legal, so `required` is left as written
    /// rather than widened to every property. What it does insist on is
    /// `additionalProperties: false` on every object, and that no unsupported
    /// constraint keyword appears at all — those are a 400, not a silent
    /// ignore, which is why this pass removes them instead of trusting the API
    /// to overlook them.
    static func anthropicSchema(_ schema: [String: Any]) -> [String: Any] {
        anthropicised(schema) as? [String: Any] ?? schema
    }

    /// - Parameter closeObjects: whether this node may be given
    ///   `additionalProperties: false`. False for an `allOf` branch, whose
    ///   properties are merged with its siblings': closing a branch would
    ///   forbid what the others contribute and leave the composition
    ///   unsatisfiable. Its subschemas are closed as usual.
    private static func anthropicised(_ node: Any, closeObjects: Bool = true) -> Any {
        guard var object = node as? [String: Any] else {
            if let array = node as? [Any] { return array.map { anthropicised($0) } }
            return node
        }

        for keyword in anthropicUnsupportedKeywords {
            object.removeValue(forKey: keyword)
        }
        // Only `minItems: 0` and `minItems: 1` are implemented; any other value
        // is rejected rather than clamped, because clamping would quietly
        // loosen a constraint the caller asked for.
        if let minItems = object["minItems"] as? Int, minItems > 1 {
            object.removeValue(forKey: "minItems")
        }
        if let format = object["format"] as? String, !anthropicSupportedFormats.contains(format) {
            object.removeValue(forKey: "format")
        }
        // Anything other than `false` is refused, so an explicit map type is
        // closed wherever it appears — including inside an `allOf` branch,
        // where *adding* a closure would be wrong but leaving a map type would
        // still be a 400.
        if object["additionalProperties"] is [String: Any] {
            object["additionalProperties"] = false
        } else if closeObjects, isObjectTyped(object) || object["properties"] != nil {
            object["additionalProperties"] = false
        }
        if let branches = object["allOf"] as? [Any] {
            object["allOf"] = branches.map { anthropicised($0, closeObjects: false) }
        }
        return descend(object, using: { anthropicised($0) })
    }
}

// MARK: - Shared recursion

private extension JSONSchemaNormalizer {
    /// Apply `transform` to every subschema of `object`, leaving its own
    /// keywords alone.
    ///
    /// The keys walked here are the ones whose values are schemas rather than
    /// constraint values: descending into anything else would rewrite data the
    /// caller meant literally (an `enum` of strings, say).
    static func descend(_ object: [String: Any], using transform: (Any) -> Any) -> [String: Any] {
        var object = object
        for key in ["$defs", "definitions", "properties"] {
            if let members = object[key] as? [String: Any] {
                object[key] = members.mapValues { transform($0) }
            }
        }
        // `allOf` is left to the caller: its branches are merged rather than
        // standalone, so a pass that adds keywords has to treat them
        // differently from the alternatives in `anyOf`/`oneOf`.
        for key in ["anyOf", "oneOf", "prefixItems"] {
            if let branches = object[key] as? [Any] {
                object[key] = branches.map { transform($0) }
            }
        }
        if let items = object["items"] {
            object["items"] = transform(items)
        }
        // A schema-valued `additionalProperties` is a subschema too; a boolean
        // is not, and `transform` returns it unchanged.
        if let additional = object["additionalProperties"], additional is [String: Any] {
            object["additionalProperties"] = transform(additional)
        }
        return object
    }
}
