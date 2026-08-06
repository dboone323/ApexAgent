import Foundation
import Security

struct KeychainManager {
    static let serviceName = "com.apexagent.ApexAgent"

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        
        // Prepare delete query first (excluding the value data)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        // Delete existing item if it exists
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Prepare add query with strict accessibility constraints (after unlock, local device only)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        let success = status == errSecSuccess
        Task { await AgentAuditLog.shared.record(toolName: "keychain.save", arguments: "key=\(key)", wasConfirmed: false, status: success ? "success" : "failed") }
        return success
    }

    static func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        guard status == errSecSuccess, let data = dataTypeRef as? Data else {
            Task { await AgentAuditLog.shared.record(toolName: "keychain.get", arguments: "key=\(key)", wasConfirmed: false, status: "failed") }
            return nil
        }
        
        Task { await AgentAuditLog.shared.record(toolName: "keychain.get", arguments: "key=\(key)", wasConfirmed: false, status: "success") }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        let success = status == errSecSuccess || status == errSecItemNotFound
        Task { await AgentAuditLog.shared.record(toolName: "keychain.delete", arguments: "key=\(key)", wasConfirmed: false, status: success ? "success" : "failed") }
        return success
    }
}
