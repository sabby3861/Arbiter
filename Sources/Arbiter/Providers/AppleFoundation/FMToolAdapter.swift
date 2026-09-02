// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Presents an ``AppleFMToolBinding`` to Foundation Models as one of its own `Tool`s.
///
/// `Arguments` is `GeneratedContent` rather than a `@Generable` struct because Arbiter's
/// tools are described by a runtime JSON Schema, not a Swift type: there is no compile-time
/// shape to generate against. `GeneratedContent` is itself `Generable`, so it satisfies the
/// protocol, and `parameters` is stored — overriding the `where Arguments: Generable`
/// extension default, which would otherwise advertise `GeneratedContent`'s own schema and
/// let the model pass anything at all.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct FMBoundTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    private let execute: @Sendable (JSONValue) async throws -> String

    init(binding: AppleFMToolBinding) throws {
        let definition = binding.definition
        let tree = try FMSchemaConverter.tree(
            from: definition.inputSchema,
            rootName: "\(FMSchemaConverter.sanitised(definition.name))Arguments"
        )
        self.name = definition.name
        self.description = definition.description
        self.parameters = try FMBridge.generationSchema(from: tree)
        self.execute = binding.execute
    }

    /// Runs inside the session's generation loop: whatever this returns, the model reads and
    /// keeps generating from. A throw here reaches Arbiter as `ToolCallError`, which maps to
    /// `ArbiterError.invalidRequest` naming the tool.
    func call(arguments: GeneratedContent) async throws -> String {
        try await execute(Self.jsonValue(from: arguments))
    }

    /// Arguments arrive as constrained-decoding output; `JSONValue` is what an Arbiter tool
    /// executor speaks. Content that will not decode becomes an empty object rather than a
    /// throw: the model produced it under this tool's own schema, so a decode failure is a
    /// bridging gap, and handing the executor an empty argument set lets it report the
    /// problem in terms its caller understands.
    private static func jsonValue(from content: GeneratedContent) -> JSONValue {
        guard let data = content.jsonString.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .object([:])
        }
        return value
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
extension FMBoundTool {
    /// Builds the tool list a session is constructed with.
    static func tools(for options: AppleFMOptions) throws -> [any Tool] {
        try options.tools.map { try FMBoundTool(binding: $0) }
    }
}

#endif
