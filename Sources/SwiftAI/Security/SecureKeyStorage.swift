// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Security

/// Stores and retrieves API keys securely in the system Keychain
public struct SecureKeyStorage: Sendable {
    private static let servicePrefix = "com.swiftai.provider."

    /// Store an API key for a provider in the Keychain
    /// - Parameters:
    ///   - key: The API key to store
    ///   - provider: Which provider this key belongs to
    public static func store(key: String, forProvider provider: ProviderID) throws {
        let service = servicePrefix + provider.rawValue
        let keyData = Data(key.utf8)

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SwiftAIError.keychainError(status: status)
        }
    }

    /// Retrieve an API key for a provider from the Keychain
    /// - Parameter provider: Which provider to retrieve the key for
    /// - Returns: The stored API key
    public static func retrieve(forProvider provider: ProviderID) throws -> String {
        let service = servicePrefix + provider.rawValue

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw SwiftAIError.keychainError(status: status)
        }

        return key
    }

    /// Delete a stored API key for a provider
    /// - Parameter provider: Which provider to delete the key for
    public static func delete(forProvider provider: ProviderID) throws {
        let service = servicePrefix + provider.rawValue

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SwiftAIError.keychainError(status: status)
        }
    }
}
