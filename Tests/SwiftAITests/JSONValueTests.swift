// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("JSONValue")
struct JSONValueTests {

    // MARK: - Codable roundtrip

    @Test func stringRoundtrip() throws {
        let value: JSONValue = .string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func numberRoundtrip() throws {
        let value: JSONValue = .number(42.5)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func boolRoundtrip() throws {
        let value: JSONValue = .bool(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func nullRoundtrip() throws {
        let value: JSONValue = .null
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func arrayRoundtrip() throws {
        let value: JSONValue = .array([.string("a"), .number(1), .bool(false)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func objectRoundtrip() throws {
        let value: JSONValue = .object(["key": .string("value"), "count": .number(3)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func nestedStructureRoundtrip() throws {
        let value: JSONValue = .object([
            "name": .string("test"),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .object(["nested": .bool(true)]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    // MARK: - Expressible literal conformances

    @Test func stringLiteral() {
        let value: JSONValue = "hello"
        #expect(value == .string("hello"))
    }

    @Test func integerLiteral() {
        let value: JSONValue = 42
        #expect(value == .number(42))
    }

    @Test func floatLiteral() {
        let value: JSONValue = 3.14
        #expect(value == .number(3.14))
    }

    @Test func boolLiteral() {
        let value: JSONValue = true
        #expect(value == .bool(true))
    }

    @Test func arrayLiteral() {
        let value: JSONValue = ["a", 1, true]
        #expect(value == .array([.string("a"), .number(1), .bool(true)]))
    }

    @Test func dictionaryLiteral() {
        let value: JSONValue = ["key": "value"]
        #expect(value == .object(["key": .string("value")]))
    }

    // MARK: - Edge cases

    @Test func emptyArray() throws {
        let value: JSONValue = .array([])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func emptyObject() throws {
        let value: JSONValue = .object([:])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func equatableAndHashable() {
        let a: JSONValue = .string("test")
        let b: JSONValue = .string("test")
        let c: JSONValue = .string("other")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }
}
