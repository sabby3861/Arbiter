// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Security

/// Stores and retrieves API keys securely in the system Keychain.
///
/// Usage:
/// ```swift
/// // Store a key once (e.g., from a server config endpoint or onboarding flow)
/// try SecureKeyStorage.store(key: "sk-ant-...", forProvider: .anthropic)
///
/// // Later, create a provider that reads from Keychain
/// let provider = try AnthropicProvider(keyStorage: .anthropic)
/// ```
public struct SecureKeyStorage: Sendable {
    private static let servicePrefix = "com.swiftai.keys."

    /// Store an API key for a provider in the Keychain
    /// - Parameters:
    ///   - key: The API key to store
    ///   - provider: Which provider this key belongs to
    public static func store(key: String, forProvider provider: ProviderID) throws {
        let service = servicePrefix + provider.rawValue
        let keyData = Data(key.utf8)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
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

    /// Check if a key exists for a provider without retrieving it
    /// - Parameter provider: Which provider to check
    /// - Returns: `true` if a key is stored for this provider
    public static func hasKey(forProvider provider: ProviderID) -> Bool {
        let service = servicePrefix + provider.rawValue

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: false,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
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
