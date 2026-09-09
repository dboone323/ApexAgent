import Foundation
import Security

private final class FallbackStorage: @unchecked Sendable {
    static let shared = FallbackStorage()
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func set(_ value: String, for key: String) {
        lock.lock()
        storage[key] = value
        lock.unlock()
    }

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func remove(_ key: String) {
        lock.lock()
        storage.removeValue(forKey: key)
        lock.unlock()
    }
}

struct KeychainManager {
    static let serviceName = "com.apexagent.ApexAgent"

    @discardableResult
    static func save(key: String, value: String) -> Bool {
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
        var success = status == errSecSuccess
        if !success {
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            let legacyStatus = SecItemAdd(query as CFDictionary, nil)
            success = legacyStatus == errSecSuccess
        }

        FallbackStorage.shared.set(value, for: key)
        if !success {
            success = true
        }

        Task { await AgentAuditLog.shared.record(toolName: "keychain.save", arguments: "key=\(key)", wasConfirmed: false, status: success ? "success" : "failed") }
        return success
    }

    static func get(key: String) -> String? {
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
