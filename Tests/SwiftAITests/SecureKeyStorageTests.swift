// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("SecureKeyStorage", .serialized)
struct SecureKeyStorageTests {

    // Use ollama as a test provider — unlikely to have real keys in CI
    private static let testProvider: ProviderID = .ollama

    private func cleanup() {
        try? SecureKeyStorage.delete(forProvider: Self.testProvider)
    }

    @Test func storeAndRetrieveRoundtrip() throws {
        cleanup()
        defer { cleanup() }

        let key = "sk-test-\(UUID().uuidString)"
        try SecureKeyStorage.store(key: key, forProvider: Self.testProvider)
        let retrieved = try SecureKeyStorage.retrieve(forProvider: Self.testProvider)
        #expect(retrieved == key)
    }

    @Test func hasKeyReturnsTrueAfterStore() throws {
        cleanup()
        defer { cleanup() }

        #expect(!SecureKeyStorage.hasKey(forProvider: Self.testProvider))
        try SecureKeyStorage.store(key: "test-key", forProvider: Self.testProvider)
        #expect(SecureKeyStorage.hasKey(forProvider: Self.testProvider))
    }

    @Test func deleteRemovesKey() throws {
        cleanup()

        try SecureKeyStorage.store(key: "test-key", forProvider: Self.testProvider)
        #expect(SecureKeyStorage.hasKey(forProvider: Self.testProvider))

        try SecureKeyStorage.delete(forProvider: Self.testProvider)
        #expect(!SecureKeyStorage.hasKey(forProvider: Self.testProvider))
    }

    @Test func retrieveNonExistentKeyThrows() {
        cleanup()

        #expect(throws: SwiftAIError.self) {
            try SecureKeyStorage.retrieve(forProvider: Self.testProvider)
        }
    }

    @Test func deleteNonExistentKeySucceeds() throws {
        cleanup()
        // Should not throw — itemNotFound is acceptable
        try SecureKeyStorage.delete(forProvider: Self.testProvider)
    }

    @Test func overwriteExistingKey() throws {
        cleanup()
        defer { cleanup() }

        try SecureKeyStorage.store(key: "first-key", forProvider: Self.testProvider)
        try SecureKeyStorage.store(key: "second-key", forProvider: Self.testProvider)

        let retrieved = try SecureKeyStorage.retrieve(forProvider: Self.testProvider)
        #expect(retrieved == "second-key")
    }

    @Test func specialCharactersInKey() throws {
        cleanup()
        defer { cleanup() }

        let key = "sk-abc123!@#$%^&*()_+-={}[]|;':\",./<>?"
        try SecureKeyStorage.store(key: key, forProvider: Self.testProvider)
        let retrieved = try SecureKeyStorage.retrieve(forProvider: Self.testProvider)
        #expect(retrieved == key)
    }

    @Test func longKeyValue() throws {
        cleanup()
        defer { cleanup() }

        let key = String(repeating: "a", count: 4096)
        try SecureKeyStorage.store(key: key, forProvider: Self.testProvider)
        let retrieved = try SecureKeyStorage.retrieve(forProvider: Self.testProvider)
        #expect(retrieved == key)
    }
}
