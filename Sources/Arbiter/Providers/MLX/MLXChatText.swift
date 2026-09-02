// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Renders `MessageContent` into the plain text MLX chat templates consume.
///
/// MLX's `Chat.Message` carries a string per turn, so tool calls and tool results
/// are serialised into that string rather than a structured field. Lives outside
/// the `canImport(MLX)` guard so it is unit-testable on every platform.
enum MLXChatText {
    /// Text for one turn, or `nil` when the content renders to nothing
    /// (e.g. an image-only turn, which MLX's text path cannot carry).
    static func render(_ content: MessageContent) -> String? {
        let rendered = fragments(content)
        return rendered.isEmpty ? nil : rendered.joined(separator: "\n")
    }

    private static func fragments(_ content: MessageContent) -> [String] {
        switch content {
        case .text(let text):
            return [text]
        case .image, .document:
            return []
        case .thinking:
            // A local model is not given another model's reasoning to continue from.
            return []
        case .toolCalls(let calls):
            return calls.map { render($0) }
        case .toolResults(let results):
            return results.map { $0.content }
        case .mixed(let parts):
            return parts.flatMap { fragments($0) }
        }
    }

    /// `{"name":…,"arguments":…}` — the shape most chat templates expect for a call.
    private static func render(_ call: ToolCall) -> String {
        let payload: [String: Any] = [
            "name": call.name,
            "arguments": call.arguments.foundationObject,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return call.name
        }
        return json
    }
}
