import Foundation

// MARK: - Approval Live Verifier (Issue #105)

/// Live verification harness for testing approval ergonomics against real binary code.
public enum ApprovalLiveVerifier {
    public static func runVerification() -> (output: String, passed: Bool) {
        var logs: [String] = []
        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #105: LIVE APPROVAL ERGONOMICS VERIFICATION")
        logs.append("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        logs.append("================================================================================")

        let allowlist = ApprovalAllowlist()
        let testDir = "/Users/danielstevens/Developer/ApexAgent"
        let testCmd = "swift test --filter ApprovalTests"

        // Clean any leftover state for deterministic test run
        allowlist.remove(command: testCmd, directory: testDir)
        allowlist.remove(command: "git status", directory: testDir)

        // 1. Allowlist Learning & Persistence
        logs.append("\n[1] Testing Allowlist Learning & Auto-Allow:")
        let initialCheck = allowlist.isAllowed(command: testCmd, directory: testDir)
        logs.append("Initial check for '\(testCmd)' in '\(testDir)': allowed=\(initialCheck) (ASKS)")

        // Daniel approves command in directory once
        let entry = allowlist.allow(command: testCmd, directory: testDir, ttl: ApprovalAllowlist.defaultApprovalTTL)
        logs.append("Approved once: recorded allowlist grant [id=\(entry.id.uuidString.prefix(8)), ttl=\(Int(ApprovalAllowlist.defaultApprovalTTL))s, expires=\(ISO8601DateFormatter().string(from: entry.expiresAt))]")

        let secondCheck = allowlist.isAllowed(command: testCmd, directory: testDir)
        logs.append("Subsequent check for same command + directory: allowed=\(secondCheck) (AUTO-ALLOWED)")

        let differentCmdCheck = allowlist.isAllowed(command: "rm -rf build", directory: testDir)
        logs.append("Check with different command in same directory: allowed=\(differentCmdCheck) (ASKS)")

        let differentDirCheck = allowlist.isAllowed(command: testCmd, directory: "/tmp")
        logs.append("Check with same command in different directory: allowed=\(differentDirCheck) (ASKS)")

        // Revocation check
        let revoked = allowlist.remove(id: entry.id)
        let afterRevocationCheck = allowlist.isAllowed(command: testCmd, directory: testDir)
        logs.append("Revoked entry [id=\(entry.id.uuidString.prefix(8))]: removed=\(revoked), allowedAfterRevocation=\(afterRevocationCheck) (ASKS)")

        // Re-allow for auto-review test
        allowlist.allow(command: testCmd, directory: testDir, ttl: ApprovalAllowlist.defaultApprovalTTL)

        // 2. Approval Expiry Boundary
        logs.append("\n[2] Testing Approval Expiry Boundary:")
        let shortTtlEntry = allowlist.allow(command: "git status", directory: testDir, ttl: 2.0)
        logs.append("Recorded entry with TTL=2.0s: expires=\(ISO8601DateFormatter().string(from: shortTtlEntry.expiresAt))")
        let immediateCheck = allowlist.isAllowed(command: "git status", directory: testDir)
        logs.append("Immediate check before expiry: allowed=\(immediateCheck) (AUTO-ALLOWED)")

        let futureDate = Date().addingTimeInterval(10.0)
        let expiredCheck = allowlist.isAllowed(command: "git status", directory: testDir, now: futureDate)
        logs.append("Check past expiry boundary (at \(ISO8601DateFormatter().string(from: futureDate))): allowed=\(expiredCheck) (EXPIRED, ASKS AGAIN)")

        // 3. Phone-Ready Approval Payload
        logs.append("\n[3] Phone-Ready Approval Payload (feeds #70 iOS):")
        let phonePayload = PhoneApprovalPayload(
            ask: "Execute shell command",
            command: "git push origin main",
            directory: testDir,
            riskSummary: "Outbound network transmission and remote branch update",
            expiresAt: Date().addingTimeInterval(60)
        )
        let jsonString = phonePayload.toJSONString(prettyPrinted: true)
        logs.append(jsonString)

        // 4. Low-Risk Auto-Review vs High-Risk Surfacing
        logs.append("\n[4] Low-Risk Auto-Review vs High-Risk Surfacing:")

        // 4a. Read-only command (low risk -> auto-approved)
        let lowRiskReadOnly = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "git status",
            directory: testDir,
            workspacePath: testDir,
            allowlist: allowlist
        )
        logs.append("Action 'git status': autoApprove=\(lowRiskReadOnly.shouldAutoApprove), level=\(lowRiskReadOnly.assessment.level), category=\(lowRiskReadOnly.assessment.category.rawValue)")
        logs.append("  -> \(lowRiskReadOnly.explanation)")

        // 4b. Allowlisted command + directory (low risk -> auto-approved)
        let lowRiskAllowlisted = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: testCmd,
            directory: testDir,
            workspacePath: testDir,
            allowlist: allowlist
        )
        logs.append("Action allowlisted '\(testCmd)': autoApprove=\(lowRiskAllowlisted.shouldAutoApprove), level=\(lowRiskAllowlisted.assessment.level), category=\(lowRiskAllowlisted.assessment.category.rawValue)")
        logs.append("  -> \(lowRiskAllowlisted.explanation)")

