import Foundation

// MARK: - Reviewer / Critic Live Verifier (Issue #103, G3)

/// Executes real end-to-end verification of the Reviewer/Critic Agent against clean and defective artifact sets,
/// verifying that defects are caught with verbatim citations and that fail verdicts block the done claim.
public enum ReviewerCriticLiveVerifier {

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
        logs.append("APEXAGENT ISSUE #103: LIVE REVIEWER/CRITIC AGENT VERIFICATION (G3)")
        logs.append("Timestamp: \(timestamp)")
        logs.append("Host: Darwin arm64 — Independent Agent Verification Before 'done'")
        logs.append("================================================================================")

        var allPassed = true
        var checkIndex = 1

        let reviewer = ReviewerAgent()

        // -------------------------------------------------------------------------
        // CHECK 1: Clean Artifact Set (All claims supported, 0 findings -> PASS)
        // -------------------------------------------------------------------------
        logs.append("\n[Check 1] Clean Artifact Set Verification:")
        let cleanFileContent = """
        import Foundation

        public final class MemoryCache {
            public static let shared = MemoryCache()
            public let ttlSeconds: TimeInterval = 60.0
            public let memoryLimitBytes: Int = 10485760

            public func purgeEvictedItems() {
                // purge expired items
            }
        }
        """
        let cleanArtifact = ReviewArtifact(path: "MemoryCache.swift", content: cleanFileContent)
        let cleanClaims = [
            ReviewClaim(
                claimText: "MemoryCache sets TTL to 60.0s",
                requiredArtifactPath: "MemoryCache.swift",
                expectedPattern: "ttlSeconds: TimeInterval = 60.0"
            ),
            ReviewClaim(
                claimText: "MemoryCache provides purgeEvictedItems method",
                requiredArtifactPath: "MemoryCache.swift",
                expectedPattern: "func purgeEvictedItems()"
            )
        ]
        let cleanRequest = ReviewRequest(
            requestDescription: "Implement MemoryCache with 60s TTL and purgeEvictedItems method",
            claims: cleanClaims,
            requiredArtifactPaths: ["MemoryCache.swift"],
            artifacts: [cleanArtifact]
        )

        let cleanReport = await reviewer.review(request: cleanRequest, recordToTrace: true)
        logs.append("  -> Reviewer Verdict: \(cleanReport.verdict.rawValue.uppercased())")
        logs.append("  -> Summary: \(cleanReport.summary)")
        logs.append("  -> Findings count: \(cleanReport.findings.count)")

        let check1Passed = cleanReport.isPassed && cleanReport.findings.isEmpty
        if check1Passed {
            logs.append("VERDICT \(checkIndex): PASS (Clean artifact set verified with 0 findings)")
        } else {
            logs.append("VERDICT \(checkIndex): FAIL (Clean artifact set unexpectedly reported findings)")
            allPassed = false
        }
        checkIndex += 1

        // -------------------------------------------------------------------------
        // CHECK 2: Planted Defect Set (Unsupported claim + Contradictory artifact -> FAIL)
        // -------------------------------------------------------------------------
        logs.append("\n[Check 2] Planted Defect Set Verification (Unsupported claim & Contradiction):")
        let defectiveFileContent = """
        import Foundation

        public final class SecureTokenVault {
            // CONTRADICTION: Expire session immediately on first use
            public let sessionExpirySeconds: Int = 0 // Expire session immediately
        }
        """
        let defectiveArtifact = ReviewArtifact(path: "SecureTokenVault.swift", content: defectiveFileContent)
        let defectiveClaims = [
            ReviewClaim(
                claimText: "SecureTokenVault configures 300s session expiry",
                requiredArtifactPath: "SecureTokenVault.swift",
                contradictionPattern: "Expire session immediately"
            ),
            ReviewClaim(
                claimText: "Docs/Security.md documents the token vault lifecycle",
                requiredArtifactPath: "Docs/Security.md"
            )
        ]
        let defectiveRequest = ReviewRequest(
            requestDescription: "Implement SecureTokenVault with 300s session expiry and write docs in Docs/Security.md",
            claims: defectiveClaims,
            requiredArtifactPaths: ["SecureTokenVault.swift", "Docs/Security.md"],
            artifacts: [defectiveArtifact]
        )

        let defectiveReport = await reviewer.review(request: defectiveRequest, recordToTrace: true)
        logs.append("  -> Reviewer Verdict: \(defectiveReport.verdict.rawValue.uppercased())")
        logs.append("  -> Summary: \(defectiveReport.summary)")
        logs.append("  -> Findings count: \(defectiveReport.findings.count)")
        for (idx, finding) in defectiveReport.findings.enumerated() {
            logs.append("     [\(idx + 1)] [\(finding.kind.rawValue)] at \(finding.location): \(finding.reason)")
        }

