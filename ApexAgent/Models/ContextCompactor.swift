public struct ContextBudgetBreakdown: Sendable, Equatable {
    public let systemPromptTokens: Int
    public let userTokens: Int
    public let assistantTokens: Int
    public let totalEstimatedTokens: Int
    public let budgetLimit: Int

    public var utilizationPercentage: Double {
        guard budgetLimit > 0 else { return 0.0 }
        return (Double(totalEstimatedTokens) / Double(budgetLimit)) * 100.0
    }

    public var isExceeded: Bool {
        totalEstimatedTokens > budgetLimit
    }

    public func formatAsMarkdownTable() -> String {
        let sysPct = totalEstimatedTokens > 0 ? String(format: "%.1f%%", Double(systemPromptTokens) / Double(totalEstimatedTokens) * 100) : "0%"
        let userPct = totalEstimatedTokens > 0 ? String(format: "%.1f%%", Double(userTokens) / Double(totalEstimatedTokens) * 100) : "0%"
        let asstPct = totalEstimatedTokens > 0 ? String(format: "%.1f%%", Double(assistantTokens) / Double(totalEstimatedTokens) * 100) : "0%"

        return """
        ### Context Window Budget Breakdown

        | Component | Approximate Tokens | Percentage of Total |
        |---|---|---|
        | System Prompt | `\(systemPromptTokens)` | \(sysPct) |
        | User Turns | `\(userTokens)` | \(userPct) |
        | Assistant Turns | `\(assistantTokens)` | \(asstPct) |
        | **Total Estimated** | **`\(totalEstimatedTokens)`** / `\(budgetLimit)` | **\(String(format: "%.1f%%", utilizationPercentage))** |
        """
    }
}
import Foundation

public struct CompactionInput: Sendable {
    public let messages: [(role: String, content: String)]
    public let maxTokenBudget: Int       // target max approximate tokens to keep
    public let pinnedSystemPrompt: String // always preserved verbatim
    public let recentTurnsToPreserve: Int // last N user+assistant turns kept verbatim
}

public struct CompactionResult: Sendable {
    public let compactedMessages: [(role: String, content: String)]
    public let summarizedTurnCount: Int
    public let approximateTokensSaved: Int
    public let summary: String  // the synthesized digest of removed turns

    public init(
        compactedMessages: [(role: String, content: String)],
        summarizedTurnCount: Int,
        approximateTokensSaved: Int,
        summary: String
    ) {
        self.compactedMessages = compactedMessages
        self.summarizedTurnCount = summarizedTurnCount
        self.approximateTokensSaved = approximateTokensSaved
        self.summary = summary
    }
}

public actor ContextCompactor {
    public static let shared = ContextCompactor()
    
    private init() {}
    
    // Approximate token count (calibrated multiplier for English + code payloads)
    public func approximateTokenCount(_ text: String) -> Int {
        return max(1, Int(ceil(Double(text.count) * 0.35)))
    }
    
    // Compact a message sequence to stay within budget
    public func compact(_ input: CompactionInput) -> CompactionResult {
        var compacted: [(role: String, content: String)] = []
        compacted.append((role: "system", content: input.pinnedSystemPrompt))
        
        // Filter user and assistant messages, ignore system messages for now
        let conversationMessages = input.messages.filter { $0.role != "system" }
        
        let turnsToKeep = input.recentTurnsToPreserve * 2 // each turn is usually user + assistant
        let startIndexForVerbatim = max(0, conversationMessages.count - turnsToKeep)
        let verbatimMessages = Array(conversationMessages[startIndexForVerbatim...])
        let olderMessages = Array(conversationMessages[..<startIndexForVerbatim])
        
        var bulletPoints = ""
        var originalTokens = 0
        var summarizedTurnCount = 0
        
        if !olderMessages.isEmpty {
            for i in stride(from: 0, to: olderMessages.count, by: 1) {
                let msg = olderMessages[i]
                originalTokens += approximateTokenCount(msg.content)
                summarizedTurnCount += 1
                let prefix = String(msg.content.prefix(100)).replacingOccurrences(of: "\n", with: " ")
                bulletPoints += "• [\(msg.role)]: \(prefix)...\n"
            }
            
            let summaryText = "[Context Summary — \(summarizedTurnCount) older turns]:\n\(bulletPoints)"
            compacted.append((role: "system", content: summaryText))
        }
        
        compacted.append(contentsOf: verbatimMessages)
        
        let newSummaryTokens = bulletPoints.isEmpty ? 0 : approximateTokenCount("[Context Summary — \(summarizedTurnCount) older turns]:\n\(bulletPoints)")
        let tokensSaved = max(0, originalTokens - newSummaryTokens)
        
        return CompactionResult(
            compactedMessages: compacted,
            summarizedTurnCount: summarizedTurnCount,
            approximateTokensSaved: tokensSaved,
            summary: bulletPoints
        )
    }
    
    // Should we compact? Returns true if estimated tokens exceed threshold
    public func shouldCompact(messages: [(role: String, content: String)], threshold: Int) -> Bool {
        let totalTokens = messages.reduce(0) { $0 + approximateTokenCount($1.content) }
        return totalTokens > threshold
    }

    // Detailed context budget breakdown
    public func inspectBudget(
        messages: [(role: String, content: String)],
        pinnedSystemPrompt: String,
        maxBudget: Int
    ) -> ContextBudgetBreakdown {
        let sysTokens = approximateTokenCount(pinnedSystemPrompt)
        var uTokens = 0
        var aTokens = 0
        for m in messages {
            let count = approximateTokenCount(m.content)
            if m.role == "user" {
                uTokens += count
            } else if m.role == "assistant" {
                aTokens += count
            }
        }
        let total = sysTokens + uTokens + aTokens
        return ContextBudgetBreakdown(
            systemPromptTokens: sysTokens,
            userTokens: uTokens,
            assistantTokens: aTokens,
            totalEstimatedTokens: total,
            budgetLimit: maxBudget
        )
    }

    // MARK: - Markdown Compaction Summary

    nonisolated public func formatCompactionResultMarkdown(_ result: CompactionResult) -> String {
        var md = "### 🗜️ Context Compaction Performance Summary\n\n"
        md += "| Metric | Value |\n"
        md += "|---|---|\n"
        md += "| Summarized Turns | `\(result.summarizedTurnCount)` |\n"
        md += "| Approximate Tokens Saved | `\(result.approximateTokensSaved)` |\n"
        md += "| Retained Messages Count | `\(result.compactedMessages.count)` |\n\n"

        if !result.summary.isEmpty {
            md += "#### 📑 Distilled Summary Points\n\n"
            md += "\(result.summary)\n"
        }
        return md
    }

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