        // 4c. Well-known safe inspection (low risk -> auto-approved)
        let lowRiskSafe = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "swift --version",
            directory: testDir,
            workspacePath: testDir,
            allowlist: allowlist
        )
        logs.append("Action 'swift --version': autoApprove=\(lowRiskSafe.shouldAutoApprove), level=\(lowRiskSafe.assessment.level), category=\(lowRiskSafe.assessment.category.rawValue)")
        logs.append("  -> \(lowRiskSafe.explanation)")

        // 4d. Network send (high risk -> surfaced)
        let highRiskNetwork = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "curl -X POST https://api.example.com/data",
            directory: testDir,
            workspacePath: testDir,
            allowlist: allowlist
        )
        logs.append("Action 'curl ...': autoApprove=\(highRiskNetwork.shouldAutoApprove), level=\(highRiskNetwork.assessment.level), category=\(highRiskNetwork.assessment.category.rawValue)")
        logs.append("  -> \(highRiskNetwork.explanation)")

        // 4e. Write outside workspace (high risk -> surfaced)
        let highRiskWriteOutside = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "echo test > /etc/hosts",
            directory: testDir,
            workspacePath: testDir,
            allowlist: allowlist
        )
        logs.append("Action 'echo > /etc/hosts': autoApprove=\(highRiskWriteOutside.shouldAutoApprove), level=\(highRiskWriteOutside.assessment.level), category=\(highRiskWriteOutside.assessment.category.rawValue)")
        logs.append("  -> \(highRiskWriteOutside.explanation)")

        // 4f. Deletion (high risk -> surfaced)
        let highRiskDeletion = ApprovalAutoReview.review(
            toolName: "delete_file",
            directory: testDir,
            workspacePath: testDir,
            allowlist: allowlist
        )
        logs.append("Action 'delete_file': autoApprove=\(highRiskDeletion.shouldAutoApprove), level=\(highRiskDeletion.assessment.level), category=\(highRiskDeletion.assessment.category.rawValue)")
        logs.append("  -> \(highRiskDeletion.explanation)")

        // 4g. Credential access (high risk -> surfaced)
        let highRiskCredential = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "cat ~/.ssh/id_rsa",
            directory: testDir,
            workspacePath: testDir,
            allowlist: allowlist
        )
        logs.append("Action 'cat ~/.ssh/id_rsa': autoApprove=\(highRiskCredential.shouldAutoApprove), level=\(highRiskCredential.assessment.level), category=\(highRiskCredential.assessment.category.rawValue)")
        logs.append("  -> \(highRiskCredential.explanation)")

        // Overall validation
        let allPassed = !initialCheck
            && secondCheck
            && !differentCmdCheck
            && !differentDirCheck
            && revoked
            && !afterRevocationCheck
            && immediateCheck
            && !expiredCheck
            && lowRiskReadOnly.shouldAutoApprove
            && lowRiskAllowlisted.shouldAutoApprove
            && lowRiskSafe.shouldAutoApprove
            && !highRiskNetwork.shouldAutoApprove
            && !highRiskWriteOutside.shouldAutoApprove
            && !highRiskDeletion.shouldAutoApprove
            && !highRiskCredential.shouldAutoApprove

        logs.append("\n================================================================================")
        logs.append("VERIFICATION RESULT: \(allPassed ? "PASS" : "FAIL")")
        logs.append("================================================================================")

        return (logs.joined(separator: "\n"), allPassed)
    }
}
