import Foundation
import CryptoKit
import Observation

@Observable @MainActor public final class EphemeralCapabilityManager {
    public static let shared = EphemeralCapabilityManager()
    
    public static let restrictedTools: Set<String> = ["delete_file", "git_operation", "run_shell_command", "patch_file", "write_file", "run_applescript"]
    
    public struct CapabilityToken: Codable, Sendable, Identifiable {
        public let id: UUID
        public let toolName: String
        public let grantedAt: Date
        public let expiresAt: Date
        public let botName: String?
        public let hmac: String
        
        public var isValid: Bool {
            Date() < expiresAt
        }
        
        public var isExpired: Bool {
            !isValid
        }
    }
    
    private var issuedTokens: [UUID: CapabilityToken] = [:]
    private let secretKey: SymmetricKey = SymmetricKey(size: .bits256)
    
    private init() {}
    
    public func issueToken(for toolName: String, botName: String?, ttlSeconds: TimeInterval) -> CapabilityToken {
        let id = UUID()
        let grantedAt = Date()
        let expiresAt = grantedAt.addingTimeInterval(ttlSeconds)
        
        let dataToMac = Data((id.uuidString + toolName + expiresAt.ISO8601Format()).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: dataToMac, using: secretKey)
        let hmacStr = mac.compactMap { String(format: "%02x", $0) }.joined()
        
        let token = CapabilityToken(
            id: id,
            toolName: toolName,
            grantedAt: grantedAt,
            expiresAt: expiresAt,
            botName: botName,
            hmac: hmacStr
        )
        
        issuedTokens[id] = token
        return token
    }
    
    public func consumeToken(id: UUID, toolName: String) -> Bool {
        guard let token = issuedTokens[id] else { return false }
        
        if token.toolName != toolName { return false }
        if !token.isValid { return false }
        
        let dataToMac = Data((token.id.uuidString + token.toolName + token.expiresAt.ISO8601Format()).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: dataToMac, using: secretKey)
        let hmacStr = mac.compactMap { String(format: "%02x", $0) }.joined()
        
        if token.hmac != hmacStr { return false }
        
        issuedTokens.removeValue(forKey: id)
        return true
    }
    
    public var activeTokens: [CapabilityToken] {
        return issuedTokens.values.filter { $0.isValid }.sorted(by: { $0.expiresAt < $1.expiresAt })
    }
    
    public func revokeAll(for toolName: String) {
        let keysToRemove = issuedTokens.filter { $0.value.toolName == toolName }.map { $0.key }
        for key in keysToRemove {
            issuedTokens.removeValue(forKey: key)
        }
    }
    
    public func hasValidToken(botName: String?, toolName: String) -> Bool {
        return issuedTokens.values.contains { token in
            token.toolName == toolName && (token.botName == botName || token.botName == nil || botName == nil) && token.isValid
        }
    }

    // MARK: - Markdown Telemetry

    public func exportActiveTokensMarkdown() -> String {
        let tokens = activeTokens
        guard !tokens.isEmpty else {
            return "No active ephemeral capability tokens issued."
        }

        var md = "### 🔑 Active Ephemeral Capability Grants (\(tokens.count) active)\n\n"
        md += "| Token ID | Scoped Tool | Target Bot | Expiration | Status |\n"
        md += "|---|---|---|---|---|\n"

        let iso = ISO8601DateFormatter()
        for tok in tokens {
            let botStr = tok.botName ?? "Any Bot"
            let expStr = iso.string(from: tok.expiresAt)
            md += "| `\(tok.id.uuidString.prefix(8))` | `\(tok.toolName)` | `\(botStr)` | `\(expStr)` | 🟢 Valid |\n"
        }
        return md
    }

}