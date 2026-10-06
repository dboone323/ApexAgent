import Foundation

// MARK: - Hardening Loop Batch 19: Diff, Launch Config & Repeat Guards
//
// 10 additive formatters/validators. Pure functions only. No behavior changes.

extension DiffStats {
    public var badge: String {
        if additions == 0 && deletions == 0 { return "⚪️ No Changes" }
        if deletions == 0 { return "🟢 Additions Only" }
        if additions == 0 { return "🟠 Deletions Only" }
        return "🔵 Mixed Changes"
    }

    public func formatAsMarkdownRow(filePath: String) -> String {
        "| `\(filePath)` | `+\(additions)` | `-\(deletions)` | \(badge) | `\(summary())` |"
    }
}

extension DiffLine.Kind {
    public var prefix: String {
        switch self {
        case .unchanged: return " "
        case .added: return "+"
        case .deleted: return "-"
        }
    }
}

extension DiffLine {
    public func formatTruncated(maxWidth: Int = 160) -> String {
        let text = text.count > maxWidth ? String(text.prefix(maxWidth)) + "…" : text
        return "\(kind.prefix)\(text)"
    }
}

extension LaunchAgentConfig {
    public func validationError() -> String? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLabel.isEmpty { return "Label must not be empty." }
        let parts = trimmedLabel.split(separator: ".")
        if parts.count < 2 { return "Label should be reverse-DNS (e.g. com.apexagent.daemon)." }
        if programPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "programPath must not be empty."
        }
        return nil
    }

    public var isValid: Bool { validationError() == nil }

    public func formatAsMarkdown() -> String {
        var md = "### 🚀 LaunchAgent: `\(label)`\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Program | `\(programPath)` |\n"
        md += "| Arguments | `\(arguments.joined(separator: " "))` |\n"
        md += "| RunAtLoad | \(runAtLoad ? "✅" : "⚪️") |\n"
        md += "| KeepAlive | \(keepAlive ? "✅" : "⚪️") |\n"
        md += "| Valid | \(isValid ? "✅" : "❌ \(validationError() ?? "")") |\n"
        return md
    }
}
