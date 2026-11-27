import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Approval Ergonomics Tests (Issue #105)

@Suite("ApprovalErgonomicsTests")
struct ApprovalErgonomicsTests {

    // MARK: - Allowlist Learning & Matching

    @Test func testAllowlistHitExactCommandAndDirectory() {
        let allowlist = ApprovalAllowlist(userDefaults: UserDefaults(suiteName: "test.allowlist.hit") ?? .standard)
        allowlist.removeAll()

        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"
        let cmd = "swift build"

        // Before approval: not allowed
        #expect(!allowlist.isAllowed(command: cmd, directory: dir))

        // Approve command in directory
        let entry = allowlist.allow(command: cmd, directory: dir)
        #expect(entry.command == cmd)
        #expect(entry.directory == dir)
        #expect(entry.expiresAt > Date())

        // Same command and directory: hit (auto-allowed)
        #expect(allowlist.isAllowed(command: cmd, directory: dir))
    }

    @Test func testAllowlistMissDifferentCommand() {
        let allowlist = ApprovalAllowlist(userDefaults: UserDefaults(suiteName: "test.allowlist.diffcmd") ?? .standard)
        allowlist.removeAll()

        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"
        allowlist.allow(command: "swift build", directory: dir)

        // Different command in same directory: miss
        #expect(!allowlist.isAllowed(command: "swift test", directory: dir))
        #expect(!allowlist.isAllowed(command: "rm -rf build", directory: dir))
    }

    @Test func testAllowlistMissDifferentDirectory() {
        let allowlist = ApprovalAllowlist(userDefaults: UserDefaults(suiteName: "test.allowlist.diffdir") ?? .standard)
        allowlist.removeAll()

        let dirA = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"
        let dirB = "/Users/danielstevens/Developer/OtherProject"
        let cmd = "git status"

        allowlist.allow(command: cmd, directory: dirA)

        // Same command in different directory: miss
        #expect(allowlist.isAllowed(command: cmd, directory: dirA))
        #expect(!allowlist.isAllowed(command: cmd, directory: dirB))
    }

    @Test func testAllowlistRevocationListAndRemove() {
        let allowlist = ApprovalAllowlist(userDefaults: UserDefaults(suiteName: "test.allowlist.revoke") ?? .standard)
        allowlist.removeAll()

        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"
        let entry1 = allowlist.allow(command: "git fetch", directory: dir)
        let entry2 = allowlist.allow(command: "git branch", directory: dir)

        var entries = allowlist.listEntries()
        #expect(entries.count == 2)
        #expect(entries.contains { $0.id == entry1.id })
        #expect(entries.contains { $0.id == entry2.id })

        // Revoke entry1 by ID
        let removed1 = allowlist.remove(id: entry1.id)
        #expect(removed1)
        #expect(!allowlist.isAllowed(command: "git fetch", directory: dir))
        #expect(allowlist.isAllowed(command: "git branch", directory: dir))

        // Revoke entry2 by command + directory
        let removed2 = allowlist.remove(command: "git branch", directory: dir)
        #expect(removed2)
        #expect(!allowlist.isAllowed(command: "git branch", directory: dir))

        entries = allowlist.listEntries()
        #expect(entries.isEmpty)
    }

    // MARK: - Approval Expiry

    @Test func testApprovalExpiryBoundary() {
        let allowlist = ApprovalAllowlist(userDefaults: UserDefaults(suiteName: "test.allowlist.expiry") ?? .standard)
        allowlist.removeAll()

        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"
        let cmd = "make lint"
        let now = Date()

        // Default TTL is a named constant (24h / 86400s)
        #expect(ApprovalAllowlist.defaultApprovalTTL == 86_400)

        // Allow with 10-second TTL
        let ttl: TimeInterval = 10.0
        let entry = allowlist.allow(command: cmd, directory: dir, ttl: ttl, now: now)
        #expect(!entry.isExpired(now: now))

        // 1 second before expiry: still allowed
        let beforeExpiry = now.addingTimeInterval(9.0)
        #expect(allowlist.isAllowed(command: cmd, directory: dir, now: beforeExpiry))

        // Exactly at expiry boundary: expired
        let atExpiry = now.addingTimeInterval(10.0)
        #expect(!allowlist.isAllowed(command: cmd, directory: dir, now: atExpiry))

        // Past expiry: expired
        let pastExpiry = now.addingTimeInterval(15.0)
        #expect(!allowlist.isAllowed(command: cmd, directory: dir, now: pastExpiry))
        #expect(entry.isExpired(now: pastExpiry))
    }

    // MARK: - Phone-Ready Approval Payload

    @Test func testPhoneReadyApprovalPayloadContents() throws {
        let expiryDate = Date(timeIntervalSince1970: 1770000000)
        let payload = PhoneApprovalPayload(
            ask: "Execute terminal command",
            command: "git push origin feat/ui",
            directory: "/Users/danielstevens/AI-Workspace/repos/ApexAgent",
            riskSummary: "Pushes local commits to remote origin",
            expiresAt: expiryDate
        )

        // Payload contains exactly what phone needs
        #expect(payload.ask == "Execute terminal command")
        #expect(payload.command == "git push origin feat/ui")
        #expect(payload.directory == "/Users/danielstevens/AI-Workspace/repos/ApexAgent")
        #expect(payload.riskSummary == "Pushes local commits to remote origin")
        #expect(payload.expiresAt == expiryDate)

        // Serialization to JSON
        let data = try payload.toJSONData()
        let decoded = try PhoneApprovalPayload.fromJSONData(data)
        #expect(decoded == payload)

        // Verify JSON keys
        let jsonDict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(jsonDict != nil)
        #expect(jsonDict?["ask"] as? String == "Execute terminal command")
        #expect(jsonDict?["command"] as? String == "git push origin feat/ui")
        #expect(jsonDict?["directory"] as? String == "/Users/danielstevens/AI-Workspace/repos/ApexAgent")
        #expect(jsonDict?["risk_summary"] as? String == "Pushes local commits to remote origin")
        #expect(jsonDict?["expires_at"] != nil)
        #expect(jsonDict?.keys.count == 5) // Exactly 5 keys, nothing more
    }

    // MARK: - Low-Risk Auto-Review vs High-Risk Surfacing

    @Test func testAutoReviewLowRiskReadOnlyCommand() {
        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"

        let statusVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "git status",
            directory: dir,
            workspacePath: dir
        )
        #expect(statusVerdict.shouldAutoApprove)
        #expect(statusVerdict.assessment.level == .low)
        #expect(statusVerdict.assessment.category == .readOnly)

        let readToolVerdict = ApprovalAutoReview.review(
            toolName: "read_file",
            directory: dir,
            workspacePath: dir
        )
        #expect(readToolVerdict.shouldAutoApprove)
        #expect(readToolVerdict.assessment.level == .low)
        #expect(readToolVerdict.assessment.category == .readOnly)
    }

    @Test func testAutoReviewLowRiskAllowlistedCommand() {
        let allowlist = ApprovalAllowlist(userDefaults: UserDefaults(suiteName: "test.autoreview.allowlist") ?? .standard)
        allowlist.removeAll()

        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"
        let cmd = "swift test --filter LongRunTests"

        // Before allowlisting: not auto-approved
        let beforeVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: cmd,
            directory: dir,
            workspacePath: dir,
            allowlist: allowlist
        )
        #expect(!beforeVerdict.shouldAutoApprove)

        // Allow command in directory
        allowlist.allow(command: cmd, directory: dir)

        // After allowlisting: auto-approved under .allowlisted category
        let afterVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: cmd,
            directory: dir,
            workspacePath: dir,
            allowlist: allowlist
        )
        #expect(afterVerdict.shouldAutoApprove)
        #expect(afterVerdict.assessment.level == .low)
        #expect(afterVerdict.assessment.category == .allowlisted)
    }

    @Test func testAutoReviewLowRiskSafeOperations() {
        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"

        let versionVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "swift --version",
            directory: dir,
            workspacePath: dir
        )
        #expect(versionVerdict.shouldAutoApprove)
        #expect(versionVerdict.assessment.level == .low)
        #expect(versionVerdict.assessment.category == .wellKnownSafe)

        let whichVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "which git",
            directory: dir,
            workspacePath: dir
        )
        #expect(whichVerdict.shouldAutoApprove)
        #expect(whichVerdict.assessment.level == .low)
        #expect(whichVerdict.assessment.category == .wellKnownSafe)
    }

    @Test func testAutoReviewHighRiskNetworkSend() {
        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"

        let curlVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "curl -s https://example.com/api",
            directory: dir,
            workspacePath: dir
        )
        #expect(!curlVerdict.shouldAutoApprove)
        #expect(curlVerdict.assessment.level == .high)
        #expect(curlVerdict.assessment.category == .networkSend)

        let pushVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "git push origin main",
            directory: dir,
            workspacePath: dir
        )
        #expect(!pushVerdict.shouldAutoApprove)
        #expect(pushVerdict.assessment.level == .high)
        #expect(pushVerdict.assessment.category == .networkSend)
    }

    @Test func testAutoReviewHighRiskWriteOutsideWorkspace() {
        let workspace = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"

        let targetOutsideVerdict = ApprovalAutoReview.review(
            toolName: "write_file",
            directory: workspace,
            workspacePath: workspace,
            targetFilePath: "/etc/passwd"
        )
        #expect(!targetOutsideVerdict.shouldAutoApprove)
        #expect(targetOutsideVerdict.assessment.level == .high)
        #expect(targetOutsideVerdict.assessment.category == .writeOutsideWorkspace)

        let redirectOutsideVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "echo 'malicious' > /tmp/malicious.sh",
            directory: workspace,
            workspacePath: workspace
        )
        #expect(!redirectOutsideVerdict.shouldAutoApprove)
        #expect(redirectOutsideVerdict.assessment.level == .high)
        #expect(redirectOutsideVerdict.assessment.category == .writeOutsideWorkspace)
    }

    @Test func testAutoReviewHighRiskDeletion() {
        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"

        let deleteToolVerdict = ApprovalAutoReview.review(
            toolName: "delete_file",
            directory: dir,
            workspacePath: dir
        )
        #expect(!deleteToolVerdict.shouldAutoApprove)
        #expect(deleteToolVerdict.assessment.level == .high)
        #expect(deleteToolVerdict.assessment.category == .deletion)

        let rmVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "rm old_build.txt",
            directory: dir,
            workspacePath: dir
        )
        #expect(!rmVerdict.shouldAutoApprove)
        #expect(rmVerdict.assessment.level == .high)
        #expect(rmVerdict.assessment.category == .deletion)

        let unlinkVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "unlink stale_link",
            directory: dir,
            workspacePath: dir
        )
        #expect(!unlinkVerdict.shouldAutoApprove)
        #expect(unlinkVerdict.assessment.level == .high)
        #expect(unlinkVerdict.assessment.category == .deletion)
    }

    @Test func testAutoReviewHighRiskCredentialUse() {
        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"

        let envVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "cat .env",
            directory: dir,
            workspacePath: dir
        )
        #expect(!envVerdict.shouldAutoApprove)
        #expect(envVerdict.assessment.level == .high)
        #expect(envVerdict.assessment.category == .credentialUse)

        let sshVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "cat ~/.ssh/id_ed25519",
            directory: dir,
            workspacePath: dir
        )
        #expect(!sshVerdict.shouldAutoApprove)
        #expect(sshVerdict.assessment.level == .high)
        #expect(sshVerdict.assessment.category == .credentialUse)

        let keychainVerdict = ApprovalAutoReview.review(
            toolName: "run_shell_command",
            command: "security find-generic-password -s MySecret",
            directory: dir,
            workspacePath: dir
        )
        #expect(!keychainVerdict.shouldAutoApprove)
        #expect(keychainVerdict.assessment.level == .high)
        #expect(keychainVerdict.assessment.category == .credentialUse)
    }

    // MARK: - Issue #166 Regression Tests (UserDefaults Injection, Verifier Leftovers, Allowlist Source)

    @Test func testAllowlistSuiteIsolationRoundTripDoesNotTouchStandard() {
        let suiteName = "test.allowlist.isolation.\(UUID().uuidString)"
        guard let testSuite = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated UserDefaults suite")
            return
        }
        testSuite.removePersistentDomain(forName: suiteName)
        defer { testSuite.removePersistentDomain(forName: suiteName) }

        let standardKey = "apex.commandDirectoryAllowlist"
        let standardBefore = UserDefaults.standard.data(forKey: standardKey)

        let allowlist1 = ApprovalAllowlist(userDefaults: testSuite)
        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"
        let cmd = "swift build"
        let entry = allowlist1.allow(command: cmd, directory: dir)

        // Read through a FRESH instance backed by the same test suite
        let allowlist2 = ApprovalAllowlist(userDefaults: testSuite)
        #expect(allowlist2.isAllowed(command: cmd, directory: dir))
        let entries = allowlist2.listEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.id == entry.id)
        #expect(entries.first?.command == cmd)

        // Ensure UserDefaults.standard was NEVER modified
        let standardAfter = UserDefaults.standard.data(forKey: standardKey)
        #expect(standardBefore == standardAfter)
    }

    @Test func testApprovalLiveVerifierLeavesNoGrantBehind() {
        let testDir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"
        let testCmd = "swift test --filter ApprovalTests"

        let (output, passed) = ApprovalLiveVerifier.runVerification()
        #expect(passed, "Live verifier failed with output:\n\(output)")

        // Assert the allowlist in UserDefaults.standard is clean of verifier-created entries
        let freshAllowlist = ApprovalAllowlist(userDefaults: .standard)
        #expect(!freshAllowlist.isAllowed(command: testCmd, directory: testDir))
        #expect(!freshAllowlist.isAllowed(command: "git status", directory: testDir))

        let allEntries = freshAllowlist.listEntries()
        #expect(!allEntries.contains { $0.command == testCmd && ApprovalAllowlist.standardizeDirectory($0.directory) == ApprovalAllowlist.standardizeDirectory(testDir) })
        #expect(!allEntries.contains { $0.command == "git status" && ApprovalAllowlist.standardizeDirectory($0.directory) == ApprovalAllowlist.standardizeDirectory(testDir) })
    }

    @Test @MainActor func testAllowlistApprovalRecordsAllowlistVerdictSource() async {
        let orchestrator = AgentOrchestrator()
        orchestrator.bypassConfirmationInDebug = false

        let suiteName = "test.allowlist.verdict.\(UUID().uuidString)"
        guard let testSuite = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated UserDefaults suite")
            return
        }
        testSuite.removePersistentDomain(forName: suiteName)
        defer { testSuite.removePersistentDomain(forName: suiteName) }

        let allowlist = ApprovalAllowlist(userDefaults: testSuite)
        let dir = "/Users/danielstevens/AI-Workspace/repos/ApexAgent"
        let cmd = "swift test --filter ApprovalTests"

        // Allow command in isolated allowlist
        allowlist.allow(command: cmd, directory: dir)

        let recorder = RunTraceManager.shared.startRun()
        defer { RunTraceManager.shared.endRun(runId: recorder.runId) }

        let approved = await orchestrator.requestConfirmation(
            toolName: "run_shell_command",
            arguments: cmd,
            riskDescription: "Run unit tests",
            command: cmd,
            directory: dir,
            allowlist: allowlist
        )

        #expect(approved)

        // Verify trace event recorded source as .allowlist
        let trace = recorder.currentTraceSnapshot()
        let approvalEvents = trace.events.filter { $0.kind == .approval }
        #expect(!approvalEvents.isEmpty)
        let lastApproval = approvalEvents.last
        #expect(lastApproval?.verdictSource == ApprovalVerdictSource.allowlist.rawValue)
        #expect(lastApproval?.rule == ActionRiskCategory.allowlisted.rawValue)
    }
}
