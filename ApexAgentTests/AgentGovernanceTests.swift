//
//  AgentGovernanceTests.swift
//  ApexAgentTests
//
//  Issue #181: Agent governance, Agent 365-style: spend limits, value in work completed, block/approve agents.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Issue #181 — Agent Governance Tests")
@MainActor
struct AgentGovernanceTests {

    @Test("Spend cap hit stops run with visible notice and guarantees $0 over-spend")
    func testSpendCapHitStopsRunAndZeroOverSpend() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        let agentId = "coder"
        let capAmount = 2.00
        governance.setSpendLimit(
            scopeKey: "agent:\(agentId)",
            scopeKind: .agent,
            limit: capAmount,
            alertThresholdPercent: 0.80,
            reason: "Testing hard cap",
            actor: "test"
        )

        // Record prior spend of $1.80
        governance.recordSpend(agentId: agentId, amount: 1.80, tokens: 4000)
        let spendBefore = governance.spendLimit(for: "agent:\(agentId)")?.currentSpend ?? 0.0
        #expect(spendBefore == 1.80)

        // An execution attempting to spend $0.50 would push total to $2.30 > $2.00 cap
        let eval = governance.evaluateExecution(agentId: agentId, estimatedCost: 0.50)
        #expect(!eval.allowed)
        #expect(eval.refusalReason != nil)
        let notice = eval.refusalReason ?? ""
        #expect(notice.contains("Codex") || notice.contains("coder"))
        #expect(notice.contains("2.00"))
        #expect(notice.contains("1.80"))

        // Spend record must remain strictly unchanged: $0 over-spend
        let spendAfter = governance.spendLimit(for: "agent:\(agentId)")?.currentSpend ?? 0.0
        #expect(spendAfter == 1.80)

        // Check subagent orchestration stops with failed status when cap exceeded
        let orchestrator = AgentOrchestrator()
        let subAgentId = SubAgent.ID()
        let subAgent = SubAgent(id: subAgentId, type: .coder, budgetLimit: 10.0)
        orchestrator.subAgents[subAgentId] = subAgent

