import Foundation

// MARK: - Goal Mode Live Verifier (Issue #79)
//
// Live verification running against the real app runtime to prove:
// VERDICT 1: A goal is created and persists across a restart (fresh instance reads it back).
// VERDICT 2: Ledger entries accumulate visibly as work proceeds (append-only ledger).
// VERDICT 3: A re-plan after a recorded setback changes the plan (it does not repeat the failed step).
// VERDICT 4: Progress reporting matches the success criteria state (blocked stays blocked).
// VERDICT 5: Completing all criteria flips the goal to done (only when all criteria met).

public enum GoalModeLiveVerifier {

    public static func runVerification(writeLogTo: String? = "runs/issue79/live-verify.log") async -> (output: String, passed: Bool) {
        var logs: [String] = []
        var allPassed = true

        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #79: GOAL MODE (A5) LIVE VERIFICATION")
        logs.append("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        logs.append("Environment: macOS 27.0, Swift 6.4, Native App Execution")
        logs.append("================================================================================")

        let tempWorkspace = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("apexagent-issue79-live-verify-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempWorkspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempWorkspace)
        }

        logs.append("\n[Seeding Temporary Goal Workspace at: \(tempWorkspace.path)]")

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 1: A goal is created and persists across a restart.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 1] Creating Goal in Instance 1 and Reloading from Fresh Instance 2:")
        let service1 = GoalModeService(workspaceURL: tempWorkspace)
        var goal1Id: UUID?

        do {
            let g1 = try await service1.createGoal(
                title: "Launch Production Microservice",
                objective: "Deploy fault-tolerant containerized service with telemetry and automated backups.",
                criteria: [
                    "Provision high-availability PostgreSQL cluster",
                    "Deploy API service container with health endpoints",
                    "Verify automated disaster recovery backups"
                ]
            )
            goal1Id = g1.id
            logs.append("Instance 1 created goal '\(g1.title)' with ID \(g1.id.uuidString).")
            _ = try await service1.appendLedgerEntry(kind: .step, text: "Initial infrastructure checklist verified.")
        } catch {
            logs.append("Instance 1 failed to create goal: \(error)")
            allPassed = false
        }

        // Fresh instance 2 simulating app restart
        let service2 = GoalModeService(workspaceURL: tempWorkspace)
        let loadedGoal = try? await service2.loadActiveGoal()
        let ledgerAfterRestart = await service2.getLedger()

        let v1Pass = (loadedGoal != nil) &&
                     (loadedGoal?.id == goal1Id) &&
                     (loadedGoal?.successCriteria.count == 3) &&
                     (ledgerAfterRestart.count >= 2)

        if v1Pass {
            logs.append("VERDICT 1: PASS — goal is created and persists across a restart (fresh instance reads back identical goal and \(ledgerAfterRestart.count) ledger entries).")
        } else {
            logs.append("VERDICT 1: FAIL — fresh instance could not read back active goal or ledger.")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 2: Ledger entries accumulate visibly as work proceeds.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 2] Appending Ledger Entries (Strict Append-Only Invariant):")
        var v2Pass = false
        do {
            _ = try await service2.appendLedgerEntry(kind: .step, text: "Database cluster nodes online.", stepId: "step-1", criterionId: "c1")
            _ = try await service2.appendLedgerEntry(kind: .step, text: "Configured TLS 1.3 certificates.", stepId: "step-2")
            let e3 = try await service2.appendLedgerEntry(kind: .setback, text: "Container image pull failed: registry rate limit reached.", stepId: "step-3", criterionId: "c2")

            let fullLedger = await service2.getLedger()
            logs.append("Ledger now contains \(fullLedger.count) entries.")

            // Verify strictly increasing sequence numbers
            var strictlyIncreasing = true
            for i in 1..<fullLedger.count {
                if fullLedger[i].sequenceNumber != fullLedger[i - 1].sequenceNumber + 1 {
                    strictlyIncreasing = false
                    break
                }
            }

            // Verify disk files
            let mdURL = service2.ledgerMarkdownURL(for: loadedGoal!.id)
            let jsonlURL = service2.ledgerJSONLURL(for: loadedGoal!.id)
            let mdExists = FileManager.default.fileExists(atPath: mdURL.path)
            let jsonlExists = FileManager.default.fileExists(atPath: jsonlURL.path)
            let jsonlContent = (try? String(contentsOf: jsonlURL, encoding: .utf8)) ?? ""
            let jsonlLines = jsonlContent.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

            v2Pass = strictlyIncreasing && mdExists && jsonlExists && jsonlLines.count == fullLedger.count && e3.kind == .setback
            if v2Pass {
                logs.append("VERDICT 2: PASS — ledger entries accumulate visibly as work proceeds (append-only ledger holds \(fullLedger.count) entries, sequenced #1..#\(fullLedger.count)).")
            } else {
                logs.append("VERDICT 2: FAIL — ledger entries sequence or disk consistency check failed.")
                allPassed = false
            }
        } catch {
            logs.append("VERDICT 2: FAIL — exception appending ledger entries: \(error)")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 3: Re-plan after recorded setback changes the plan.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 3] Re-planning Against Recorded Setback:")
        var v3Pass = false
        do {
            let plan = try await service2.replan()
            logs.append("Re-plan generated \(plan.steps.count) steps: '\(plan.summary)'")
            for step in plan.steps {
                logs.append("  * [\(step.id)] \(step.title): \(step.rationale)")
                if !step.avoidSetbacks.isEmpty {
                    logs.append("    Avoiding: \(step.avoidSetbacks.joined(separator: ", "))")
                }
            }

            // Check that criterion c2 has an adapted step that avoids repeating the registry failure
            let c2Step = plan.steps.first(where: { $0.criterionId == "c2" })
            let avoidsRegistryFailure = c2Step?.avoidSetbacks.contains(where: { $0.contains("registry rate limit") }) ?? false
            let doesNotRepeatFailedAction = (c2Step?.id.contains("alt") ?? false) && avoidsRegistryFailure

            v3Pass = doesNotRepeatFailedAction
            if v3Pass {
                logs.append("VERDICT 3: PASS — re-plan after recorded setback changed the plan (produced alternative step avoiding failed registry pull).")
            } else {
                logs.append("VERDICT 3: FAIL — re-plan did not account for setback or repeated failed action.")
                allPassed = false
            }
        } catch {
            logs.append("VERDICT 3: FAIL — exception during replan: \(error)")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 4: Progress reporting matches success criteria state (blocked stays blocked).
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 4] Progress Reporting & Blocked State Integrity:")
        var v4Pass = false
        do {
            // Mark c1 completed, but mark c3 explicitly blocked
            _ = try await service2.updateCriterionStatus(criterionId: "c1", status: .completed, notes: "PostgreSQL cluster active and healthy.")
            _ = try await service2.updateCriterionStatus(criterionId: "c3", status: .blocked, blockedReason: "Backup bucket permissions denied (403 Forbidden).")

            let report = await service2.reportProgress()
            logs.append("Progress Assessment: \(report.overallStatus.rawValue) (\(report.completedCriteria)/\(report.totalCriteria) completed, \(report.blockedCriteria) blocked).")
            logs.append("Summary: \(report.summary)")

            // Crucial: blocked criteria MUST cause overall progress to be .blocked, not vaguely "mostly done"
            let isHonestBlocked = (report.overallStatus == .blocked) && (report.blockedCriteria == 1) && (report.completedCriteria == 1)

            // Attempting to complete must be rejected
            let completeAttempt = try await service2.completeGoalIfEligible()
            let rejectedPrematureComplete = !completeAttempt

            v4Pass = isHonestBlocked && rejectedPrematureComplete
            if v4Pass {
                logs.append("VERDICT 4: PASS — progress reporting matches success criteria state (blocked stays blocked; premature completion rejected).")
            } else {
                logs.append("VERDICT 4: FAIL — progress reporting was dishonest or allowed completion with blocked criteria.")
                allPassed = false
            }
        } catch {
            logs.append("VERDICT 4: FAIL — exception testing progress reporting: \(error)")
            allPassed = false
        }

        // ─────────────────────────────────────────────────────────────────────
        // VERDICT 5: Completing all criteria flips the goal to done.
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[Check 5] Completing All Criteria and Verifying Goal Done:")
        var v5Pass = false
        do {
            // Unblock and complete c2 and c3
            _ = try await service2.updateCriterionStatus(criterionId: "c2", status: .completed, notes: "API service running with healthy endpoints.")
            _ = try await service2.updateCriterionStatus(criterionId: "c3", status: .completed, notes: "Backup permissions granted and disaster recovery tested.")

            let reportDone = await service2.reportProgress()
            let completeSuccess = try await service2.completeGoalIfEligible()
            let reloadedAfterComplete = try await service2.loadActiveGoal()

            v5Pass = (reportDone.overallStatus == .done) &&
                     (reportDone.completedCriteria == 3) &&
                     completeSuccess &&
                     (reloadedAfterComplete?.status == .completed)

            if v5Pass {
                logs.append("VERDICT 5: PASS — completing all criteria flips the goal to done (goal status is COMPLETED; criteria 3/3 satisfied).")
            } else {
                logs.append("VERDICT 5: FAIL — goal did not report done or complete successfully after all criteria were met.")
                allPassed = false
            }
        } catch {
            logs.append("VERDICT 5: FAIL — exception testing goal completion: \(error)")
            allPassed = false
        }

        logs.append("\n================================================================================")
        logs.append("LIVE VERIFICATION SUMMARY: \(allPassed ? "ALL 5 VERDICTS PASSED" : "FAILED")")
        logs.append("================================================================================")

        let output = logs.joined(separator: "\n")

        // Write log file if requested
        if let logPath = writeLogTo {
            let logURL = URL(fileURLWithPath: logPath)
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? output.write(to: logURL, atomically: true, encoding: .utf8)
        }

        return (output, allPassed)
    }
}
