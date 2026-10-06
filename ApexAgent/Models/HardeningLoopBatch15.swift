import Foundation

// MARK: - Hardening Loop Batch 15: Memory, Skill & Keychain Reporting
//
// 10 additive formatters/validators. Pure functions only. No behavior changes.

extension CognitiveMemoryEngine.EpisodicEntry {
    public func formatAsMarkdown() -> String {
        var md = "### 🧠 Episode: \(eventType) — \(timestamp)\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Type | `\(eventType)` |\n"
        md += "| Summary | \(String(summary.prefix(250)).replacingOccurrences(of: "|", with: "\\|")) |\n"
        if !metadata.isEmpty {
            md += "| Metadata | `\(metadata.count)` keys |\n"
        }
        return md
    }

    public var isWellFormed: Bool {
        !eventType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension SkillValidationError {
    public var badge: String {
        switch self {
        case .fileNotFound: return "📄 Missing File"
        case .unreadableFile: return "🔒 Unreadable"
        case .invalidJSON: return "🧩 Bad JSON"
        case .missingDescription: return "📝 No Description"
        case .missingScriptPath: return "🔧 No Script"
        case .scriptFileNotFound: return "❌ Script Missing"
        }
    }

    public func formatAsMarkdown() -> String {
        "| \(badge) | \(errorDescription ?? "unknown") |"
    }
}

extension KeychainAuditEntry {
    public var operationBadge: String {
        switch operation {
        case "save": return "💾 Save"
        case "get": return "📖 Read"
        case "delete": return "🗑️ Delete"
        default: return "ℹ️ `\(operation)`"
        }
    }

    public func formatAsMarkdown() -> String {
        "| `\(timestamp)` | \(operationBadge) | `\(key)` | \(success ? "✅" : "❌") |"
    }
}

extension SkillManifestInfo {
    /// Length/emptiness guards before heavier validation runs.
    public func preflightError() -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Skill name must not be empty."
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Skill description must not be empty."
        }
        if scriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Skill scriptPath must not be empty."
        }
        if parameterCount < 0 { return "parameterCount cannot be negative." }
        return nil
    }

    public var isPreflightClean: Bool { preflightError() == nil }
}
