import Foundation

// MARK: - Hardening Loop Batch 18: Rollback, Compaction & Budget Reporting
//
// 10 additive formatters/validators. Pure functions only. No behavior changes.

extension FileRollbackSnapshot {
    public func formatAsMarkdown() -> String {
        var md = "### 🗂️ Rollback Snapshot `\(originalPath)`\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Original | `\(originalPath)` |\n"
        md += "| Snapshot | `\(snapshotPath)` |\n"
        md += "| Taken | `\(timestamp)` |\n"
        md += "| Size | `\(sizeBytes)` bytes |\n"
        return md
    }

    public var isNonEmpty: Bool { sizeBytes > 0 }
}

extension CompactionResult {
    public func formatAsMarkdown() -> String {
        var md = "### 🗜️ Context Compaction: \(summarizedTurnCount) turns summarized\n\n"
        md += "| Metric | Value |\n"
        md += "|---|---|\n"
        md += "| Turns Summarized | `\(summarizedTurnCount)` |\n"
        md += "| Tokens Saved | `\(approximateTokensSaved)` |\n"
        md += "| Kept Messages | `\(compactedMessages.count)` |\n"
        if !summary.isEmpty {
            md += "| Summary | \(String(summary.prefix(250)).replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
        return md
    }

    public var savedAnything: Bool { approximateTokensSaved > 0 }
}

extension ContextBudgetBreakdown {
    public var healthBadge: String {
        if isExceeded { return "🔴 Over Budget" }
        if utilizationPercentage > 85 { return "🟡 Near Limit" }
        return "🟢 Healthy"
    }

    public func formatHealthMarkdown() -> String {
        "| Budget | `\(totalEstimatedTokens)` / `\(budgetLimit)` | \(healthBadge) (`\(String(format: "%.1f%%", utilizationPercentage))`) |"
    }
}

extension CompactionInput {
    public func validationError() -> String? {
        if maxTokenBudget <= 0 { return "maxTokenBudget must be positive." }
        if recentTurnsToPreserve < 0 { return "recentTurnsToPreserve cannot be negative." }
        if messages.isEmpty { return "No messages to compact." }
        return nil
    }

    public var isValid: Bool { validationError() == nil }
}
