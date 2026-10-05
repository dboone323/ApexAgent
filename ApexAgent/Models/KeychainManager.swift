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

    static var isTestProcess: Bool {
        getenv("APEX_TEST_MODE") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("test")
            || NSClassFromString("XCTestCase") != nil
    }

    static var activeServiceName: String {
        guard isTestProcess else { return serviceName }
        return "\(serviceName).test.\(ProcessInfo.processInfo.processIdentifier)"
    }

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
        guard !isTestProcess else { return }
        _ = migrateLegacySecureDefaults
    }

    @discardableResult
    static func migrateLegacyFile(at url: URL, toKey key: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }

        do {
            let value = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                try FileManager.default.removeItem(at: url)
                return true
            }
            guard save(key: key, value: value) else { return false }
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("Keychain migration failed for legacy file \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// Writes a value to the Keychain (delete-then-add, with a legacy
    /// data-protection fallback). Returns the true Keychain result — callers
    /// must never report success when this returns false (C1).
    private static func addToKeychain(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: activeServiceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        deleteQuery[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(deleteQuery as CFDictionary)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: activeServiceName,
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
    
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        runLegacyMigration()
        guard !value.isEmpty else { return delete(key: key) }
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
            kSecAttrService as String: activeServiceName,
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
            kSecAttrService as String: activeServiceName,
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
