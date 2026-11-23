import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Goal Mode Tests (Issue #79)")
struct GoalModeTests {

    private func createTempWorkspace(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // MARK: - 1. Goal Persistence Across Restarts

    @Test("Goal persists across a fresh service instance (simulating restart)")
    func testGoalPersistenceAcrossServiceRestart() async throws {
        let tempDir = try createTempWorkspace(prefix: "goal-restart-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service1 = GoalModeService(workspaceURL: tempDir)
        let initialGoal = try await service1.createGoal(
            title: "Build Distributed Queue",
            objective: "Implement resilient priority queue with persistent storage and crash recovery.",
            criteria: [
                "Queue partition manager",
                "WAL log compactor",
                "Dead letter queue routing"
            ],
            metadata: ["tier": "critical", "environment": "production"]
        )

        _ = try await service1.appendLedgerEntry(kind: .step, text: "Partition manager scaffolding in place.", stepId: "s1", criterionId: "c1")
        _ = try await service1.appendLedgerEntry(kind: .step, text: "WAL compactor initial benchmarks completed.", stepId: "s2", criterionId: "c2")

        // Create a completely fresh instance simulating an app restart
        let service2 = GoalModeService(workspaceURL: tempDir)
        let loadedGoal = try await service2.loadActiveGoal()

        #expect(loadedGoal != nil)
        #expect(loadedGoal?.id == initialGoal.id)
        #expect(loadedGoal?.title == "Build Distributed Queue")
        #expect(loadedGoal?.objective == initialGoal.objective)
        #expect(loadedGoal?.successCriteria.count == 3)
        #expect(loadedGoal?.metadata["tier"] == "critical")

        // Verify ledger persistence
        let reloadedLedger = await service2.getLedger()
        #expect(reloadedLedger.count == 3) // 1 initial plan + 2 steps
        #expect(reloadedLedger[0].kind == .plan)
        #expect(reloadedLedger[1].text == "Partition manager scaffolding in place.")
        #expect(reloadedLedger[2].text == "WAL compactor initial benchmarks completed.")

        // Verify physical files on disk in the files-first memory tier
        let goalMdPath = service2.goalMarkdownURL(for: initialGoal.id).path
        let goalJsonPath = service2.goalFileURL(for: initialGoal.id).path
        let ledgerMdPath = service2.ledgerMarkdownURL(for: initialGoal.id).path
        let ledgerJsonlPath = service2.ledgerJSONLURL(for: initialGoal.id).path

        #expect(FileManager.default.fileExists(atPath: goalMdPath))
        #expect(FileManager.default.fileExists(atPath: goalJsonPath))
        #expect(FileManager.default.fileExists(atPath: ledgerMdPath))
        #expect(FileManager.default.fileExists(atPath: ledgerJsonlPath))

        let mdContent = try String(contentsOfFile: goalMdPath, encoding: .utf8)
        #expect(mdContent.contains("# Goal: Build Distributed Queue"))
        #expect(mdContent.contains("Queue partition manager"))
    }

    // MARK: - 2. Ledger Entries Append-Only Invariant

    @Test("Ledger entries append and are never rewritten or deleted")
    func testLedgerAppendOnlyAndNeverRewritten() async throws {
        let tempDir = try createTempWorkspace(prefix: "goal-ledger-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = GoalModeService(workspaceURL: tempDir)
        let goal = try await service.createGoal(
            title: "Security Hardening",
            objective: "Enforce TLS 1.3 and secret rotation across all microservices.",
            criteria: ["Audit cipher suites", "Rotate database credentials"]
        )

        let jsonlURL = service.ledgerJSONLURL(for: goal.id)

        // Capture snapshot after creation (entry #1: initial plan)
        let initialJSONL = try String(contentsOf: jsonlURL, encoding: .utf8)
        #expect(!initialJSONL.isEmpty)

        // Append 4 distinct entries
        _ = try await service.appendLedgerEntry(kind: .step, text: "TLS 1.3 verification passed on ingress.", stepId: "step-1", criterionId: "c1")
        _ = try await service.appendLedgerEntry(kind: .setback, text: "Credential rotation failed: lock timeout on replica.", stepId: "step-2", criterionId: "c2")
        _ = try await service.appendLedgerEntry(kind: .plan, text: "Attempt credential rotation with increased lease timeout.")
        _ = try await service.appendLedgerEntry(kind: .step, text: "Database credentials rotated successfully.", stepId: "step-3", criterionId: "c2")

        let fullLedger = await service.getLedger()
        #expect(fullLedger.count == 5)

        // Verify sequence numbers are strictly 1, 2, 3, 4, 5
        for (idx, entry) in fullLedger.enumerated() {
            #expect(entry.sequenceNumber == idx + 1)
        }

        // Verify disk content preserves the original prefix byte-for-byte
        let updatedJSONL = try String(contentsOf: jsonlURL, encoding: .utf8)
        #expect(updatedJSONL.hasPrefix(initialJSONL), "Ledger file must strictly prepend prior content without rewriting")

        let lines = updatedJSONL.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(lines.count == 5)

        // Markdown ledger check
        let mdURL = service.ledgerMarkdownURL(for: goal.id)
        let mdContent = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(mdContent.contains("[PLAN]"))
        #expect(mdContent.contains("[STEP]"))
        #expect(mdContent.contains("[SETBACK]"))
        #expect(mdContent.contains("Credential rotation failed"))
    }

    // MARK: - 3. Re-plan Reflects Recorded Setback

    @Test("Re-plan reflects recorded setbacks and avoids repeating failed actions")
    func testReplanReflectsRecordedSetbacks() async throws {
        let tempDir = try createTempWorkspace(prefix: "goal-replan-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = GoalModeService(workspaceURL: tempDir)
        let goal = try await service.createGoal(
            title: "Automate Database Failover",
            objective: "Configure automatic failover with zero data loss.",
            criteria: [
                "Setup health probes",
                "Configure replication sync",
                "Automate DNS traffic swing"
            ]
        )

        // Step 1: Health probes succeeded
        _ = try await service.updateCriterionStatus(criterionId: "c1", status: .completed, notes: "Health probes green.")

        // Step 2: Setback on replication sync
        _ = try await service.appendLedgerEntry(
            kind: .setback,
            text: "Replication sync failed: primary WAL archive disk full on node db-1.",
            stepId: "repl-1",
            criterionId: "c2"
        )

        // Trigger re-plan
        let plan = try await service.replan()

        // Completed criterion c1 should NOT be in the planned steps
        #expect(!plan.steps.contains(where: { $0.criterionId == "c1" }))

        // Criterion c2 must have an adapted step accounting for the setback
        guard let c2Step = plan.steps.first(where: { $0.criterionId == "c2" }) else {
            Issue.record("Expected planned step for criterion c2")
            return
        }

        #expect(c2Step.id.contains("alt"), "Plan must produce alternative step for setback criterion")
        #expect(c2Step.avoidSetbacks.contains(where: { $0.contains("WAL archive disk full") }))
        #expect(c2Step.rationale.contains("Adapting strategy to avoid repeating failure"))

        // Standard criterion c3 should have a regular step
        guard let c3Step = plan.steps.first(where: { $0.criterionId == "c3" }) else {
            Issue.record("Expected planned step for criterion c3")
            return
        }
        #expect(c3Step.avoidSetbacks.isEmpty)

        // Verify plan is appended to ledger
        let ledger = await service.getLedger()
        let lastEntry = ledger.last
        #expect(lastEntry?.kind == .plan)
        #expect(lastEntry?.text.contains("Re-plan generated") == true)
    }

    // MARK: - 4. Progress Reporting (Blocked Stays Blocked)

    @Test("Progress against success criteria is reported honestly (blocked stays blocked)")
    func testHonestProgressReportingBlockedStaysBlocked() async throws {
        let tempDir = try createTempWorkspace(prefix: "goal-progress-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = GoalModeService(workspaceURL: tempDir)
        _ = try await service.createGoal(
            title: "Third-Party OAuth Migration",
            objective: "Migrate auth provider to OAuth 2.1 PKCE.",
            criteria: [
                "Create OAuth app client",
                "Configure callback URLs",
                "Migrate legacy user tokens"
            ]
        )

        // Complete criterion 1
        _ = try await service.updateCriterionStatus(criterionId: "c1", status: .completed, notes: "Client ID created.")

        // Block criterion 2 with an unrecoverable setback
        _ = try await service.updateCriterionStatus(
            criterionId: "c2",
            status: .blocked,
            blockedReason: "Identity provider blocked domain callback: enterprise admin approval required."
        )

        let report = await service.reportProgress()

        // Strict honest reporting:
        // NEVER "mostly done" or "in progress" when a criterion is blocked!
        #expect(report.overallStatus == .blocked)
        #expect(report.completedCriteria == 1)
        #expect(report.blockedCriteria == 1)
        #expect(report.pendingCriteria == 1)
        #expect(report.totalCriteria == 3)
        #expect(report.activeBlockers.count == 1)
        #expect(report.activeBlockers[0].contains("enterprise admin approval required"))

        // Complete goal should be rejected while blocked
        let canComplete = try await service.completeGoalIfEligible()
        #expect(canComplete == false, "Goal cannot be completed while criteria are blocked")
    }

    // MARK: - 5. Completed Goal Reports Done Only When All Criteria Met

    @Test("Completed goal reports done only when its criteria are met")
    func testCompletedGoalReportsDoneOnlyWhenCriteriaMet() async throws {
        let tempDir = try createTempWorkspace(prefix: "goal-completion-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = GoalModeService(workspaceURL: tempDir)
        let goal = try await service.createGoal(
            title: "API Rate Limiter",
            objective: "Implement token bucket rate limiter for REST API.",
            criteria: [
                "Implement token bucket algorithm",
                "Integrate Redis backend"
            ]
        )

        // Phase 1: Only 1 criterion completed
        _ = try await service.updateCriterionStatus(criterionId: "c1", status: .completed, notes: "Algorithm verified.")

        var report = await service.reportProgress()
        #expect(report.overallStatus == .inProgress)
        #expect(try await service.completeGoalIfEligible() == false)
        #expect(await service.activeGoal?.status == .active)

        // Phase 2: Complete remaining criterion
        _ = try await service.updateCriterionStatus(criterionId: "c2", status: .completed, notes: "Redis backend cluster connected.")

        report = await service.reportProgress()
        #expect(report.overallStatus == .done)
        #expect(report.completedCriteria == 2)
        #expect(report.totalCriteria == 2)

        // Now completion succeeds
        let completed = try await service.completeGoalIfEligible()
        #expect(completed == true)

        let finishedGoal = await service.activeGoal
        #expect(finishedGoal?.status == .completed)

        // Ledger must record the completion event
        let ledger = await service.getLedger()
        let finalEntry = ledger.last
        #expect(finalEntry?.kind == .step)
        #expect(finalEntry?.text.contains("Goal marked completed") == true)

        // Execute live verifier to produce runs/issue79/live-verify.log
        let verifierResult = await GoalModeLiveVerifier.runVerification(writeLogTo: "runs/issue79/live-verify.log")
        #expect(verifierResult.passed == true, "Live verifier must pass all 5 verdicts")
    }
}
