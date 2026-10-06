import Testing
import Foundation
@testable import ApexAgentCore

@Suite("HardeningLoopBatch18Tests")
struct HardeningLoopBatch18Tests {
    @Test func testSnapshotMarkdown() {
        let s = FileRollbackSnapshot(originalPath: "/tmp/a.txt", snapshotPath: "/tmp/a.bak", sizeBytes: 42)
        #expect(s.isNonEmpty)
        #expect(s.formatAsMarkdown().contains("a.txt"))
        let empty = FileRollbackSnapshot(originalPath: "/x", snapshotPath: "/y", sizeBytes: 0)
        #expect(!empty.isNonEmpty)
    }

    @Test func testCompactionMarkdown() {
        let r = CompactionResult(compactedMessages: [("user", "hi")], summarizedTurnCount: 3, approximateTokensSaved: 500, summary: "digest")
        #expect(r.savedAnything)
        #expect(r.formatAsMarkdown().contains("3 turns"))
        let none = CompactionResult(compactedMessages: [], summarizedTurnCount: 0, approximateTokensSaved: 0, summary: "")
        #expect(!none.savedAnything)
    }

    @Test func testBudgetHealth() {
        let ok = ContextBudgetBreakdown(systemPromptTokens: 10, userTokens: 10, assistantTokens: 10, totalEstimatedTokens: 30, budgetLimit: 1000)
        #expect(ok.healthBadge.contains("Healthy"))
        #expect(ok.formatHealthMarkdown().contains("30"))
        let over = ContextBudgetBreakdown(systemPromptTokens: 900, userTokens: 900, assistantTokens: 900, totalEstimatedTokens: 2700, budgetLimit: 1000)
        #expect(over.isExceeded)
        #expect(over.healthBadge.contains("Over Budget"))
    }

    @Test func testCompactionInputValidation() {
        let ok = CompactionInput(messages: [("user", "hi")], maxTokenBudget: 4000, pinnedSystemPrompt: "sys", recentTurnsToPreserve: 2)
        #expect(ok.isValid)
        let bad = CompactionInput(messages: [], maxTokenBudget: -1, pinnedSystemPrompt: "", recentTurnsToPreserve: -1)
        #expect(!bad.isValid)
        #expect(bad.validationError() != nil)
    }
}
