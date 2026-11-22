import Foundation

// MARK: - Task Workspace Live Verifier (Issue #102, G2)

/// Executes real end-to-end verification of per-task isolated workspaces,
/// path containment enforcement, cross-workspace isolation, and merge/review gating.
public enum TaskWorkspaceLiveVerifier {

    public struct VerificationResult: Sendable {
        public let output: String
        public let passed: Bool
        public let totalChecks: Int
        public let passedChecks: Int
    }

    public static func runVerification(jsonOutput: Bool = false) async -> VerificationResult {
        var logs: [String] = []
        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())

        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #102: ISOLATED PARALLEL WORKSPACES LIVE VERIFICATION (G2)")
        logs.append("Timestamp: \(timestamp)")
        logs.append("Host: Darwin arm64 — Parallel Task Workspaces & Merge Review")
        logs.append("================================================================================")

        var allPassed = true
        var passedChecks = 0
        let totalChecks = 5

        let runUUID = UUID().uuidString.prefix(8).lowercased()
        let taskAID = "task-alpha-\(runUUID)"
        let taskBID = "task-beta-\(runUUID)"

        let baseTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("apex_live_test_base_\(runUUID)")
        try? FileManager.default.createDirectory(at: baseTemp, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: baseTemp)
        }

        // -------------------------------------------------------------------------
        // CHECK 1: Two parallel tasks each get their own isolated workspace
        // -------------------------------------------------------------------------
        logs.append("\n[Check 1] Provisioning Distinct Workspaces for Two Parallel Tasks:")
        var wsAOpt: TaskWorkspace?
        var wsBOpt: TaskWorkspace?

        do {
            let wsA = try await TaskWorkspaceManager.shared.createWorkspace(
                taskID: taskAID,
                baseDirectory: baseTemp.path,
                isolationType: .ephemeralDirectory,
                retentionPolicy: .cleanupAlways
            )
            let wsB = try await TaskWorkspaceManager.shared.createWorkspace(
                taskID: taskBID,
                baseDirectory: baseTemp.path,
                isolationType: .ephemeralDirectory,
                retentionPolicy: .cleanupAlways
            )
            wsAOpt = wsA
            wsBOpt = wsB

            logs.append("  -> Task A workspace: \(wsA.workspacePath)")
            logs.append("  -> Task B workspace: \(wsB.workspacePath)")

            let pathsDistinct = wsA.workspacePath != wsB.workspacePath
            let bothExist = FileManager.default.fileExists(atPath: wsA.workspacePath) &&
                            FileManager.default.fileExists(atPath: wsB.workspacePath)

            if pathsDistinct && bothExist {
                logs.append("VERDICT 1: PASS (Two parallel tasks each get their own isolated workspace: Task A '\(wsA.workspacePath)' and Task B '\(wsB.workspacePath)')")
                passedChecks += 1
            } else {
                logs.append("VERDICT 1: FAIL (Workspaces failed distinctness or directory creation)")
                allPassed = false
            }
        } catch {
            logs.append("VERDICT 1: FAIL (Error creating parallel workspaces: \(error.localizedDescription))")
            allPassed = false
        }

        guard let wsA = wsAOpt, let wsB = wsBOpt else {
            let output = logs.joined(separator: "\n")
            return VerificationResult(output: output, passed: false, totalChecks: totalChecks, passedChecks: passedChecks)
        }

        // -------------------------------------------------------------------------
        // CHECK 2: File written by Task A is NOT visible inside Task B's workspace
        // -------------------------------------------------------------------------
        logs.append("\n[Check 2] Cross-Workspace Isolation & Non-Corruption:")
        let secretFilename = "task_a_isolated_data.txt"
        let secretContent = "CONFIDENTIAL_PAYLOAD_TASK_A_\(runUUID)"

        do {
            let writtenPathA = try wsA.writeFile(relativePath: secretFilename, content: secretContent)
            logs.append("  -> Task A wrote file to: \(writtenPathA)")

            let existsInA = wsA.fileExists(relativePath: secretFilename)
            let existsInB = wsB.fileExists(relativePath: secretFilename)
            logs.append("  -> File exists in Task A: \(existsInA)")
            logs.append("  -> File exists in Task B: \(existsInB)")

            if existsInA && !existsInB {
                logs.append("VERDICT 2: PASS (A file written by task A is not visible inside task B's workspace: existsInA=true, existsInB=false)")
                passedChecks += 1
            } else {
                logs.append("VERDICT 2: FAIL (Isolation leak detected: file exists in B=\(existsInB))")
                allPassed = false
            }
        } catch {
            logs.append("VERDICT 2: FAIL (Error performing cross-workspace write check: \(error.localizedDescription))")
            allPassed = false
        }

        // -------------------------------------------------------------------------
        // CHECK 3: Task cannot escape its own workspace path
        // -------------------------------------------------------------------------
        logs.append("\n[Check 3] Workspace Path Confinement & Escape Prevention:")
        var escapeBlocked = false
        var escapeErrorSummary = ""

        let escapeAttempts = [
            "../escape_sibling.txt",
            "../../escape_parent.txt",
            "/tmp/apex_unauthorized_escape_\(runUUID).txt"
        ]

        for attempt in escapeAttempts {
            do {
                _ = try wsA.writeFile(relativePath: attempt, content: "malicious escape data")
                logs.append("  -> ERROR: Escape succeeded unexpectedly for: \(attempt)")
                escapeBlocked = false
                break
            } catch let error as TaskWorkspaceError {
                if case .pathEscape(let attempted, let root) = error {
                    logs.append("  -> Successfully caught pathEscape for '\(attempted)' outside '\(root)'")
                    escapeBlocked = true
                    escapeErrorSummary = error.localizedDescription
                }
            } catch {
                logs.append("  -> Caught expected error for '\(attempt)': \(error.localizedDescription)")
                escapeBlocked = true
            }
        }

        if escapeBlocked {
            logs.append("VERDICT 3: PASS (A task cannot write outside its own workspace: \(escapeErrorSummary))")
            passedChecks += 1
        } else {
            logs.append("VERDICT 3: FAIL (Path escape check failed to confine task writes)")
            allPassed = false
        }

        // -------------------------------------------------------------------------
        // CHECK 4: Merge/review step shows task changes for review before landing
        // -------------------------------------------------------------------------
        logs.append("\n[Check 4] Pre-Landing Merge/Review Step & Proposal Generation:")

        do {
            let featureFile = "FeatureComponent.swift"
            let featureContent = "// Feature Component for \(runUUID)\npublic struct ComponentA {}\n"
            try wsA.writeFile(relativePath: featureFile, content: featureContent)

            let proposal = try await TaskMergeReviewService.shared.createReviewProposal(for: wsA.id)
            logs.append("  -> Proposal for task '\(proposal.taskID)':")
            logs.append("     Changed files count: \(proposal.changedFiles.count)")
            for cf in proposal.changedFiles {
                logs.append("     - \(cf.changeType.rawValue.uppercased()): \(cf.path) (\(cf.byteCount) bytes)")
            }
            logs.append("  -> Summary preview:\n\(proposal.diffSummary)")

            let hasChangedFiles = !proposal.changedFiles.isEmpty
            let containsFeature = proposal.changedFiles.contains { $0.path == featureFile }
            if hasChangedFiles && containsFeature && proposal.isEligibleForLanding {
                logs.append("VERDICT 4: PASS (The merge/review step shows the task's changes for review before landing: \(proposal.changedFiles.count) file(s) presented)")
                passedChecks += 1
            } else {
                logs.append("VERDICT 4: FAIL (Proposal did not properly enumerate task changes)")
                allPassed = false
            }
        } catch {
            logs.append("VERDICT 4: FAIL (Error generating review proposal: \(error.localizedDescription))")
            allPassed = false
        }

        // -------------------------------------------------------------------------
        // CHECK 5: Task whose changes fail review DOES NOT land
        // -------------------------------------------------------------------------
        logs.append("\n[Check 5] Review Gating & Refusal to Land Failing Changes:")
        let targetLandingDir = baseTemp.appendingPathComponent("target_landing")
        try? FileManager.default.createDirectory(at: targetLandingDir, withIntermediateDirectories: true)

        do {
            // First: Attempt landing with reviewerApproval = false (rejection)
            let rejectionResult = try await TaskMergeReviewService.shared.land(
                taskID: wsA.id,
                reviewerApproval: false,
                reviewerNotes: "Changes contain unreviewed code and failed architectural linting",
                targetWorkspacePath: targetLandingDir.path
            )
            logs.append("  -> Landing attempt 1 (Rejected): succeeded=\(rejectionResult.succeeded), reason=\(rejectionResult.reason)")

            let targetFeaturePath = targetLandingDir.appendingPathComponent("FeatureComponent.swift").path
            let landedOnDiskAfterRejection = FileManager.default.fileExists(atPath: targetFeaturePath)
            logs.append("  -> Target workspace has FeatureComponent.swift after rejection: \(landedOnDiskAfterRejection)")

            // Second: Attempt landing with reviewerApproval = true to verify successful path
            let approvalResult = try await TaskMergeReviewService.shared.land(
                taskID: wsA.id,
                reviewerApproval: true,
                reviewerNotes: "Reviewer approved after thorough verification",
                targetWorkspacePath: targetLandingDir.path
            )
            logs.append("  -> Landing attempt 2 (Approved): succeeded=\(approvalResult.succeeded), landed=\(approvalResult.landedFiles)")
            let landedOnDiskAfterApproval = FileManager.default.fileExists(atPath: targetFeaturePath)
            logs.append("  -> Target workspace has FeatureComponent.swift after approval: \(landedOnDiskAfterApproval)")

            if !rejectionResult.succeeded && !landedOnDiskAfterRejection && approvalResult.succeeded && landedOnDiskAfterApproval {
                logs.append("VERDICT 5: PASS (A task whose changes fail review does not land: rejection refused cleanly and target copy untouched)")
                passedChecks += 1
            } else {
                logs.append("VERDICT 5: FAIL (Review gating failed to block unapproved landing or failed to land approved changes)")
                allPassed = false
            }
        } catch {
            logs.append("VERDICT 5: FAIL (Error testing review landing gate: \(error.localizedDescription))")
            allPassed = false
        }

        // Teardown workspaces per policy
        try? await TaskWorkspaceManager.shared.teardownWorkspace(taskID: taskAID, status: allPassed ? .succeeded : .failed)
        try? await TaskWorkspaceManager.shared.teardownWorkspace(taskID: taskBID, status: allPassed ? .succeeded : .failed)

        logs.append("\n================================================================================")
        logs.append(allPassed ? "VERIFICATION RESULT: PASS (\(passedChecks)/\(totalChecks) checks passed)" : "VERIFICATION RESULT: FAIL (\(passedChecks)/\(totalChecks) checks passed)")
        logs.append("================================================================================")

        let finalOutput = logs.joined(separator: "\n")

        // Persist to runs/issue102/live-verify.log
        let runsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("runs")
            .appendingPathComponent("issue102")
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        let logURL = runsDir.appendingPathComponent("live-verify.log")
        try? finalOutput.write(to: logURL, atomically: true, encoding: .utf8)

        return VerificationResult(
            output: finalOutput,
            passed: allPassed,
            totalChecks: totalChecks,
            passedChecks: passedChecks
        )
    }
}
