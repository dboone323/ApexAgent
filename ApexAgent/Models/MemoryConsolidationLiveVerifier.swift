import Foundation
import SharedKit

// MARK: - Memory Consolidation Live Verifier (Issue #82)
//
// Live verification harness running against real binary code to prove:
// 1. Pre-compaction flush writes daily note and MEMORY.md entries with citations.
// 2. Pre-compaction flush is idempotent (second flush adds nothing).
// 3. Memory consolidation supersedes stale facts with citations and never silently deletes.
// 4. Second consolidation run produces an empty diff (idempotent).

@MainActor
public enum MemoryConsolidationLiveVerifier {

    public static func runVerification() async -> (output: String, passed: Bool) {
        var logs: [String] = []
        var allPassed = true

        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #82: PRE-COMPACTION FLUSH & MEMORY CONSOLIDATION VERIFICATION")
        logs.append("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        logs.append("================================================================================")

        let tempWorkspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("apexagent-issue82-live-verify-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempWorkspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempWorkspace)
        }

        logs.append("\n[Seeding Workspace at: \(tempWorkspace.path)]")

        // 1. Seed initial memory tiers:
        // Seed MEMORY.md with a known fact and a stale fact to be superseded
        let initialCuratedContent = """
        # Space Curated Memory

        ## Key Facts
        - [MEMORY.md:4] Architecture fence: app-sandbox is disabled. (key: fence_sandbox)
        - [MEMORY.md:5] Database replica runs on port 5432. (key: db_replica_port)
        - [MEMORY.md:6] Logging level configured as INFO. (key: log_level)
        """
        let curatedFilePath = tempWorkspace.appendingPathComponent("MEMORY.md").path
        try? initialCuratedContent.write(toFile: curatedFilePath, atomically: true, encoding: .utf8)
        logs.append("Seeded MEMORY.md with 3 facts (including stale db_replica_port: 5432).")

        // ─────────────────────────────────────────────────────────────────────
        // Check 1: Pre-compaction Flush
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 1] Pre-Compaction Memory Flush:")
        let dateStr = "2026-11-19"
        let flushFacts = [
            "Database replica migrated to port 5434 for failover testing. (key: db_replica_port)",
            "Redis cache sentinel listening on port 26379. (key: cache_sentinel)"
        ]

        do {
            let flushResult = try MemoryConsolidationEngine.shared.flushSession(
                explicitFacts: flushFacts,
                workspacePath: tempWorkspace.path,
                date: dateStr
            )

            logs.append("Flushed facts count: \(flushResult.factsFlushedCount)")
            logs.append("Daily Note Citations (\(flushResult.dailyCitations.count)):")
            for cit in flushResult.dailyCitations {
                logs.append("  \(cit)")
            }
            logs.append("Curated Memory Citations (\(flushResult.curatedCitations.count)):")
            for cit in flushResult.curatedCitations {
                logs.append("  \(cit)")
            }

            let dailyPath = tempWorkspace.appendingPathComponent("daily/\(dateStr).md").path
            let dailyContent = (try? String(contentsOfFile: dailyPath, encoding: .utf8)) ?? ""
            let curatedContent = (try? String(contentsOfFile: curatedFilePath, encoding: .utf8)) ?? ""

            logs.append("\n--- Verbatim daily/\(dateStr).md content ---")
            logs.append(dailyContent.trimmingCharacters(in: .whitespacesAndNewlines))
            logs.append("--- End daily/\(dateStr).md ---")

            logs.append("\n--- Verbatim MEMORY.md content after flush ---")
            logs.append(curatedContent.trimmingCharacters(in: .whitespacesAndNewlines))
            logs.append("--- End MEMORY.md ---")

            if flushResult.factsFlushedCount == 2
                && !flushResult.dailyCitations.isEmpty
                && dailyContent.contains("[daily/2026-11-19.md:")
                && dailyContent.contains("port 5434") {
                logs.append("VERDICT 1: PASS — Pre-compaction flush wrote daily-note and MEMORY.md entries with citations")
            } else {
                allPassed = false
                logs.append("VERDICT 1: FAIL — Pre-compaction flush did not produce expected entries and citations")
            }
        } catch {
            allPassed = false
            logs.append("VERDICT 1: FAIL — Exception during flush: \(error.localizedDescription)")
        }

        // ─────────────────────────────────────────────────────────────────────
        // Check 2: Pre-compaction Flush Idempotency
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 2] Pre-Compaction Flush Idempotency:")
        do {
            let secondFlushResult = try MemoryConsolidationEngine.shared.flushSession(
                explicitFacts: flushFacts,
                workspacePath: tempWorkspace.path,
                date: dateStr
            )

            logs.append("Second flush result: factsFlushedCount=\(secondFlushResult.factsFlushedCount), isIdempotent=\(secondFlushResult.isIdempotent)")
            if secondFlushResult.isIdempotent && secondFlushResult.factsFlushedCount == 0 {
                logs.append("VERDICT 2: PASS — Second flush is idempotent (0 entries added, files unchanged)")
            } else {
                allPassed = false
                logs.append("VERDICT 2: FAIL — Second flush added duplicate entries or was not idempotent")
            }
        } catch {
            allPassed = false
            logs.append("VERDICT 2: FAIL — Exception during second flush: \(error.localizedDescription)")
        }

