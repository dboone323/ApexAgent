import Foundation

// MARK: - Hardening Loop Batch 14: Group Chat, Diagnostics & Capability Guards
//
// 10 additive validators/summarizers. Pure functions only. No behavior changes.

extension GroupToolPermission {
    public var badge: String {
        switch self {
        case .allowed: return "🟢 Allowed"
        case .needsApproval: return "🟡 Needs Approval"
        case .denied: return "🔴 Denied"
        }
    }

    public var isActionable: Bool {
        switch self {
        case .allowed, .needsApproval: return true
        case .denied: return false
        }
    }
}

extension DiagnosticStatus {
    public var badge: String {
        switch self {
        case .pass: return "✅ Pass"
        case .warning: return "⚠️ Warning"
        case .fail: return "❌ Fail"
        }
    }
}

extension DiagnosticItem {
    public func formatAsMarkdown() -> String {
        "| **\(name)** | `\(category)` | \(status.badge) | \(message.prefix(200)) |"
    }

    public static func summarizeAsMarkdown(_ items: [DiagnosticItem]) -> String {
        guard !items.isEmpty else { return "No diagnostic results recorded." }
        let fails = items.filter { $0.status == .fail }.count
        let warns = items.filter { $0.status == .warning }.count
        var md = "### 🩺 Diagnostics Summary: \(items.count) checks (\(fails) failing, \(warns) warnings)\n\n"
        md += "| Check | Category | Status | Message |\n"
        md += "|---|---|---|---|\n"
        for item in items { md += item.formatAsMarkdown() + "\n" }
        return md
    }
}

extension EphemeralCapabilityManager.CapabilityToken {
    /// Remaining lifetime, clamped at zero once expired.
    public var remainingLifetime: TimeInterval {
        max(0, expiresAt.timeIntervalSince(Date()))
    }

    public func formatAsMarkdown(redacted: Bool = true) -> String {
        var md = "### 🔑 Capability Token `\(id.uuidString.prefix(8))`\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Tool | `\(toolName)` |\n"
        md += "| Bot | `\(botName ?? "any")` |\n"
        md += "| Status | \(isValid ? "🟢 Valid" : "⚪️ Expired") |\n"
        md += "| Remaining | `\(Int(remainingLifetime))s` |\n"
        md += "| HMAC | `\(redacted ? String(hmac.prefix(8)) + "••••" : hmac)` |\n"
        return md
    }
}

extension EphemeralCapabilityManager {
    /// Validates a TTL before issuance. Nil = acceptable.
    public static func ttlError(_ ttlSeconds: TimeInterval) -> String? {
        if ttlSeconds <= 0 { return "TTL must be positive." }
        if ttlSeconds > 3600 { return "TTL exceeds 1 hour cap; use revokeAll for long scopes." }
        return nil
    }

    /// Tool-name gate: only restricted tools need capability tokens.
    public static func requiresToken(toolName: String) -> Bool {
        restrictedTools.contains(toolName)
    }
}

extension DefaultGroupToolAllowlist {
    /// Allowlist membership probe without exposing the set for mutation.
    public static func isAllowed(_ tool: String) -> Bool {
        set.contains(tool)
    }
}
