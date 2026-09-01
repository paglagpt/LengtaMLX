//
// KeychainStore.swift
// Secure credential storage and v1 UserDefaults migration for PaglaMLX.
//
// Secrets are stored as macOS Keychain generic-password items. The migration
// path is deliberately write-before-delete: a legacy value is removed only
// after its Keychain replacement has been written successfully.
//

import Foundation
import Security

/// A small, synchronous API around the macOS Keychain.
///
/// The implementation serializes Security framework calls on a private queue.
/// Callers should keep the returned strings short-lived and must not log them.
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()

    public enum KeyType: String, CaseIterable, Sendable {
        case bearer
        case openAI = "openai"
        case anthropic
        case openRouter = "openrouter"
        case groq
        case together
        case gemini
        case deepSeek = "deepseek"
        case mistral
        case perplexity
        case cohere
        case fireworks
        case hyperbolic
        case sambaNova = "sambanova"

        public var service: String { "com.paglaai.paglamlx" }
        public var account: String { "paglamlx.\(rawValue)" }

        public var displayName: String {
            switch self {
            case .bearer: return "Gateway bearer token"
            case .openAI: return "OpenAI"
            case .anthropic: return "Anthropic"
            case .openRouter: return "OpenRouter"
            case .groq: return "Groq"
            case .together: return "Together"
            case .gemini: return "Gemini"
            case .deepSeek: return "DeepSeek"
            case .mistral: return "Mistral"
            case .perplexity: return "Perplexity"
            case .cohere: return "Cohere"
            case .fireworks: return "Fireworks"
            case .hyperbolic: return "Hyperbolic"
            case .sambaNova: return "SambaNova"
            }
        }
    }

    public enum KeychainError: Error, LocalizedError, Sendable {
        case itemNotFound
        case accessDenied
        case encodingFailed
        case decodingFailed
        case operationFailed

        public var errorDescription: String? {
            switch self {
            case .itemNotFound: return "The requested credential was not found."
            case .accessDenied: return "Access to the macOS Keychain was denied or unavailable."
            case .encodingFailed: return "The credential could not be encoded."
            case .decodingFailed: return "The stored credential could not be decoded."
            case .operationFailed: return "The Keychain operation failed."
            }
        }
    }

    private static let legacyMappings: [(KeyType, String)] = [
        (.bearer, "apiKey"),
        (.openAI, "openaiKey"),
        (.anthropic, "anthropicKey"),
        (.openRouter, "openrouterKey"),
        (.groq, "groqKey"),
        (.together, "togetherKey"),
        (.gemini, "geminiKey"),
        (.deepSeek, "deepseekKey"),
        (.mistral, "mistralKey"),
        (.perplexity, "perplexityKey"),
        (.cohere, "cohereKey"),
        (.fireworks, "fireworksKey"),
        (.hyperbolic, "hyperbolicKey"),
        (.sambaNova, "sambanovaKey")
    ]

    private let queue = DispatchQueue(
        label: "com.paglaai.paglamlx.keychain",
        qos: .userInitiated
    )

    private init() {}

    public func set(_ value: String, for key: KeyType) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try queue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: key.service,
                kSecAttrAccount as String: key.account
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecItemNotFound {
                var addQuery = query
                addQuery.merge(attributes) { _, new in new }
                guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
                    throw mapStatus(SecItemCopyMatching(query as CFDictionary, nil))
                }
            } else if updateStatus != errSecSuccess {
                throw mapStatus(updateStatus)
            }
        }
    }

    public func get(_ key: KeyType) throws -> String? {
        try queue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: key.service,
                kSecAttrAccount as String: key.account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw mapStatus(status) }
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return value
        }
    }

    public func delete(_ key: KeyType) throws {
        try queue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: key.service,
                kSecAttrAccount as String: key.account
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw mapStatus(status)
            }
        }
    }

    public func hasCredential(for key: KeyType) -> Bool {
        do {
            guard let value = try get(key) else { return false }
            return !value.isEmpty
        } catch {
            return false
        }
    }

    /// Migrates legacy credentials and returns the number successfully moved.
    /// Existing Keychain values win; their corresponding legacy values are
    /// removed because the destination is already known to be safe.
    @discardableResult
    public func migrateFromUserDefaults(
        defaults: UserDefaults = .standard
    ) throws -> Int {
        var migrated = 0
        for (key, legacyKey) in Self.legacyMappings {
            guard let legacyValue = defaults.string(forKey: legacyKey), !legacyValue.isEmpty else {
                continue
            }

            if let existing = try get(key), !existing.isEmpty {
                defaults.removeObject(forKey: legacyKey)
                continue
            }

            do {
                try set(legacyValue, for: key)
                defaults.removeObject(forKey: legacyKey)
                migrated += 1
            } catch {
                // Preserve the legacy value so a later launch can retry.
                throw error
            }
        }
        return migrated
    }

    public func hasUserDefaultsCredentials(
        defaults: UserDefaults = .standard
    ) -> Bool {
        Self.legacyMappings.contains { _, key in
            guard let value = defaults.string(forKey: key) else { return false }
            return !value.isEmpty
        }
    }

    public func getOrCreateBearerToken() throws -> String {
        if let token = try get(.bearer), !token.isEmpty { return token }
        let token = try Self.generateBearerToken()
        try set(token, for: .bearer)
        return token
    }

    public static func generateBearerToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeychainError.operationFailed
        }
        return "sk-paglamlx-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func mapStatus(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecItemNotFound: return .itemNotFound
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable, errSecMissingEntitlement:
            return .accessDenied
        default: return .operationFailed
        }
    }
}

public extension KeychainStore {
    func setBearerToken(_ token: String) throws { try set(token, for: .bearer) }
    func getBearerToken() throws -> String? { try get(.bearer) }
    func deleteBearerToken() throws { try delete(.bearer) }
    func setAPIKey(_ key: KeyType, value: String) throws { try set(value, for: key) }
    func getAPIKey(_ key: KeyType) throws -> String? { try get(key) }
    func deleteAPIKey(_ key: KeyType) throws { try delete(key) }
}
