import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Context compaction reporting, budget health & input validation

@Suite("ContextCompactorTests")
struct ContextCompactorTests {
    @Test func compactionMarkdown() {
        let r = CompactionResult(compactedMessages: [("user", "hi")], summarizedTurnCount: 3, approximateTokensSaved: 500, summary: "digest")
        #expect(r.savedAnything)
        #expect(r.formatAsMarkdown().contains("3 turns"))
        let none = CompactionResult(compactedMessages: [], summarizedTurnCount: 0, approximateTokensSaved: 0, summary: "")
        #expect(!none.savedAnything)
    }

    @Test func budgetHealth() {
        let ok = ContextBudgetBreakdown(systemPromptTokens: 10, userTokens: 10, assistantTokens: 10, totalEstimatedTokens: 30, budgetLimit: 1000)
        #expect(ok.healthBadge.contains("Healthy"))
        #expect(ok.formatHealthMarkdown().contains("30"))
        let over = ContextBudgetBreakdown(systemPromptTokens: 900, userTokens: 900, assistantTokens: 900, totalEstimatedTokens: 2700, budgetLimit: 1000)
        #expect(over.isExceeded)
        #expect(over.healthBadge.contains("Over Budget"))
    }

    @Test func compactionInputValidation() {
        let ok = CompactionInput(messages: [("user", "hi")], maxTokenBudget: 4000, pinnedSystemPrompt: "sys", recentTurnsToPreserve: 2)
        #expect(ok.isValid)
        let bad = CompactionInput(messages: [], maxTokenBudget: -1, pinnedSystemPrompt: "", recentTurnsToPreserve: -1)
        #expect(!bad.isValid)
        #expect(bad.validationError() != nil)
    }

    @Test func calibratedTokenMultiplierProducesHigherTokenCounts() async {
        let codeSample = """
        func executeTask(command: String, options: [String: Any]) async throws -> ExecutionResult {
            guard !command.isEmpty else { throw TaskError.invalidCommand }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            return try await run(process)
        }
        """
        let legacyCount = max(1, codeSample.count / 4)
        let calibratedCount = await ContextCompactor.shared.approximateTokenCount(codeSample)
        #expect(calibratedCount > legacyCount)
        #expect(calibratedCount == Int(ceil(Double(codeSample.count) * 0.35)))
    }
}
