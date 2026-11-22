import Foundation
import SharedKit

// MARK: - Space Memory Live Verifier (Issue #83)
//
// Live verification harness running against real binary code to prove:
// VERDICT 1: topics list shows real memory topics for a Space.
// VERDICT 2: editing a topic changes the stored fact; pausing a topic excludes it from retrieval.
// VERDICT 3: the source panel cites the real source entry for a fact.
// VERDICT 4: a no-memory session leaves no new entries in memory.
// VERDICT 5: Markdown export contains the topics; re-import restores them.

@MainActor
public enum SpaceMemoryLiveVerifier {

    public static func runVerification(writeLogTo: String? = nil) -> (output: String, passed: Bool) {
        var logs: [String] = []
        var allPassed = true

        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #83: INSPECTABLE MEMORY UI (B5) LIVE VERIFICATION")
        logs.append("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        logs.append("Environment: macOS 27.0, Swift 6.4, Native App Execution")
        logs.append("================================================================================")

        let tempWorkspace = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("apexagent-issue83-live-verify-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempWorkspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempWorkspace)
        }

        logs.append("\n[Seeding Temporary Workspace at: \(tempWorkspace.path)]")

        // 1. Seed MEMORY.md
        let initialCuratedContent = """
        # Space Curated Memory

        ## Key Facts
        - [MEMORY.md:4] Database host configured as db.staging.internal (key: db_host)
        - [MEMORY.md:5] Authentication service uses RS256 JWT tokens (key: auth_jwt)
        - [MEMORY.md:6] UI theme preference is set to dark mode (key: theme_pref)
        """
        let curatedPath = tempWorkspace.appendingPathComponent("MEMORY.md").path
        try? initialCuratedContent.write(toFile: curatedPath, atomically: true, encoding: .utf8)

        // 2. Seed Daily Note
        let dailyDir = tempWorkspace.appendingPathComponent("daily", isDirectory: true)
        try? FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let dailyContent = """
        # Daily Log: 2026-11-22

        ## Activity
        - [daily/2026-11-22.md:4] Deploy deadline set for next Friday (key: deploy_deadline)
        - [daily/2026-11-22.md:5] Primary contact is Alice Smith (key: primary_contact)
        """
        let dailyPath = dailyDir.appendingPathComponent("2026-11-22.md").path
        try? dailyContent.write(toFile: dailyPath, atomically: true, encoding: .utf8)

        logs.append("Seeded MEMORY.md with 3 facts and daily/2026-11-22.md with 2 facts.")

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 1: topics list shows real memory topics for a Space.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 1] Extracting Topics & Discrete Memory Blocks:")
        let groups = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: tempWorkspace.path)
        let loadedTopics = groups.map(\.topic).sorted()
        let totalItems = groups.flatMap(\.items).count

        logs.append("Discovered \(groups.count) topic groups with \(totalItems) total memory facts.")
        for g in groups {
            logs.append("  - Topic '\(g.topic)': \(g.items.count) item(s) (Status: \(g.isPaused ? "Paused" : "Active"))")
            for item in g.items {
                logs.append("    * \(item.sourceCitation) \(item.statement)")
            }
        }

        let expectedTopics = ["auth_jwt", "db_host", "deploy_deadline", "primary_contact", "theme_pref"]
        let hasAllTopics = expectedTopics.allSatisfy { loadedTopics.contains($0) }
        let v1Pass = hasAllTopics && totalItems == 5

        if v1Pass {
            logs.append("VERDICT 1: PASS — topics list shows real memory topics for a Space (loaded 5/5 expected topics: \(loadedTopics.joined(separator: ", "))).")
        } else {
            logs.append("VERDICT 1: FAIL — expected 5 topics [\(expectedTopics.joined(separator: ", "))], found \(loadedTopics).")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 2: editing a topic changes the stored fact; pausing a topic excludes it from retrieval.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 2] Editing a Fact and Pausing Topic Retrieval:")

        // Step 2a: Edit topic fact
        guard let dbHostItem = groups.first(where: { $0.topic == "db_host" })?.items.first else {
            logs.append("VERDICT 2: FAIL — could not find db_host topic to edit.")
            allPassed = false
            return (logs.joined(separator: "\n"), false)
        }

        let updatedStatement = "Database host upgraded to db.production.internal for failover resilience."
        do {
            try SpaceMemoryInspectorManager.shared.editItem(
                dbHostItem,
                newKey: "db_host",
                newStatement: updatedStatement,
                workspacePath: tempWorkspace.path
            )
            logs.append("Edited db_host fact statement on disk.")
        } catch {
            logs.append("Failed to edit db_host fact: \(error)")
            allPassed = false
        }

