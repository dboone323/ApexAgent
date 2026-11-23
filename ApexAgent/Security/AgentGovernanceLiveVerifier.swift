//
//  AgentGovernanceLiveVerifier.swift
//  ApexAgent
//
//  Issue #181: Live functional verifier for Agent Governance (Agent 365-style):
//  spend limits, value in work completed, block/approve agents, free-tier guardrails.
//

import Foundation
import os

public enum AgentGovernanceLiveVerifier {

    public struct VerificationResult: Sendable {
        public let output: String
        public let passed: Bool
        public let totalChecks: Int
        public let passedChecks: Int
    }

    public static func runVerification(
        logPath: String? = nil,
        jsonOutput: Bool = false
    ) async -> VerificationResult {
        var logs: [String] = []
        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())

        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #181: AGENT GOVERNANCE LIVE VERIFICATION")
        logs.append("Timestamp: \(timestamp)")
        logs.append("Host: Darwin arm64 — Spend Limits, Value in Work Completed, Approve/Block, Free-Tier")
        logs.append("================================================================================")

        var allPassed = true
        var passedChecks = 0
        let totalChecks = 7

        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()

        // -------------------------------------------------------------------------
        // CHECK 1: A spend cap set for an agent is enforced: a run that would exceed
        //          it is stopped with a visible notice naming the agent, the cap, and
        //          the spend so far — $0 over-spend.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 1] Spend Cap Enforcement & $0 Over-Spend Guarantee:")
        governance.setSpendLimit(
            scopeKey: "agent:coder",
            scopeKind: .agent,
            limit: 1.00,
            alertThresholdPercent: 0.80,
            reason: "Testing spend cap enforcement",
            actor: "test"
        )
        // Record prior spend of $0.85
        governance.recordSpend(agentId: "coder", amount: 0.85, tokens: 2000)

        // Attempt execution that would cost $0.25 (projected $1.10 > $1.00 cap)
        let evalResult = governance.evaluateExecution(
            agentId: "coder",
            estimatedCost: 0.25
        )

        let initialSpend = governance.spendLimit(for: "agent:coder")?.currentSpend ?? 0.0
        let check1RefusalValid = !evalResult.allowed && (evalResult.refusalReason != nil)
        let noticeContainsDetails = (evalResult.refusalReason?.contains("Codex") == true || evalResult.refusalReason?.contains("coder") == true)
            && (evalResult.refusalReason?.contains("1.00") == true)
            && (evalResult.refusalReason?.contains("0.85") == true)
        let zeroOverspend = (initialSpend == 0.85)

        logs.append("  -> Allowed: \(evalResult.allowed)")
        logs.append("  -> Refusal Notice: \(evalResult.refusalReason ?? "none")")
        logs.append("  -> Spend before: $0.85, spend after stopped run: $\(String(format: "%.2f", initialSpend)) ($0 over-spend)")

        let check1Passed = check1RefusalValid && noticeContainsDetails && zeroOverspend
        if check1Passed {
            passedChecks += 1
            logs.append("VERDICT 1: PASS (spend cap set for agent stopped run with visible notice naming agent, cap, and spend so far with $0 over-spend)")
        } else {
            allPassed = false
            logs.append("VERDICT 1: FAIL (spend cap check failed: allowed=\(evalResult.allowed), details=\(noticeContainsDetails), zeroOverspend=\(zeroOverspend))")
        }

        // -------------------------------------------------------------------------
        // CHECK 2: An agent can be blocked and approved: a blocked agent's run is
        //          refused with a clear reason; after approval it runs again.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 2] Block and Approve Lifecycle:")
        governance.blockAgent(id: "developer", reason: "Security review pending", actor: "admin")
        let isBlocked = governance.isAgentBlocked(id: "developer")
        let blockedEval = governance.evaluateExecution(agentId: "developer")

        let blockedReasonValid = !blockedEval.allowed
            && (blockedEval.refusalReason?.contains("blocked by governance policy") == true)
            && (blockedEval.refusalReason?.contains("Developer") == true || blockedEval.refusalReason?.contains("developer") == true)

