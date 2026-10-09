import Foundation
import Testing
import SharedKit
@testable import ApexAgentCore

@Suite("Memory Compaction & Vector Integrity Tests")
struct MemoryCompactionAuditorTests {
    @Test("Audits compliant bot memory with zero violations and full score")
    func compliantMemoryAudit() {
        let botId = UUID()
        let working = "User asked for Swift code refactoring. Successfully analyzed AST."

        let episodes = [
            CognitiveMemoryEngine.EpisodicEntry(
                botId: botId,
                eventType: "task_complete",
                summary: "Successfully refactored codebase AST parser",
                metadata: ["durationMs": "150"]
            )
        ]

        let vector = CognitiveMemoryEngine.deterministicHashEmbedding(for: "AST parser refactor", dimensions: 64)
        let vectorData = CognitiveMemoryEngine.encodeEmbedding(vector)
        let entry = AgentMemoryEntry(
            content: "AST parser refactor",
            embedding: vectorData,
            source: .userChat,
            relevanceScore: 1.0,
            tags: ["ast", "parser"]
        )

        let report = MemoryCompactionAuditor.audit(
            bots: [(botId: botId, workingContext: working, episodes: episodes, memoryEntries: [entry])]
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)
        #expect(report.evaluatedBots == 1)

        let md = report.toMarkdown()
        #expect(md.contains("PASS"))
        #expect(md.contains("Compaction Summaries"))
    }

    @Test("Detects working memory bloat exceeding policy threshold")
    func workingMemoryBloatAudit() {
        let botId = UUID()
        // 70 KB of text
        let bloatedContext = String(repeating: "Large context token buffer... ", count: 2500)
        let violations = MemoryCompactionAuditor.auditWorkingMemory(
            contexts: [botId: bloatedContext],
            policy: MemoryCompactionPolicy(maxWorkingContextBytes: 64 * 1024)
        )

        #expect(!violations.isEmpty)
        let hasBloat = violations.contains { $0.ruleId == "working_memory_bloat" }
        #expect(hasBloat)
    }

    @Test("Detects vector dimensional mismatch and zero magnitude")
    func vectorIntegrityDefectsAudit() {
        // Mismatch test: 32 dimensions instead of 64
        let shortVector = [Double](repeating: 0.1, count: 32)
        let shortData = CognitiveMemoryEngine.encodeEmbedding(shortVector)
        let entryMismatch = AgentMemoryEntry(content: "Short vector", embedding: shortData, source: .userChat)

        let violationsMismatch = MemoryCompactionAuditor.auditVectorIntegrity(
            entry: entryMismatch,
            expectedDimensions: 64
        )
        let hasMismatch = violationsMismatch.contains { $0.ruleId == "vector_dimension_mismatch" }
        #expect(hasMismatch)

        // Zero magnitude test
        let zeroVector = [Double](repeating: 0.0, count: 64)
        let zeroData = CognitiveMemoryEngine.encodeEmbedding(zeroVector)
        let entryZero = AgentMemoryEntry(content: "Zero vector", embedding: zeroData, source: .userChat)

        let violationsZero = MemoryCompactionAuditor.auditVectorIntegrity(
            entry: entryZero,
            expectedDimensions: 64
        )
        let hasZero = violationsZero.contains { $0.ruleId == "vector_zero_magnitude" }
        #expect(hasZero)
    }

    @Test("Correctly compacts episodic memory and preserves chronological bounds")
    func episodicCompactionExecution() {
        let botId = UUID()
        var episodes: [CognitiveMemoryEngine.EpisodicEntry] = []
        let baseTime = Date(timeIntervalSince1970: 1700000000)

        for i in 0..<100 {
            episodes.append(
                CognitiveMemoryEngine.EpisodicEntry(
                    id: UUID(),
                    timestamp: baseTime.addingTimeInterval(Double(i * 60)),
                    botId: botId,
                    eventType: "step_\(i)",
                    summary: "Executed step \(i) of pipeline"
                )
            )
        }

        let (retained, archived) = MemoryCompactionAuditor.compactEpisodes(episodes, maxLimit: 40)
        #expect(retained.count == 40)
        #expect(archived.count == 60)

        // Retained should be the most recent 40 entries
        #expect(retained.first?.eventType == "step_60")
        #expect(retained.last?.eventType == "step_99")
        // Archived should be the oldest 60 entries
        #expect(archived.first?.eventType == "step_0")
        #expect(archived.last?.eventType == "step_59")
    }

    @Test("Detects malformed episodic entry with blank summary")
    func malformedEpisodicEntryAudit() {
        let botId = UUID()
        let malformed = CognitiveMemoryEngine.EpisodicEntry(
            botId: botId,
            eventType: "action",
            summary: "   " // Blank summary
        )

        let (violations, _) = MemoryCompactionAuditor.auditBotMemory(
            botId: botId,
            workingContext: "clean context",
            episodes: [malformed],
            memoryEntries: []
        )

        let hasMalformed = violations.contains { $0.ruleId == "malformed_episodic_entry" }
        #expect(hasMalformed)
    }
}
