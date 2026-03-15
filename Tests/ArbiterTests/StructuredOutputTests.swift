// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
import Foundation
@testable import Arbiter

private struct TestRecipe: Codable, Sendable, Equatable {
    let name: String
    let ingredients: [String]
}

private struct NestedType: Codable, Sendable, Equatable {
    let title: String
    let metadata: Metadata

    struct Metadata: Codable, Sendable, Equatable {
        let author: String
        let year: Int
    }
}

@Suite("StructuredOutput")
struct StructuredOutputTests {
    let handler = StructuredOutputHandler()

    @Test("Decode strips markdown fences")
    func decodeStripsMarkdownFences() throws {
        let content = """
        ```json
        {"name": "Pasta", "ingredients": ["flour", "eggs"]}
        ```
        """
        let result = try handler.decode(content, as: TestRecipe.self)
        #expect(result.name == "Pasta")
        #expect(result.ingredients == ["flour", "eggs"])
    }

    @Test("Decode handles preamble text before JSON")
    func decodeHandlesPreamble() throws {
        let content = """
        Here's the recipe you asked for:
        {"name": "Salad", "ingredients": ["lettuce", "tomato"]}
        """
        let result = try handler.decode(content, as: TestRecipe.self)
        #expect(result.name == "Salad")
    }

    @Test("Decode throws decodingFailed with raw content on bad JSON")
    func decodeThrowsOnBadJSON() {
        let content = "This is not JSON at all, just random text without braces"
        do {
            _ = try handler.decode(content, as: TestRecipe.self)
            Issue.record("Expected decoding to throw")
        } catch let error as ArbiterError {
            if case .decodingFailed = error {
                // Expected
            } else {
                Issue.record("Expected .decodingFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected ArbiterError, got \(error)")
        }
    }

    @Test("Decode handles nested Codable types")
    func decodeNestedTypes() throws {
        let content = """
        {"title": "Book", "metadata": {"author": "Author", "year": 2024}}
        """
        let result = try handler.decode(content, as: NestedType.self)
        #expect(result.title == "Book")
        #expect(result.metadata.author == "Author")
        #expect(result.metadata.year == 2024)
    }

    @Test("Decode handles arrays")
    func decodeArrays() throws {
        let content = """
        [{"name": "A", "ingredients": []}, {"name": "B", "ingredients": ["x"]}]
        """
        let result = try handler.decode(content, as: [TestRecipe].self)
        #expect(result.count == 2)
        #expect(result[0].name == "A")
    }

    @Test("Full generate<T> with MockProvider returning valid JSON")
    func generateTypedValidJSON() async throws {
        let json = #"{"name": "Soup", "ingredients": ["water", "salt"]}"#
        let provider = MockProvider(responseContent: json)
        let ai = Arbiter(provider: provider)
        let recipe: TestRecipe = try await ai.generate("Make a recipe", as: TestRecipe.self)
        #expect(recipe.name == "Soup")
        #expect(recipe.ingredients == ["water", "salt"])
    }

    @Test("Full generate<T> with MockProvider returning fenced JSON")
    func generateTypedFencedJSON() async throws {
        let json = "```json\n{\"name\": \"Cake\", \"ingredients\": [\"flour\"]}\n```"
        let provider = MockProvider(responseContent: json)
        let ai = Arbiter(provider: provider)
        let recipe: TestRecipe = try await ai.generate("Make a recipe", as: TestRecipe.self)
        #expect(recipe.name == "Cake")
    }

    @Test("Full generate<T> with MockProvider returning garbage throws error")
    func generateTypedGarbageThrows() async {
        let provider = MockProvider(responseContent: "Not JSON at all, sorry!")
        let ai = Arbiter(provider: provider)
        do {
            let _: TestRecipe = try await ai.generate("Make a recipe", as: TestRecipe.self)
            Issue.record("Expected error")
        } catch let error as ArbiterError {
            if case .decodingFailed = error {
                // Expected
            } else {
                Issue.record("Expected .decodingFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected ArbiterError, got \(error)")
        }
    }

    @Test("buildJSONPrompt with example includes actual JSON structure")
    func promptWithExampleIncludesSchema() {
        let example = TestRecipe(name: "Example", ingredients: ["flour"])
        let prompt = handler.buildJSONPrompt(
            for: TestRecipe.self,
            userPrompt: "Make a recipe",
            example: example
        )
        #expect(prompt.contains("\"name\""))
        #expect(prompt.contains("\"ingredients\""))
        #expect(prompt.contains("flour"))
    }

    @Test("buildJSONPrompt without example still produces valid prompt")
    func promptWithoutExampleWorks() {
        let prompt = handler.buildJSONPrompt(
            for: TestRecipe.self,
            userPrompt: "Make a recipe"
        )
        #expect(prompt.contains("TestRecipe"))
        #expect(prompt.contains("JSON"))
    }

    @Test("generate<T> with example produces correct result")
    func generateWithExample() async throws {
        let json = #"{"name": "Soup", "ingredients": ["water"]}"#
        let provider = MockProvider(responseContent: json)
        let ai = Arbiter(provider: provider)
        let recipe: TestRecipe = try await ai.generate(
            "Make soup",
            as: TestRecipe.self,
            example: TestRecipe(name: "", ingredients: [])
        )
        #expect(recipe.name == "Soup")
    }
}