        let hasContradiction = defectiveReport.findings.contains { $0.kind == .contradictoryArtifact && $0.location == "SecureTokenVault.swift:4" }
        let hasMissingDoc = defectiveReport.findings.contains { $0.kind == .missingRequiredArtifact && $0.artifactPath == "Docs/Security.md" }
        let check2Passed = !defectiveReport.isPassed && hasContradiction && hasMissingDoc
        if check2Passed {
            logs.append("VERDICT \(checkIndex): PASS (Planted defect caught: contradiction cited at SecureTokenVault.swift:4 and missing Docs/Security.md:1)")
        } else {
            logs.append("VERDICT \(checkIndex): FAIL (Planted defects were not properly cited or verdict was not FAIL)")
            allPassed = false
        }
        checkIndex += 1

        // -------------------------------------------------------------------------
        // CHECK 3: Missing Required Artifact Reported as Finding, Not Silent Pass
        // -------------------------------------------------------------------------
        logs.append("\n[Check 3] Missing Required Artifact Verification:")
        let missingRequest = ReviewRequest(
            requestDescription: "Generate required report at reports/manifest.json",
            claims: [],
            requiredArtifactPaths: ["reports/manifest.json"],
            artifacts: []
        )
        let missingReport = await reviewer.review(request: missingRequest, recordToTrace: true)
        logs.append("  -> Reviewer Verdict: \(missingReport.verdict.rawValue.uppercased())")
        logs.append("  -> Summary: \(missingReport.summary)")
        for finding in missingReport.findings {
            logs.append("     [\(finding.kind.rawValue)] at \(finding.location): \(finding.reason)")
        }

        let check3Passed = !missingReport.isPassed && missingReport.findings.contains { $0.kind == .missingRequiredArtifact && $0.artifactPath == "reports/manifest.json" }
        if check3Passed {
            logs.append("VERDICT \(checkIndex): PASS (Missing required artifact reported as finding citing reports/manifest.json:1)")
        } else {
            logs.append("VERDICT \(checkIndex): FAIL (Missing required artifact was silently passed)")
            allPassed = false
        }
        checkIndex += 1

        // -------------------------------------------------------------------------
        // CHECK 4: Checkpoint Wiring Blocks Done Claim in Workflow (ConfirmCompletionTool)
        // -------------------------------------------------------------------------
        logs.append("\n[Check 4] Checkpoint Wiring Blocks Done Claim in ConfirmCompletionTool:")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgent-Issue103-LiveVerify-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blockedReport = await reviewer.reviewCompletion(
            summary: "Completed feature implementation",
            filesModified: "MissingProductFile.swift",
            verificationResults: "Tests failed with exit code 1",
            workspacePath: tempDir.path
        )
        logs.append("  -> Completion Review Verdict: \(blockedReport.verdict.rawValue.uppercased())")
        logs.append("  -> Summary: \(blockedReport.summary)")
        for finding in blockedReport.findings {
            logs.append("     [\(finding.kind.rawValue)] at \(finding.location): \(finding.reason)")
        }

        let check4Passed = !blockedReport.isPassed && blockedReport.findings.count >= 2
        if check4Passed {
            logs.append("VERDICT \(checkIndex): PASS (Fail verdict blocks done claim and surfaces findings citing exact locations)")
        } else {
            logs.append("VERDICT \(checkIndex): FAIL (Workflow failed to block done claim on defect)")
            allPassed = false
        }
        checkIndex += 1

        // -------------------------------------------------------------------------
        // CHECK 5: Trace Recording for Review Checkpoint
        // -------------------------------------------------------------------------
        logs.append("\n[Check 5] Telemetry Trace Recording for Review Checkpoint:")
        let runId = RunTrace.generateRunId()
        RunTraceManager.shared.startRun(runId: runId, workspacePath: tempDir.path)
        let passReport = await reviewer.review(request: cleanRequest, recordToTrace: true)
        let traceEvent = RunTraceManager.shared.activeRecorder?.currentTraceSnapshot().events.last
        RunTraceManager.shared.endRun(runId: runId)

        let check5Passed = passReport.isPassed
            && traceEvent?.kind == .reviewCheckpoint
            && traceEvent?.reviewVerdict == "pass"
        if check5Passed {
            logs.append("  -> Trace Event: \(traceEvent?.eventDescription ?? "")")
            logs.append("VERDICT \(checkIndex): PASS (Pass verdict and findings recorded in RunTrace telemetry)")
        } else {
            logs.append("VERDICT \(checkIndex): FAIL (Review checkpoint was not recorded in RunTrace)")
            allPassed = false
        }

        logs.append("\n================================================================================")
        let finalResultLine = allPassed ? "VERIFICATION RESULT: PASS" : "VERIFICATION RESULT: FAIL"
        logs.append(finalResultLine)
        logs.append("================================================================================")

        let fullOutput = logs.joined(separator: "\n")

        // Write log directly to runs/issue103/live-verify.log if workspace runs directory exists
        let currentDir = FileManager.default.currentDirectoryPath
        let logDirURL = URL(fileURLWithPath: currentDir).appendingPathComponent("runs/issue103", isDirectory: true)
        if FileManager.default.fileExists(atPath: logDirURL.path) {
            let logFileURL = logDirURL.appendingPathComponent("live-verify.log")
            try? fullOutput.write(to: logFileURL, atomically: true, encoding: .utf8)
        }

        return VerificationResult(
            output: fullOutput,
            passed: allPassed,
            totalChecks: 5,
            passedChecks: allPassed ? 5 : 0
        )
    }
}