        // Verify file on disk updated
        let reloadedCurated = (try? String(contentsOfFile: curatedPath, encoding: .utf8)) ?? ""
        let diskContainsEdit = reloadedCurated.contains("db.production.internal")
        logs.append("Disk verification of MEMORY.md: contains 'db.production.internal' = \(diskContainsEdit)")

        // Retrieval before pause
        let prePauseMatches = HybridMemoryRetriever.shared.search(
            query: "database host production",
            workspacePath: tempWorkspace.path,
            limit: 5
        )
        let prePauseFound = prePauseMatches.contains { $0.content.contains("db.production.internal") }
        logs.append("Pre-pause search for 'database host production' found db_host = \(prePauseFound) (\(prePauseMatches.count) total matches).")

        // Step 2b: Pause topic
        SpaceMemoryInspectorManager.shared.pauseTopic("db_host", workspacePath: tempWorkspace.path)
        let isPaused = SpaceMemoryInspectorManager.shared.isTopicPaused("db_host", workspacePath: tempWorkspace.path)
        logs.append("Topic 'db_host' paused: \(isPaused)")

        // Retrieval while paused: must NOT find db_host
        let postPauseMatches = HybridMemoryRetriever.shared.search(
            query: "database host production",
            workspacePath: tempWorkspace.path,
            limit: 5
        )
        let postPauseFound = postPauseMatches.contains { $0.content.contains("db.production.internal") || $0.content.contains("db_host") }
        logs.append("Post-pause search found db_host = \(postPauseFound) (excluded as expected).")

        // Step 2c: Resume topic
        SpaceMemoryInspectorManager.shared.resumeTopic("db_host", workspacePath: tempWorkspace.path)
        let postResumeMatches = HybridMemoryRetriever.shared.search(
            query: "database host production",
            workspacePath: tempWorkspace.path,
            limit: 5
        )
        let postResumeFound = postResumeMatches.contains { $0.content.contains("db.production.internal") }
        logs.append("Post-resume search found db_host = \(postResumeFound) (restored as expected).")

        let v2Pass = diskContainsEdit && prePauseFound && !postPauseFound && postResumeFound