        logs.append("  -> Blocked status: \(isBlocked)")
        logs.append("  -> Blocked evaluation allowed: \(blockedEval.allowed)")
        logs.append("  -> Blocked refusal notice: \(blockedEval.refusalReason ?? "none")")

        // Now approve the agent
        governance.approveAgent(id: "developer", reason: "Security review passed", actor: "admin")
        let isApproved = !governance.isAgentBlocked(id: "developer")
        let approvedEval = governance.evaluateExecution(agentId: "developer")

        logs.append("  -> Unblocked status: \(isApproved)")
        logs.append("  -> Approved evaluation allowed: \(approvedEval.allowed)")

        let check2Passed = isBlocked && blockedReasonValid && isApproved && approvedEval.allowed
        if check2Passed {
            passedChecks += 1
            logs.append("VERDICT 2: PASS (agent can be blocked and approved; blocked run refused with clear reason naming agent and block; approved run succeeds)")
        } else {
            allPassed = false
            logs.append("VERDICT 2: FAIL (block/approve cycle failed: isBlocked=\(isBlocked), reasonValid=\(blockedReasonValid), isApproved=\(isApproved), approvedEval=\(approvedEval.allowed))")
        }

        // -------------------------------------------------------------------------
        // CHECK 3: A risky action requires human approval through the existing
        //          approval system before proceeding.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 3] Risky Action Routing Through Existing Approval System:")
        // Check 3a: Agent lacks shell execution permission
        let verdictNoShell = governance.checkActionRisk(
            agentId: "reviewer",
            toolName: "run_shell_command",
            command: "git status",
            arguments: "git status"
        )
        logs.append("  -> Reviewer shell request requires human approval: \(verdictNoShell.requiresHumanApproval), reason: \(verdictNoShell.reason)")

        // Check 3b: Destructive or network action on agent with shell permission
        let verdictDestructive = governance.checkActionRisk(
            agentId: "executor",
            toolName: "run_shell_command",
            command: "rm -rf /tmp/test-issue181",
            arguments: "rm -rf /tmp/test-issue181"
        )
        logs.append("  -> Executor destructive command requires human approval: \(verdictDestructive.requiresHumanApproval), riskCategory: \(verdictDestructive.riskCategory ?? "nil")")

        // Check 3c: Safe read-only action auto-approves
        let verdictSafe = governance.checkActionRisk(
            agentId: "coder",
            toolName: "read_file",
            command: "",
            arguments: "{\"filePath\":\"README.md\"}"
        )
        logs.append("  -> Coder safe read requires human approval: \(verdictSafe.requiresHumanApproval) (auto-approved)")

        let check3Passed = verdictNoShell.requiresHumanApproval
            && verdictDestructive.requiresHumanApproval
            && !verdictSafe.requiresHumanApproval
        if check3Passed {
            passedChecks += 1
            logs.append("VERDICT 3: PASS (risky actions require human approval through approval system while safe inspection operations proceed)")
        } else {
            allPassed = false
            logs.append("VERDICT 3: FAIL (risky action check failed: noShell=\(verdictNoShell.requiresHumanApproval), destructive=\(verdictDestructive.requiresHumanApproval), safe=\(!verdictSafe.requiresHumanApproval))")
        }

        // -------------------------------------------------------------------------
        // CHECK 4: Value analytics shows work completed (tasks done, PRs merged,
        //          verified runs) per agent / model / Space — with tokens/cost alongside.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 4] Value Analytics (Work Completed Beyond Just Tokens):")
        let spaceId = UUID()
        let testModelId = "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"

        governance.recordWorkCompleted(
            agentId: "coder",
            spaceId: spaceId,
            modelId: testModelId,
            tasksDone: 4,
            prsMerged: 2,
            verifiedRuns: 3,
            tokens: 18450,
            cost: 0.0
        )

        let analytics = governance.valueAnalytics(for: "coder")
        guard let coderValue = analytics.first(where: { $0.spaceId == spaceId }) else {
            allPassed = false
            logs.append("VERDICT 4: FAIL (no value record found for coder in space)")
            return VerificationResult(output: logs.joined(separator: "\n"), passed: false, totalChecks: totalChecks, passedChecks: passedChecks)
        }

