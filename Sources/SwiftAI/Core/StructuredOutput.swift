// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "StructuredOutput")

struct StructuredOutputHandler: Sendable {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    func buildJSONPrompt<T: Codable>(
        for type: T.Type,
        userPrompt: String,
        example: T? = nil
    ) -> String {
        let schemaBlock: String
        if let example,
           let data = try? encoder.encode(example),
           let json = String(data: data, encoding: .utf8) {
            schemaBlock = """
            Respond with ONLY a valid JSON object matching this exact structure:
            \(json)
            Replace the example values with real values based on the prompt.
            """
        } else {
            schemaBlock = """
            Respond with ONLY a valid JSON object. \
            The JSON must represent a \(String(describing: type)) \
            with all its properties as keys. \
            Use appropriate JSON types: strings as "text", \
            numbers as 0, booleans as true/false, \
            arrays as [...], nested objects as {...}. \
            Do not include any explanation or markdown.
            """
        }

        return """
        \(userPrompt)

        \(schemaBlock)
        Do not include markdown fences, explanation, or any text outside the JSON object.
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
}