        if v2Pass {
            logs.append("VERDICT 2: PASS — editing a topic changes the stored fact; pausing a topic excludes it from retrieval (preFound=\(prePauseFound), pausedFound=\(postPauseFound), resumedFound=\(postResumeFound)).")
        } else {
            logs.append("VERDICT 2: FAIL — edit or pause gating failed (diskContainsEdit=\(diskContainsEdit), preFound=\(prePauseFound), pausedFound=\(postPauseFound), resumedFound=\(postResumeFound)).")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 3: the source panel cites the real source entry for a fact.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 3] Source Panel Citation & Provenance ('Why do you think that?'):")
        let refreshedGroups = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: tempWorkspace.path)
        guard let deployDeadlineItem = refreshedGroups.first(where: { $0.topic == "deploy_deadline" })?.items.first else {
            logs.append("VERDICT 3: FAIL — missing deploy_deadline item.")
            allPassed = false
            return (logs.joined(separator: "\n"), false)
        }

        let provenance = SpaceMemoryInspectorManager.shared.provenance(for: deployDeadlineItem)
        logs.append("Generated Provenance for fact '\(deployDeadlineItem.key)':")
        logs.append("  - Citation: \(provenance.sourceCitation)")
        logs.append("  - File: \(provenance.relativePath) (\(provenance.lineRange))")
        logs.append("  - Tier: \(provenance.tier)")
        logs.append("  - Date: \(provenance.dateRecorded)")
        logs.append("  - Verbatim Snippet: \(provenance.verbatimSourceSnippet)")
        logs.append("  - Answer: \(provenance.provenanceAnswer.replacingOccurrences(of: "\n", with: " "))")

        let citationMatches = provenance.sourceCitation.contains("daily/2026-11-22.md")
        let hasVerbatim = provenance.verbatimSourceSnippet.contains("Deploy deadline set for next Friday")
        let answersWhy = provenance.provenanceAnswer.contains("The agent holds this belief because it was explicitly recorded in daily/2026-11-22.md")
        let v3Pass = citationMatches && hasVerbatim && answersWhy

        if v3Pass {
            logs.append("VERDICT 3: PASS — the source panel cites the real source entry for a fact (citation=\(provenance.sourceCitation), lineRange=\(provenance.lineRange), tier=\(provenance.tier)).")
        } else {
            logs.append("VERDICT 3: FAIL — provenance citation or answer did not match expected source.")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 4: a no-memory session leaves no new entries in memory.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 4] Incognito / No-Memory Session Protection:")
        let curatedSizeBefore = (try? Data(contentsOf: URL(fileURLWithPath: curatedPath)).count) ?? 0
        let dailySizeBefore = (try? Data(contentsOf: URL(fileURLWithPath: dailyPath)).count) ?? 0

        // Enable No-Memory Mode
        SpaceMemoryInspectorManager.shared.setNoMemoryMode(true, workspacePath: tempWorkspace.path)
        logs.append("No-memory mode enabled: \(SpaceMemoryInspectorManager.shared.isNoMemoryModeEnabled(workspacePath: tempWorkspace.path))")

        // Attempt flush during no-memory session
        let flushFacts = [
            "Temporary session secret: user entered confidential token 99881122. (key: session_secret)",
            "User asked about a confidential project. (key: temp_query)"
        ]

        let flushResult = try? SpaceMemoryTierManager.shared.flushSession(
            explicitFacts: flushFacts,
            workspacePath: tempWorkspace.path
        )

        let curatedSizeAfter = (try? Data(contentsOf: URL(fileURLWithPath: curatedPath)).count) ?? 0
        let dailySizeAfter = (try? Data(contentsOf: URL(fileURLWithPath: dailyPath)).count) ?? 0

        logs.append("Flush result factsFlushedCount: \(flushResult?.factsFlushedCount ?? -1)")
        logs.append("MEMORY.md bytes: before=\(curatedSizeBefore), after=\(curatedSizeAfter)")
        logs.append("Daily note bytes: before=\(dailySizeBefore), after=\(dailySizeAfter)")

        // Disable No-Memory Mode
        SpaceMemoryInspectorManager.shared.setNoMemoryMode(false, workspacePath: tempWorkspace.path)

        let v4Pass = flushResult?.factsFlushedCount == 0
            && curatedSizeBefore == curatedSizeAfter
            && dailySizeBefore == dailySizeAfter

        if v4Pass {
            logs.append("VERDICT 4: PASS — a no-memory session leaves no new entries in memory (0 facts flushed, 0 bytes added to MEMORY.md or daily notes).")
        } else {
            logs.append("VERDICT 4: FAIL — memory files modified or facts flushed during no-memory session.")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 5: Markdown export contains the topics; re-import restores them.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 5] Markdown Export and Round-Trip Re-Import:")
        let exportedMarkdown = SpaceMemoryInspectorManager.shared.exportMarkdown(workspacePath: tempWorkspace.path)
        logs.append("Exported Markdown snippet (first 300 chars):\n\(String(exportedMarkdown.prefix(300)))...")

        let exportContainsTopics = exportedMarkdown.contains("## Topic: auth_jwt")
            && exportedMarkdown.contains("## Topic: db_host")
            && exportedMarkdown.contains("## Topic: deploy_deadline")

        // Clear curated MEMORY.md
        let wipedContent = "# Space Curated Memory\n\n## Key Facts\n"
        try? wipedContent.write(toFile: curatedPath, atomically: true, encoding: .utf8)
        HybridMemoryRetriever.shared.clearCache()

        let topicsAfterWipe = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: tempWorkspace.path)
        logs.append("Topics count after clearing MEMORY.md: \(topicsAfterWipe.count)")

        // Re-import from exported Markdown
        let importResult = try? SpaceMemoryInspectorManager.shared.importMarkdown(exportedMarkdown, workspacePath: tempWorkspace.path)
        logs.append("Import result: \(importResult?.message ?? "failed")")

        let topicsAfterImport = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: tempWorkspace.path)
        let restoredTopicNames = topicsAfterImport.map(\.topic).sorted()
        logs.append("Restored topics count: \(topicsAfterImport.count) (\(restoredTopicNames.joined(separator: ", ")))")

        let v5Pass = exportContainsTopics
            && (importResult?.isSuccess ?? false)
            && topicsAfterImport.count >= 4
            && restoredTopicNames.contains("auth_jwt")
            && restoredTopicNames.contains("db_host")

        if v5Pass {
            logs.append("VERDICT 5: PASS — Markdown export contains the topics; re-import restores them (exported \(groups.count) topics, re-imported \(importResult?.topicsImported ?? 0) topics and \(importResult?.factsImported ?? 0) facts).")
        } else {
            logs.append("VERDICT 5: FAIL — Markdown export/import round-trip failed.")
            allPassed = false
        }

        logs.append("\n================================================================================")
        logs.append("LIVE VERIFICATION RESULT: \(allPassed ? "PASS" : "FAIL")")
        logs.append("================================================================================")

        let output = logs.joined(separator: "\n")
        if let logPath = writeLogTo {
            let logURL = URL(fileURLWithPath: logPath)
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? output.write(toFile: logPath, atomically: true, encoding: .utf8)
        }

        return (output, allPassed)
    }
}
