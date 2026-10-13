// DotCredentialVault.swift
// Batch 126: Native macOS Keychain credential vault for persistent per-Dot
// secrets, model provider API keys, and credential access audit logging.

import Foundation
import Security
import CryptoKit

/// Recognized credential types and model provider secrets.
public enum DotCredentialType: String, Sendable, Codable, CaseIterable {
    case gitHubCopilotToken = "github.copilot.token"
    case geminiApiKey = "google.gemini.apikey"
    case anthropicApiKey = "anthropic.apikey"
    case openAIApiKey = "openai.apikey"
    case customDotSecret = "dot.custom.secret"
}

/// Metadata associated with a stored secret.
public struct DotCredentialMetadata: Sendable, Codable, Equatable {
    public let key: String
    public let dotId: UUID?
    public let credentialType: DotCredentialType
    public let createdAt: Date
    public var updatedAt: Date
    public var description: String

    public init(
        key: String,
        dotId: UUID? = nil,
        credentialType: DotCredentialType = .customDotSecret,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        description: String = ""
    ) {
        self.key = key
        self.dotId = dotId
        self.credentialType = credentialType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.description = description
    }
}

/// Audit entry recorded whenever a secret is accessed or modified.
public struct CredentialAccessAuditEntry: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let key: String
    public let action: String // "read", "write", "delete"
    public let success: Bool

    public init(
        timestamp: Date = Date(),
        key: String,
        action: String,
        success: Bool
    ) {
        self.timestamp = timestamp
        self.key = key
        self.action = action
        self.success = success
    }
}

/// Errors thrown by the DotCredentialVault.
public enum DotCredentialVaultError: LocalizedError, Sendable, Equatable {
    case emptyKey
    case storageFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "Credential key cannot be empty."
        case .storageFailed(let message):
            return "Credential operation failed: \(message)"
        }
    }
}

/// Actor managing macOS Keychain integration, per-Dot secrets, and audit logging.
public actor DotCredentialVault {
    public static let shared = DotCredentialVault()

    private var auditLog: [CredentialAccessAuditEntry] = []
    private var memoryStore: [String: String] = [:]
    private var metadataStore: [String: DotCredentialMetadata] = [:]

    public init() {}

    /// Stores a secret into the macOS Keychain with memory-store mirroring.
    public func storeSecret(
        key: String,
        value: String,
        dotId: UUID? = nil,
        type: DotCredentialType = .customDotSecret,
        description: String = ""
    ) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DotCredentialVaultError.emptyKey
        }

        _ = KeychainManager.save(key: key, value: value)
        memoryStore[key] = value

        let now = Date()
        if var existing = metadataStore[key] {
            existing.updatedAt = now
            if !description.isEmpty {
                existing.description = description
            }
            metadataStore[key] = existing
        } else {
            metadataStore[key] = DotCredentialMetadata(
                key: key,
                dotId: dotId,
                credentialType: type,
                createdAt: now,
                updatedAt: now,
                description: description
            )
        }

        auditLog.append(CredentialAccessAuditEntry(
            timestamp: now,
            key: key,
            action: "write",
            success: true
        ))
    }

    /// Retrieves a secret from Keychain, falling back to memory store if unavailable.
    public func retrieveSecret(key: String) throws -> String? {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DotCredentialVaultError.emptyKey
        }

        let found = KeychainManager.get(key: key) ?? memoryStore[key]
        if let found {
            memoryStore[key] = found
            if metadataStore[key] == nil {
                let inferredType = DotCredentialType(rawValue: key) ?? .customDotSecret
                metadataStore[key] = DotCredentialMetadata(
                    key: key,
                    dotId: nil,
                    credentialType: inferredType,
                    createdAt: Date(),
                    updatedAt: Date(),
                    description: ""
                )
            }
        }

        auditLog.append(CredentialAccessAuditEntry(
            timestamp: Date(),
            key: key,
            action: "read",
            success: found != nil
        ))
        return found
    }

    /// Deletes a secret from both the Keychain and memory store.
    public func deleteSecret(key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DotCredentialVaultError.emptyKey
        }

        _ = KeychainManager.delete(key: key)
        memoryStore.removeValue(forKey: key)
        metadataStore.removeValue(forKey: key)

        auditLog.append(CredentialAccessAuditEntry(
            timestamp: Date(),
            key: key,
            action: "delete",
            success: true
        ))
    }

    /// Checks if a secret exists in the vault.
    public func hasSecret(key: String) -> Bool {
        (try? retrieveSecret(key: key)) != nil
    }

    /// Returns a copy of the audit log.
    public func getAuditLog() -> [CredentialAccessAuditEntry] {
        auditLog
    }

    /// Clears the audit log.
    public func clearAuditLog() {
        auditLog.removeAll()
    }

    /// Stores a model provider credential using its standard key.
    public func storeProviderKey(provider: DotCredentialType, secret: String) throws {
        try storeSecret(key: provider.rawValue, value: secret, type: provider)
    }

    /// Retrieves a model provider credential using its standard key.
    public func retrieveProviderKey(provider: DotCredentialType) throws -> String? {
        try retrieveSecret(key: provider.rawValue)
    }

    /// Deletes a model provider credential.
    public func deleteProviderKey(provider: DotCredentialType) throws {
        try deleteSecret(key: provider.rawValue)
    }

    /// Checks if a provider credential exists.
    public func hasProviderKey(provider: DotCredentialType) -> Bool {
        hasSecret(key: provider.rawValue)
    }

    /// Returns metadata for the given key, if available.
    public func getMetadata(key: String) -> DotCredentialMetadata? {
        metadataStore[key]
    }

    /// Returns all stored metadata entries.
    public func listCredentials() -> [DotCredentialMetadata] {
        Array(metadataStore.values)
    }

    /// Computes a SHA-256 fingerprint of the secret for safe identification.
    public static func fingerprint(secret: String) -> String {
        let digest = SHA256.hash(data: Data(secret.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Resets all in-memory secrets and audit entries, removing entries from Keychain.
    public func resetAll() {
        for key in memoryStore.keys {
            _ = KeychainManager.delete(key: key)
        }
        memoryStore.removeAll()
        metadataStore.removeAll()
        auditLog.removeAll()
    }
}