        logs.append("  -> Agent: \(coderValue.displayName) (ID: \(coderValue.agentId))")
        logs.append("  -> Space: \(spaceId.uuidString.prefix(8))")
        logs.append("  -> Tasks Done: \(coderValue.tasksCompleted)")
        logs.append("  -> PRs Merged: \(coderValue.prsMerged)")
        logs.append("  -> Verified Runs: \(coderValue.verifiedRuns)")
        logs.append("  -> Tokens: \(coderValue.totalTokens), Cost: $\(String(format: "%.4f", coderValue.totalCost))")

        let check4Passed = (coderValue.tasksCompleted == 4)
            && (coderValue.prsMerged == 2)
            && (coderValue.verifiedRuns == 3)
            && (coderValue.totalTokens == 18450)
            && (coderValue.totalCost == 0.0)

        if check4Passed {
            passedChecks += 1
            logs.append("VERDICT 4: PASS (value analytics shows work completed: tasks done, PRs merged, verified runs per agent/model/Space with tokens and cost alongside)")
        } else {
            allPassed = false
            logs.append("VERDICT 4: FAIL (value analytics data mismatch: tasks=\(coderValue.tasksCompleted), prs=\(coderValue.prsMerged), verified=\(coderValue.verifiedRuns))")
        }

        // -------------------------------------------------------------------------
        // CHECK 5: The governance view shows one agent's identity + permissions +
        //          spend vs cap + value together, in one place.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 5] Unified Governance View:")
        let viewSummary = governance.governanceSummaryView(for: "coder")
        logs.append("----- VIEW OUTPUT BEGIN -----")
        logs.append(viewSummary)
        logs.append("----- VIEW OUTPUT END -----")

        let containsIdentity = viewSummary.contains("Agent: Codex") && viewSummary.contains("ID: coder") && viewSummary.contains("APPROVED")
        let containsPermissions = viewSummary.contains("Permissions:") && viewSummary.contains("read_workspace")
        let containsSpendVsCap = viewSummary.contains("Spend vs Cap:")
        let containsWorkValue = viewSummary.contains("Work Value:") && viewSummary.contains("Tasks Done:") && viewSummary.contains("PRs Merged:")
        let containsEfficiency = viewSummary.contains("Efficiency:") && viewSummary.contains("Tokens:") && viewSummary.contains("Cost:")

        let check5Passed = containsIdentity && containsPermissions && containsSpendVsCap && containsWorkValue && containsEfficiency
        if check5Passed {
            passedChecks += 1
            logs.append("VERDICT 5: PASS (governance view shows agent identity, permissions, spend vs cap, and work value together in one place)")
        } else {
            allPassed = false
            logs.append("VERDICT 5: FAIL (governance view missing sections: id=\(containsIdentity), perms=\(containsPermissions), spend=\(containsSpendVsCap), work=\(containsWorkValue), eff=\(containsEfficiency))")
        }

        // -------------------------------------------------------------------------
        // CHECK 6: Free-tier: governance works with $0 spend and local models,
        //          and governance decisions are written to audit log and readable.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 6] Free-Tier Zero-Spend Guardrails & Audit Trail:")
        // Verify default global limit is $0.00
        let globalLimit = governance.spendLimit(for: "global")
        let isDefaultFreeTier = (globalLimit?.spendLimit == 0.0)

        // Attempting paid model spend on free-tier cap
        let paidAttempt = governance.evaluateExecution(
            agentId: "executor",
            estimatedCost: 0.004
        )
        let paidBlockedOnZeroSpend = !paidAttempt.allowed

        // Local free model run (cost: 0.0) succeeds
        let localFreeAttempt = governance.evaluateExecution(
            agentId: "executor",
            estimatedCost: 0.0
        )
        let localAllowed = localFreeAttempt.allowed

        // Inspect audit log
        let auditEntries = governance.decisionAuditLog(limit: 50)
        let hasApproveAction = auditEntries.contains { $0.action == "approve" }
        let hasBlockAction = auditEntries.contains { $0.action == "block" }
        let hasCapStopAction = auditEntries.contains { $0.action == "hard_cap_stop" }

