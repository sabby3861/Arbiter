// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "StructuredOutput")

struct StructuredOutputHandler: Sendable {
    private let decoder = JSONDecoder()

    func buildJSONPrompt<T: Codable>(for type: T.Type, userPrompt: String) -> String {
        let schemaDescription = describeType(type)
        return """
        \(userPrompt)

        Respond ONLY with valid JSON matching this structure:
        \(schemaDescription)

        Do not include any explanation, markdown fences, or text outside the JSON object.
        """
    }

    func decode<T: Codable>(_ rawContent: String, as type: T.Type) throws -> T {
        let cleaned = extractJSON(from: rawContent)

        guard let jsonData = cleaned.data(using: .utf8) else {
            throw SwiftAIError.decodingFailed(
                context: "Could not convert response to data. Raw content: \(String(rawContent.prefix(500)))"
            )
        }

        do {
            return try decoder.decode(T.self, from: jsonData)
        } catch {
            logger.error("Failed to decode structured output: \(error.localizedDescription)")
            throw SwiftAIError.decodingFailed(
                context: "JSON decode failed: \(error.localizedDescription). Raw content: \(String(rawContent.prefix(500)))"
            )
        }
    }
}

private extension StructuredOutputHandler {
    func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the first { or [ and the last matching } or ]
        guard let firstBrace = cleaned.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return cleaned
        }
        let opener = cleaned[firstBrace]
        let closer: Character = opener == "{" ? "}" : "]"

        guard let lastBrace = cleaned.lastIndex(of: closer) else {
            return cleaned
        }

        return String(cleaned[firstBrace...lastBrace])
    }

    func describeType<T: Codable>(_ type: T.Type) -> String {
        let typeName = String(describing: type)
        return "{\(typeName) properties as JSON keys with appropriate value types}"
    }
}