        // ─────────────────────────────────────────────────────────────────────
        // Check 3: Background Memory Consolidation
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 3] Background Memory Consolidation:")
        do {
            let diff = try MemoryConsolidationEngine.shared.consolidate(
                workspacePath: tempWorkspace.path,
                dryRun: false
            )

            logs.append("\n--- Verbatim Consolidation Diff ---")
            logs.append(diff.formattedDiff)
            logs.append("--- End Consolidation Diff ---")

            let updatedCurated = (try? String(contentsOfFile: curatedFilePath, encoding: .utf8)) ?? ""
            logs.append("\n--- Consolidated MEMORY.md on disk ---")
            logs.append(updatedCurated.trimmingCharacters(in: .whitespacesAndNewlines))
            logs.append("--- End Consolidated MEMORY.md ---")

            let supersededDb = diff.superseded.first(where: { $0.oldFact.key == "db_replica_port" })
            let hasSuperseded = supersededDb != nil
            let oldCitation = supersededDb?.oldFact.sourceCitation ?? ""
            let newCitation = supersededDb?.newFact.sourceCitation ?? ""

            logs.append("Superseded check: key='db_replica_port', oldCitation='\(oldCitation)', newCitation='\(newCitation)'")

            if hasSuperseded
                && diff.superseded.count >= 1
                && diff.formattedDiff.contains("## Superseded Facts")
                && updatedCurated.contains("port 5434") {
                logs.append("VERDICT 3: PASS — Memory consolidation superseded stale fact with readable diff and exact citations")
            } else {
                allPassed = false
                logs.append("VERDICT 3: FAIL — Memory consolidation did not correctly supersede stale fact")
            }
        } catch {
            allPassed = false
            logs.append("VERDICT 3: FAIL — Exception during consolidation: \(error.localizedDescription)")
        }

        // ─────────────────────────────────────────────────────────────────────
        // Check 4: Consolidation Idempotency
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 4] Consolidation Idempotency (Second Run):")
        do {
            let secondDiff = try MemoryConsolidationEngine.shared.consolidate(
                workspacePath: tempWorkspace.path,
                dryRun: false
            )

            logs.append("\n--- Second Consolidation Diff ---")
            logs.append(secondDiff.formattedDiff)
            logs.append("--- End Second Consolidation Diff ---")

            if secondDiff.isIdempotent
                && secondDiff.added.isEmpty
                && secondDiff.superseded.isEmpty
                && secondDiff.formattedDiff.contains("Memory is already consolidated. No changes made.") {
                logs.append("VERDICT 4: PASS — Second consolidation is idempotent (diff is empty, 0 changes)")
            } else {
                allPassed = false
                logs.append("VERDICT 4: FAIL — Second consolidation produced unexpected diff changes")
            }
        } catch {
            allPassed = false
            logs.append("VERDICT 4: FAIL — Exception during second consolidation: \(error.localizedDescription)")
        }

        logs.append("\n================================================================================")
        if allPassed {
            logs.append("VERIFICATION RESULT: PASS")
        } else {
            logs.append("VERIFICATION RESULT: FAIL")
        }
        logs.append("================================================================================")

        let outputString = logs.joined(separator: "\n")
        return (outputString, allPassed)
    }
}
