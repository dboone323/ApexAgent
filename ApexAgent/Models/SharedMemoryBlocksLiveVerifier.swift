import Foundation
import SharedKit

// MARK: - Shared Memory Blocks Live Verifier (Issue #84 / B6)
//
// Live verification harness running against real binary code to prove:
// VERDICT 1: Agent A writes a block; agent B in the same Space reads the same content.
// VERDICT 2: A conflicting write from B produces a conflict record naming both writers.
// VERDICT 3: The losing value is still recoverable from the conflict record.
// VERDICT 4: An agent in a different Space cannot read the block.
// VERDICT 5: Blocks survive a restart (fresh instance reads them back).

@MainActor
public enum SharedMemoryBlocksLiveVerifier {

    public static func runVerification(writeLogTo: String? = nil) -> (output: String, passed: Bool) {
        var logs: [String] = []
        var allPassed = true

        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #84: SHARED MEMORY BLOCKS ACROSS AGENTS (B6) LIVE VERIFICATION")
        logs.append("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        logs.append("Environment: macOS 27.0, Swift 6.4, Native App Execution")
        logs.append("================================================================================")

        let tempWorkspace = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("apexagent-issue84-live-verify-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempWorkspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempWorkspace)
        }

        logs.append("\n[Seeding Temporary Storage at: \(tempWorkspace.path)]")

        let spaceAlpha = "space-alpha-84"
        let spaceBeta = "space-beta-84"
        let blockId = "sprint_mission"

        let service = SharedMemoryBlockService(storageDirectory: tempWorkspace)

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 1: Agent A writes a block; agent B in the same Space reads the same content.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 1] Agent A writes a shared block in Space Alpha; Agent B reads it:")
        let initialPayload = "Sprint 42 Mission: Build distributed multi-agent shared memory."
        let writeResultA = service.writeBlock(
            spaceId: spaceAlpha,
            blockId: blockId,
            content: initialPayload,
            writerId: "agent_architect_A",
            expectedVersion: nil,
            workspacePath: tempWorkspace.path
        )

        guard case .success(let blockA) = writeResultA else {
            logs.append("VERDICT 1: FAIL — Agent A initial write failed: \(writeResultA)")
            allPassed = false
            return finalize(logs: logs, passed: false, writeLogTo: writeLogTo)
        }

        logs.append("Agent A created block '\(blockA.id)' at revision v\(blockA.version) with content: '\(blockA.content)'.")

        let readByAgentB = service.readBlock(spaceId: spaceAlpha, blockId: blockId, workspacePath: tempWorkspace.path)
        let v1Pass = (readByAgentB != nil) &&
                     (readByAgentB?.content == initialPayload) &&
                     (readByAgentB?.version == 1) &&
                     (readByAgentB?.writerId == "agent_architect_A")

        if v1Pass {
            logs.append("Agent B successfully read the exact block content from Space Alpha.")
            logs.append("VERDICT 1: PASS — Agent A writes a block; agent B in the same Space reads the same content.")
        } else {
            logs.append("VERDICT 1: FAIL — Agent B could not read or received mismatching content: \(String(describing: readByAgentB)).")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 2: A conflicting write from B produces a conflict record naming both writers.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 2] Conflicting write detection with writer attribution:")
        // First, Agent A advances the block to version 2
        let v2Payload = "Sprint 42 Mission Updated: Integrate hybrid retriever."
        let writeResultA2 = service.writeBlock(
            spaceId: spaceAlpha,
            blockId: blockId,
            content: v2Payload,
            writerId: "agent_architect_A",
            expectedVersion: 1,
            workspacePath: tempWorkspace.path
        )
        guard case .success(let blockV2) = writeResultA2 else {
            logs.append("VERDICT 2: FAIL — Precondition update to v2 failed.")
            allPassed = false
            return finalize(logs: logs, passed: false, writeLogTo: writeLogTo)
        }
        logs.append("Agent A advanced block to v\(blockV2.version).")

        // Now, Agent B attempts to write based on stale version 1
        let stalePayloadB = "Sprint 42 Mission (Conflicting): Focus solely on UI views."
        let writeResultB = service.writeBlock(
            spaceId: spaceAlpha,
            blockId: blockId,
            content: stalePayloadB,
            writerId: "agent_developer_B",
            expectedVersion: 1, // Stale! Current is v2
            workspacePath: tempWorkspace.path
        )

        var v2Pass = false
        var capturedConflict: SharedMemoryConflict?
        if case .conflict(let conflict, let current) = writeResultB {
            capturedConflict = conflict
            logs.append("Conflict successfully caught! Winning writer: '\(conflict.winningWriterId)', Conflicting writer: '\(conflict.conflictingWriterId)'.")
            logs.append("Reason: \(conflict.reason)")
            v2Pass = (conflict.winningWriterId == "agent_architect_A") &&
                     (conflict.conflictingWriterId == "agent_developer_B") &&
                     (current.version == 2) &&
                     (conflict.baseVersion == 1)
        }

        if v2Pass {
            logs.append("VERDICT 2: PASS — A conflicting write from B produces a conflict record naming both writers.")
        } else {
            logs.append("VERDICT 2: FAIL — Conflicting write was not properly rejected or writers not attributed: \(writeResultB).")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 3: The losing value is still recoverable from the conflict record.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 3] Zero data loss — recovering losing content from conflict records:")
        let allConflicts = service.getConflicts(spaceId: spaceAlpha, blockId: blockId, workspacePath: tempWorkspace.path)
        let matchingConflict = allConflicts.first(where: { $0.conflictingWriterId == "agent_developer_B" })

        let v3Pass = (capturedConflict != nil) &&
                     (matchingConflict != nil) &&
                     (capturedConflict?.id == matchingConflict?.id) &&
                     (matchingConflict?.conflictingContent == stalePayloadB) &&
                     (matchingConflict?.winningContent == v2Payload)

        if v3Pass, let conflict = matchingConflict {
            logs.append("Recovered conflict record ID: \(conflict.id.uuidString)")
            logs.append("Preserved losing content: '\(conflict.conflictingContent)'")
            logs.append("Preserved winning content: '\(conflict.winningContent)'")
            logs.append("VERDICT 3: PASS — The losing value is still recoverable from the conflict record.")
        } else {
            logs.append("VERDICT 3: FAIL — Could not recover the losing value from conflict records: \(allConflicts).")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 4: An agent in a different Space cannot read the block.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 4] Space boundary isolation:")
        let foreignRead = service.readBlock(spaceId: spaceBeta, blockId: blockId, workspacePath: tempWorkspace.path)
        let foreignList = service.listBlocks(spaceId: spaceBeta, workspacePath: tempWorkspace.path)
        let v4Pass = (foreignRead == nil) && foreignList.isEmpty

        if v4Pass {
            logs.append("Agent in Space Beta queried block '\(blockId)' -> returned nil (list count: \(foreignList.count)).")
            logs.append("VERDICT 4: PASS — An agent in a different Space cannot read the block.")
        } else {
            logs.append("VERDICT 4: FAIL — Block leaked across Space boundaries into Space Beta: \(String(describing: foreignRead)).")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 5: Blocks survive a restart (fresh instance reads them back).
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 5] Cold restart persistence across fresh service instances:")
        // Create an entirely fresh service instance pointing to the same disk root
        let restartedService = SharedMemoryBlockService(storageDirectory: tempWorkspace)

        let recoveredBlock = restartedService.readBlock(spaceId: spaceAlpha, blockId: blockId, workspacePath: tempWorkspace.path)
        let recoveredConflicts = restartedService.getConflicts(spaceId: spaceAlpha, blockId: blockId, workspacePath: tempWorkspace.path)

        let v5Pass = (recoveredBlock != nil) &&
                     (recoveredBlock?.content == v2Payload) &&
                     (recoveredBlock?.version == 2) &&
                     (recoveredBlock?.writerId == "agent_architect_A") &&
                     (!recoveredConflicts.isEmpty) &&
                     (recoveredConflicts.first?.conflictingWriterId == "agent_developer_B")

        if v5Pass {
            logs.append("Restarted service successfully loaded block from disk: v\(recoveredBlock?.version ?? 0) with \(recoveredConflicts.count) conflict record(s).")
            logs.append("VERDICT 5: PASS — Blocks survive a restart (fresh instance reads them back).")
        } else {
            logs.append("VERDICT 5: FAIL — Restarted service failed to restore state from disk: \(String(describing: recoveredBlock)).")
            allPassed = false
        }

        logs.append("\n================================================================================")
        logs.append("SUMMARY: \(allPassed ? "ALL 5 VERDICTS PASSED (5/5)" : "FAILED VERDICTS DETECTED")")
        logs.append("================================================================================")

        return finalize(logs: logs, passed: allPassed, writeLogTo: writeLogTo)
    }

    private static func finalize(logs: [String], passed: Bool, writeLogTo: String?) -> (output: String, passed: Bool) {
        let output = logs.joined(separator: "\n")
        if let logPath = writeLogTo {
            let expanded = (logPath as NSString).expandingTildeInPath
            let url: URL
            if expanded.hasPrefix("/") {
                url = URL(fileURLWithPath: expanded)
            } else {
                let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                url = repoRoot.appendingPathComponent(logPath)
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? output.write(to: url, atomically: true, encoding: .utf8)
        }
        return (output, passed)
    }
}
