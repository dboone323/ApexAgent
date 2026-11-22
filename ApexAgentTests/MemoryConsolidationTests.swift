import Foundation
import SwiftData
import Testing
@testable import ApexAgentCore

@Suite("Memory Consolidation & Pre-Compaction Flush Tests (Issue #82)")
struct MemoryConsolidationTests {

    private func createTempWorkspace(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // MARK: - 1. Flush Writes Correct Daily-Note Entries With Citations

    @Test("Pre-compaction flush: writes correct daily-note and MEMORY.md entries with citations")
    @MainActor
    func testFlushWritesDailyNoteWithCitations() throws {
        let ws = try createTempWorkspace(prefix: "test-flush-citations")
        defer { try? FileManager.default.removeItem(at: ws) }

        let engine = MemoryConsolidationEngine.shared
        let dateStr = "2026-11-19"
        let facts = [
            "Production database replica runs on port 5434. (key: db_replica_port)",
            "Redis cache sentinel is enabled on port 26379. (key: redis_sentinel)"
        ]

        let result = try engine.flushSession(
            explicitFacts: facts,
            workspacePath: ws.path,
            date: dateStr
        )

        #expect(result.factsFlushedCount == 2)
        #expect(!result.isIdempotent)
        #expect(result.dailyCitations.count == 2)
        #expect(result.curatedCitations.count == 2)

        // Verify daily note file on disk
        let dailyPath = ws.appendingPathComponent("daily/\(dateStr).md").path
        #expect(FileManager.default.fileExists(atPath: dailyPath))
        let dailyContent = try String(contentsOfFile: dailyPath, encoding: .utf8)

        #expect(dailyContent.contains("[daily/2026-11-19.md:"))
        #expect(dailyContent.contains("Production database replica runs on port 5434."))
        #expect(dailyContent.contains("Redis cache sentinel is enabled on port 26379."))

        // Verify curated MEMORY.md on disk
        let curatedPath = ws.appendingPathComponent("MEMORY.md").path
        #expect(FileManager.default.fileExists(atPath: curatedPath))
        let curatedContent = try String(contentsOfFile: curatedPath, encoding: .utf8)

        #expect(curatedContent.contains("[MEMORY.md:"))
        #expect(curatedContent.contains("Production database replica runs on port 5434."))
        #expect(curatedContent.contains("Redis cache sentinel is enabled on port 26379."))

        // Exact line verification: verify citations match real line numbers
        let dailyLines = dailyContent.components(separatedBy: "\n")
        for cit in result.dailyCitations {
            guard let lineNumStr = cit.split(separator: ":").last?.dropLast(),
                  let lineNum = Int(lineNumStr) else { continue }
            #expect(lineNum <= dailyLines.count)
            let actualLine = dailyLines[lineNum - 1]
            #expect(actualLine.contains(cit))
        }
    }

    // MARK: - 2. Flush Idempotency: Second Flush Adds Nothing

    @Test("Pre-compaction flush: flush is idempotent and second flush adds nothing")
    @MainActor
    func testFlushIsIdempotentSecondFlushAddsNothing() throws {
        let ws = try createTempWorkspace(prefix: "test-flush-idempotent")
        defer { try? FileManager.default.removeItem(at: ws) }

        let engine = MemoryConsolidationEngine.shared
        let dateStr = "2026-11-19"
        let facts = [
            "Application sandbox is disabled per standing architecture fence. (key: sandbox_fence)"
        ]

        // First flush
        let firstResult = try engine.flushSession(
            explicitFacts: facts,
            workspacePath: ws.path,
            date: dateStr
        )
        #expect(firstResult.factsFlushedCount == 1)
        #expect(!firstResult.isIdempotent)

        let dailyPath = ws.appendingPathComponent("daily/\(dateStr).md").path
        let curatedPath = ws.appendingPathComponent("MEMORY.md").path

        let dailyContentBefore = try String(contentsOfFile: dailyPath, encoding: .utf8)
        let curatedContentBefore = try String(contentsOfFile: curatedPath, encoding: .utf8)

        // Second flush of the exact same fact
        let secondResult = try engine.flushSession(
            explicitFacts: facts,
            workspacePath: ws.path,
            date: dateStr
        )

        #expect(secondResult.factsFlushedCount == 0)
        #expect(secondResult.isIdempotent)
        #expect(secondResult.dailyCitations.isEmpty)
        #expect(secondResult.curatedCitations.isEmpty)

        let dailyContentAfter = try String(contentsOfFile: dailyPath, encoding: .utf8)
        let curatedContentAfter = try String(contentsOfFile: curatedPath, encoding: .utf8)

        // Content must be byte-for-byte identical
        #expect(dailyContentBefore == dailyContentAfter)
        #expect(curatedContentBefore == curatedContentAfter)
    }

    // MARK: - 3. Consolidation Supersedes Stale Fact And Records In Diff

    @Test("Memory consolidation: supersedes stale fact and records it in readable diff")
    @MainActor
    func testConsolidationSupersedesStaleFactAndRecordsInDiff() throws {
        let ws = try createTempWorkspace(prefix: "test-consolidation-supersede")
        defer { try? FileManager.default.removeItem(at: ws) }

        let engine = MemoryConsolidationEngine.shared

        // Seed older curated memory with stale fact
        let staleMemoryContent = """
        # Space Curated Memory

        ## Key Facts
        - [MEMORY.md:4] Production database replica runs on port 5432. (key: db_replica_port)
        - [MEMORY.md:5] Cache cluster configured on port 6379. (key: cache_port)
        """
        let curatedPath = ws.appendingPathComponent("MEMORY.md").path
        try staleMemoryContent.write(toFile: curatedPath, atomically: true, encoding: .utf8)

        // Seed newer daily note with updated fact
        let dailyDir = ws.appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let newerDailyContent = """
        # Daily Note: 2026-11-19
        Tags: #memory #ops

        ## Actions
        - [daily/2026-11-19.md:5] Production database replica migrated to port 5434. (key: db_replica_port)
        """
        let dailyPath = dailyDir.appendingPathComponent("2026-11-19.md").path
        try newerDailyContent.write(toFile: dailyPath, atomically: true, encoding: .utf8)

        // Run consolidation
        let diff = try engine.consolidate(workspacePath: ws.path)

        #expect(!diff.isIdempotent)
        #expect(diff.superseded.count == 1)

        guard let pair = diff.superseded.first else {
            return
        }
        #expect(pair.oldFact.key == "db_replica_port")
        #expect(pair.oldFact.value.contains("5432"))
        #expect(pair.oldFact.sourceCitation == "[MEMORY.md:4]")

        #expect(pair.newFact.key == "db_replica_port")
        #expect(pair.newFact.value.contains("5434"))
        #expect(pair.newFact.sourceCitation == "[daily/2026-11-19.md:5]")

        // Check formatted diff output
        #expect(diff.formattedDiff.contains("## Superseded Facts (1)"))
        #expect(diff.formattedDiff.contains("[MEMORY.md:4] (Superseded by [daily/2026-11-19.md:5])"))
        #expect(diff.formattedDiff.contains("OLD: Production database replica runs on port 5432."))
        #expect(diff.formattedDiff.contains("NEW: Production database replica migrated to port 5434."))

        // Verify updated MEMORY.md on disk reflects the new port 5434 and records supersession
        let updatedCurated = try String(contentsOfFile: curatedPath, encoding: .utf8)
        #expect(updatedCurated.contains("port 5434"))
        #expect(updatedCurated.contains("[Supersedes: [MEMORY.md:4]]"))
    }

    // MARK: - 4. Consolidation Never Silently Deletes

    @Test("Memory consolidation: never silently deletes any facts")
    @MainActor
    func testConsolidationNeverSilentlyDeletes() throws {
        let ws = try createTempWorkspace(prefix: "test-never-delete")
        defer { try? FileManager.default.removeItem(at: ws) }

        let engine = MemoryConsolidationEngine.shared

        // Seed 3 facts in curated memory
        let curatedContent = """
        # Space Curated Memory

        ## Key Facts
        - [MEMORY.md:4] Alpha setting enabled. (key: config_alpha)
        - [MEMORY.md:5] Beta port is 8080. (key: config_beta)
        - [MEMORY.md:6] Gamma flag is active. (key: config_gamma)
        """
        let curatedPath = ws.appendingPathComponent("MEMORY.md").path
        try curatedContent.write(toFile: curatedPath, atomically: true, encoding: .utf8)

        // Seed newer daily note updating only Beta
        let dailyDir = ws.appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let dailyContent = """
        # Daily Note: 2026-11-19
        ## Notes
        - [daily/2026-11-19.md:4] Beta port updated to 8081. (key: config_beta)
        """
        let dailyPath = dailyDir.appendingPathComponent("2026-11-19.md").path
        try dailyContent.write(toFile: dailyPath, atomically: true, encoding: .utf8)

        let diff = try engine.consolidate(workspacePath: ws.path)

        // Verify every initial fact is accounted for (either unchanged or explicitly superseded)
        let allReportedKeys = Set(diff.unchanged.map(\.key) + diff.superseded.map(\.oldFact.key))
        #expect(allReportedKeys.contains("config_alpha"))
        #expect(allReportedKeys.contains("config_beta"))
        #expect(allReportedKeys.contains("config_gamma"))

        // Check that updated MEMORY.md still retains alpha, beta, and gamma
        let updatedCurated = try String(contentsOfFile: curatedPath, encoding: .utf8)
        #expect(updatedCurated.contains("config_alpha"))
        #expect(updatedCurated.contains("config_beta"))
        #expect(updatedCurated.contains("config_gamma"))
        #expect(updatedCurated.contains("Superseded History"))
    }

    // MARK: - 5. Diff Lists Added, Updated, Superseded With Citations

    @Test("Memory consolidation: diff lists added, updated, and superseded facts with citations")
    @MainActor
    func testConsolidationDiffListsAddedUpdatedSupersededWithCitations() throws {
        let ws = try createTempWorkspace(prefix: "test-diff-breakdown")
        defer { try? FileManager.default.removeItem(at: ws) }

        let engine = MemoryConsolidationEngine.shared

        // Initial MEMORY.md: 1 unchanged fact, 1 stale fact
        let initialCurated = """
        # Space Curated Memory

        ## Key Facts
        - [MEMORY.md:4] Architecture: Swift 6 concurrency strictly enforced. (key: arch_swift6)
        - [MEMORY.md:5] Worker pool thread count is 4. (key: worker_threads)
        """
        let curatedPath = ws.appendingPathComponent("MEMORY.md").path
        try initialCurated.write(toFile: curatedPath, atomically: true, encoding: .utf8)

        // Daily note: updates worker_threads (superseded), adds new telemetry_endpoint (added)
        let dailyDir = ws.appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let dailyContent = """
        # Daily Note: 2026-11-19
        ## Updates
        - [daily/2026-11-19.md:4] Worker pool thread count increased to 8. (key: worker_threads)
        - [daily/2026-11-19.md:5] Telemetry collector endpoint set to https://telemetry.apex.local:8443. (key: telemetry_endpoint)
        """
        let dailyPath = dailyDir.appendingPathComponent("2026-11-19.md").path
        try dailyContent.write(toFile: dailyPath, atomically: true, encoding: .utf8)

        let diff = try engine.consolidate(workspacePath: ws.path)

        #expect(diff.totalFactsAnalyzed == 4)
        #expect(diff.superseded.count == 1)
        #expect(diff.added.count == 1)
        #expect(diff.unchanged.count >= 1)

        // Added fact citation check
        guard let addedFact = diff.added.first else {
            return
        }
        #expect(addedFact.key == "telemetry_endpoint")
        #expect(addedFact.sourceCitation == "[daily/2026-11-19.md:5]")

        // Superseded fact citations check
        guard let supPair = diff.superseded.first else {
            return
        }
        #expect(supPair.oldFact.sourceCitation == "[MEMORY.md:5]")
        #expect(supPair.newFact.sourceCitation == "[daily/2026-11-19.md:4]")

        // Unchanged fact citation check
        let unchangedFact = diff.unchanged.first(where: { $0.key == "arch_swift6" })
        #expect(unchangedFact?.sourceCitation == "[MEMORY.md:4]")

        // Second run must be completely idempotent
        let secondDiff = try engine.consolidate(workspacePath: ws.path)
        #expect(secondDiff.isIdempotent)
        #expect(secondDiff.added.isEmpty)
        #expect(secondDiff.superseded.isEmpty)
        #expect(secondDiff.formattedDiff.contains("Memory is already consolidated. No changes made."))
    }

    // MARK: - 6. Tool Registration & Execution Verification

    @Test("Memory tools: memory_flush and memory_consolidate tools execute cleanly")
    @MainActor
    func testMemoryToolsExecution() async throws {
        let ws = try createTempWorkspace(prefix: "test-tools-exec")
        defer { try? FileManager.default.removeItem(at: ws) }

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = ws.path

        let flushTool = MemoryFlushTool(orchestrator: orchestrator)
        let consolidateTool = MemoryConsolidateTool(orchestrator: orchestrator)

        #expect(flushTool.name == "memory_flush")
        #expect(consolidateTool.name == "memory_consolidate")

        // Call flush tool with explicit facts
        let flushArgs = MemoryFlushTool.Arguments(
            facts: ["Security fence: ad-hoc signing with app-sandbox disabled. (key: signing_fence)"],
            sessionSummary: nil,
            date: "2026-11-19"
        )
        let flushOutput = try await flushTool.call(arguments: flushArgs)
        #expect(flushOutput.contains("Pre-Compaction Memory Flush Successful"))
        #expect(flushOutput.contains("MEMORY.md"))

        // Call consolidate tool
        let consArgs = MemoryConsolidateTool.Arguments(dryRun: true)
        let consOutput = try await consolidateTool.call(arguments: consArgs)
        #expect(consOutput.contains("=== MEMORY CONSOLIDATION DIFF ==="))
    }
}