        logs.append("  -> Global limit default: $\(String(format: "%.2f", globalLimit?.spendLimit ?? -1.0)) (free-tier safe)")
        logs.append("  -> Paid execution under $0 cap stopped: \(paidBlockedOnZeroSpend)")
        logs.append("  -> Local $0 model execution allowed: \(localAllowed)")
        logs.append("  -> Audit log entry count: \(auditEntries.count)")
        logs.append("  -> Audit contains approve: \(hasApproveAction), block: \(hasBlockAction), hard_cap_stop: \(hasCapStopAction)")

        let check6Passed = isDefaultFreeTier && paidBlockedOnZeroSpend && localAllowed && hasApproveAction && hasBlockAction && hasCapStopAction
        if check6Passed {
            passedChecks += 1
            logs.append("VERDICT 6: PASS (free-tier governance enforces $0 spend cap stopping paid runs while allowing local models, with all decisions recorded in audit log)")
        } else {
            allPassed = false
            logs.append("VERDICT 6: FAIL (free-tier audit check failed: freeTier=\(isDefaultFreeTier), paidBlocked=\(paidBlockedOnZeroSpend), localAllowed=\(localAllowed), auditApprove=\(hasApproveAction), auditBlock=\(hasBlockAction), auditCap=\(hasCapStopAction))")
        }

        // -------------------------------------------------------------------------
        // CHECK 7: Persistence — set a block + a cap, recreate the manager from
        //          stored state, and verify the block and cap are still in force.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 7] Governance State Persistence Across Launches:")
        governance.blockAgent(id: "reviewer", reason: "Verifier persistence test", actor: "verifier")
        governance.setSpendLimit(
            scopeKey: "agent:reviewer",
            scopeKind: .agent,
            limit: 42.00,
            alertThresholdPercent: 0.80,
            reason: "Verifier persistence cap",
            actor: "verifier"
        )
        governance.recordSpend(agentId: "reviewer", amount: 10.50, tokens: 3000)

        // Recreate manager to simulate app restart
        let relaunchedGovernance = AgentGovernanceManager(userDefaults: .standard)
        let reviewerRecord = relaunchedGovernance.agent(for: "reviewer")
        let isReviewerBlocked = reviewerRecord?.status == .blocked
        let capRecord = relaunchedGovernance.spendLimit(for: "agent:reviewer")
        let capSurvives = capRecord?.spendLimit == 42.00 && capRecord?.currentSpend == 10.50
        let recentDecisions = relaunchedGovernance.decisionAuditLog()
        let auditSurvives = recentDecisions.contains { $0.action == "block" && $0.targetId == "reviewer" }

        logs.append("  -> Reviewer blocked persists: \(isReviewerBlocked)")
        logs.append("  -> Reviewer spend limit $42.00 and spend $10.50 persists: \(capSurvives)")
        logs.append("  -> Reviewer block decision in audit log persists: \(auditSurvives)")

        let check7Passed = isReviewerBlocked && capSurvives && auditSurvives
        if check7Passed {
            passedChecks += 1
            logs.append("VERDICT 7: PASS (governance state persists across launches: blocks, spend limits, spend totals, and decision log survive restart)")
        } else {
            allPassed = false
            logs.append("VERDICT 7: FAIL (persistence check failed: blocked=\(isReviewerBlocked), capSurvives=\(capSurvives), auditSurvives=\(auditSurvives))")
        }

        // Summary
        logs.append("\n================================================================================")
        logs.append("SUMMARY: \(passedChecks)/\(totalChecks) CHECKS PASSED. ALL PASS: \(allPassed)")
        logs.append("================================================================================")

        var outputText = logs.joined(separator: "\n")

        // Write output to log file if path provided (with loud failure on error)
        if let path = logPath {
            let url = URL(fileURLWithPath: path)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try outputText.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let fatalMsg = "FATAL ERROR: Failed to write verification log to '\(path)': \(error.localizedDescription)"
                logs.append(fatalMsg)
                allPassed = false
                outputText = logs.joined(separator: "\n")
            }
        }

        // Clean up verifier state so subsequent tests start clean
        governance.resetToDefaults()

        return VerificationResult(
            output: outputText,
            passed: allPassed,
            totalChecks: totalChecks,
            passedChecks: passedChecks
        )
    }
}