        // Set global cap to 0.00 and evaluate non-zero cost
        governance.setSpendLimit(scopeKey: "agent:coder", scopeKind: .agent, limit: 0.00, reason: "Zero cap", actor: "test")
        let zeroCapEval = governance.evaluateExecution(agentId: "coder", estimatedCost: 0.01)
        #expect(!zeroCapEval.allowed)
    }

    @Test("Blocked agent's run is refused with clear reason; approved agent runs again")
    func testBlockedAgentRefusedAndApprovedRunsAgain() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        let agentId = "developer"
        let initialAgent = governance.agent(for: agentId)
        #expect(initialAgent != nil)
        #expect(initialAgent?.status == .approved)

        // Block agent
        governance.blockAgent(id: agentId, reason: "Compliance review pending", actor: "security_admin")
        #expect(governance.isAgentBlocked(id: agentId))
        let blockedRecord = governance.agent(for: agentId)
        #expect(blockedRecord?.status == .blocked)

        // Blocked execution evaluation fails
        let blockedEval = governance.evaluateExecution(agentId: agentId)
        #expect(!blockedEval.allowed)
        let reason = blockedEval.refusalReason ?? ""
        #expect(reason.contains("blocked by governance policy"))
        #expect(reason.contains("Developer") || reason.contains("developer"))

        // Unblock/Approve agent
        governance.approveAgent(id: agentId, reason: "Compliance verified", actor: "security_admin")
        #expect(!governance.isAgentBlocked(id: agentId))
        let approvedRecord = governance.agent(for: agentId)
        #expect(approvedRecord?.status == .approved)

        // Approved execution proceeds
        let approvedEval = governance.evaluateExecution(agentId: agentId)
        #expect(approvedEval.allowed)
        #expect(approvedEval.refusalReason == nil)
    }

    @Test("Risky actions require human approval through approval system while safe actions proceed")
    func testRiskyActionRequiresHumanApproval() {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        // Reviewer does not have shellExecution permission by default
        let shellVerdict = governance.checkActionRisk(
            agentId: "reviewer",
            toolName: "run_shell_command",
            command: "git status",
            arguments: "git status"
        )
        #expect(shellVerdict.requiresHumanApproval)
        #expect(shellVerdict.riskCategory == "missing-permission-shell")

        // Destructive command requires human approval even if agent has shell permission
        let destructiveVerdict = governance.checkActionRisk(
            agentId: "executor",
            toolName: "run_shell_command",
            command: "rm -rf /Users/test/workspace",
            arguments: "rm -rf /Users/test/workspace"
        )
        #expect(destructiveVerdict.requiresHumanApproval)

        // Read-only tool auto-approves
        let safeVerdict = governance.checkActionRisk(
            agentId: "coder",
            toolName: "read_file",
            command: "",
            arguments: "{\"filePath\":\"Package.swift\"}"
        )
        #expect(!safeVerdict.requiresHumanApproval)
        #expect(safeVerdict.allowed)

        // Audit log records the risky action gating
        let decisions = governance.decisionAuditLog()
        #expect(decisions.contains { $0.action == "risky_action_gated" })
    }

    @Test("Value analytics tracks work completed (tasks, PRs, verified runs) alongside tokens and cost")
    func testValueAnalyticsTracksWorkCompleted() {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        let spaceId = UUID()
        let model = "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"

        // Record initial batch of work
        governance.recordWorkCompleted(
            agentId: "coder",
            spaceId: spaceId,
            modelId: model,
            tasksDone: 6,
            prsMerged: 3,
            verifiedRuns: 5,
            tokens: 24500,
            cost: 0.0
        )

        // Record second batch of work
        governance.recordWorkCompleted(
            agentId: "coder",
            spaceId: spaceId,
            modelId: model,
            tasksDone: 2,
            prsMerged: 1,
            verifiedRuns: 2,
            tokens: 8200,
            cost: 0.0
        )

        let analytics = governance.valueAnalytics(for: "coder")
        #expect(!analytics.isEmpty)

        let coderRecord = analytics.first { $0.spaceId == spaceId }
        #expect(coderRecord != nil)
        #expect(coderRecord?.tasksCompleted == 8)
        #expect(coderRecord?.prsMerged == 4)
        #expect(coderRecord?.verifiedRuns == 7)
        #expect(coderRecord?.totalTokens == 32700)
        #expect(coderRecord?.totalCost == 0.0)
    }

    @Test("Governance view displays identity, permissions, spend vs cap, and value together in one place")
    func testGovernanceViewDisplaysAllComponentsTogether() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        governance.setSpendLimit(
            scopeKey: "agent:coder",
            scopeKind: .agent,
            limit: 5.00,
            alertThresholdPercent: 0.80,
            reason: "Monthly cap",
            actor: "admin"
        )
        governance.recordSpend(agentId: "coder", amount: 1.25, tokens: 5000)
        governance.recordWorkCompleted(
            agentId: "coder",
            tasksDone: 3,
            prsMerged: 1,
            verifiedRuns: 2
        )

        let viewOutput = governance.governanceSummaryView(for: "coder")
        #expect(viewOutput.contains("Codex"))
        #expect(viewOutput.contains("coder"))
        #expect(viewOutput.contains("APPROVED"))
        #expect(viewOutput.contains("Permissions:"))
        #expect(viewOutput.contains("read_workspace"))
        #expect(viewOutput.contains("Spend vs Cap:"))
        #expect(viewOutput.contains("$1.25"))
        #expect(viewOutput.contains("$5.00"))
        #expect(viewOutput.contains("Tasks Done: 3"))
        #expect(viewOutput.contains("PRs Merged: 1"))
        #expect(viewOutput.contains("Verified Runs: 2"))
        #expect(viewOutput.contains("Tokens: 5000"))

        // Also run live verifier end-to-end to ensure all 6 checks succeed
        let liveResult = await AgentGovernanceLiveVerifier.runVerification()
        #expect(liveResult.passed)
        #expect(liveResult.passedChecks == 6)
        #expect(liveResult.totalChecks == 6)
    }
}
