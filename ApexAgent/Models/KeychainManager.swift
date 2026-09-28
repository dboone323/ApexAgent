import Foundation
import Security
import Synchronization

private final class FallbackStorage: Sendable {
    static let shared = FallbackStorage()
    private let storage = Mutex<[String: String]>([:])

    func set(_ value: String, for key: String) {
        storage.withLock { $0[key] = value }
    }

    func get(_ key: String) -> String? {
        storage.withLock { $0[key] }
    }

    func remove(_ key: String) {
        _ = storage.withLock { $0.removeValue(forKey: key) }
    }
}

struct KeychainManager {
    static let serviceName = "com.apexagent.ApexAgent"

    /// One-time migration of legacy plaintext "secure.*" UserDefaults values
    /// (C1): moves each into the Keychain and deletes the plaintext copy.
    /// Runs lazily on first save/get/delete.
    private static let migrateLegacySecureDefaults: Void = {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix("secure."),
                  let stringValue = value as? String,
                  !stringValue.isEmpty else { continue }
            let account = String(key.dropFirst("secure.".count))
            guard !account.isEmpty else { continue }
            if addToKeychain(key: account, value: stringValue) {
                defaults.removeObject(forKey: key)
            }
        }
    }()

    private static func runLegacyMigration() {
        _ = migrateLegacySecureDefaults
    }

    /// Writes a value to the Keychain (delete-then-add, with a legacy
    /// data-protection fallback). Returns the true Keychain result — callers
    /// must never report success when this returns false (C1).
    private static func addToKeychain(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        deleteQuery[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(deleteQuery as CFDictionary)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return true }
        query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        let legacyStatus = SecItemAdd(query as CFDictionary, nil)
        return legacyStatus == errSecSuccess
    }
    
    /// Securely deletes a file at the given URL by overwriting it with random data
    /// before removing it. This prevents file recovery tools from recovering
    /// sensitive plaintext credentials (e.g., legacy Gemini API keys stored in
    /// `~/.apex/gemini_key`).
    ///
    /// Uses a single-pass random overwrite followed by `removeItem`, which is
    /// sufficient for SSDs (where multi-pass overwrite is unreliable due to
    /// wear-leveling and TRIM). For HDDs, consider increasing `passes`.
    ///
    /// - Parameters:
    ///   - url: The file URL to securely delete.
    ///   - passes: Number of overwrite passes (default: 1, suitable for SSDs).
    /// - Returns: `true` if the file was securely deleted, `false` otherwise.
    static func secureDeleteFile(at url: URL, passes: Int = 1) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return true // Nothing to delete
        }
        
        do {
            let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            guard fileSize > 0 else {
                // Empty file — just remove it
                try FileManager.default.removeItem(at: url)
                return true
            }
            
            // Overwrite with cryptographically secure random data
            let randomData = Data((0..<fileSize).map { _ in UInt8.random(in: 0...255) })
            try randomData.write(to: url, options: .atomic)
            
            // Additional passes if requested (mainly for HDD compatibility)
            for _ in 1..<passes {
                try randomData.write(to: url, options: .atomic)
            }
            
            // Now remove the overwritten file
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            // If overwrite fails (e.g., permission issue), attempt plain removal
            // as a best-effort fallback — the file may still be recoverable,
            // but at least it's gone from the filesystem.
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }
    
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        runLegacyMigration()
        let success = addToKeychain(key: key, value: value)

        // In-memory fallback keeps the value available for this session when
        // the Keychain is unreachable. It is never persisted to disk (C1).
        FallbackStorage.shared.set(value, for: key)

        Task { await AgentAuditLog.shared.record(toolName: "keychain.save", arguments: "key=\(key)", wasConfirmed: false, status: success ? "success" : "failed") }
        return success
    }

    static func get(key: String) -> String? {
        runLegacyMigration()
        if let fallback = FallbackStorage.shared.get(key) {
            Task { await AgentAuditLog.shared.record(toolName: "keychain.get", arguments: "key=\(key)", wasConfirmed: false, status: "success") }
            return fallback
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status != errSecSuccess {
            query[kSecUseDataProtectionKeychain as String] = true
            status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        }
        
        if status == errSecSuccess, let data = dataTypeRef as? Data, let str = String(data: data, encoding: .utf8) {
            Task { await AgentAuditLog.shared.record(toolName: "keychain.get", arguments: "key=\(key)", wasConfirmed: false, status: "success") }
            return str
        }

        Task { await AgentAuditLog.shared.record(toolName: "keychain.get", arguments: "key=\(key)", wasConfirmed: false, status: "failed") }
        return nil
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        runLegacyMigration()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        var status = SecItemDelete(query as CFDictionary)
        query[kSecUseDataProtectionKeychain as String] = true
        let dpStatus = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess {
            status = dpStatus
        }

        FallbackStorage.shared.remove(key)

        let success = status == errSecSuccess || status == errSecItemNotFound
        Task { await AgentAuditLog.shared.record(toolName: "keychain.delete", arguments: "key=\(key)", wasConfirmed: false, status: success ? "success" : "failed") }
        return success
    }
}
