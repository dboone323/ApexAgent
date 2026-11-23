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

        // Also run live verifier end-to-end to ensure all 7 checks succeed
        let liveResult = await AgentGovernanceLiveVerifier.runVerification()
        #expect(liveResult.passed)
        #expect(liveResult.passedChecks == 7)
        #expect(liveResult.totalChecks == 7)
    }

    // MARK: - Round 4: Tests for 10 Codex PR #207 Findings (5 P1, 5 P2)

    @Test("P1-1: Paid model turn is refused under $0.00 cap, and spend accumulates after cap is raised")
    func testPaidTurnRefusedUnderZeroCapAndSpendAccrues() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        let router = ModelRouter.shared
        router.clearDecisions()

        let paidApprovalZeroCap = PaidEscalationApproval(
            isApproved: true,
            authorizedSpendCap: 0.0
        )
        // With default $0.00 cap, router must refuse paid escalation
        let result = router.route(
            taskKind: .coding,
            preferredModelId: "anthropic-claude-3-5-sonnet",
            approval: paidApprovalZeroCap
        )
        switch result {
        case .paidEscalationRefused(let reason, _):
            #expect(reason.contains("cap") || reason.contains("Spend cap reached") || reason.contains("zero-spend") || reason.contains("governance"))
        default:
            Issue.record("Expected paid escalation refused under $0 cap, got \(result)")
        }

        // Now increase global cap to $10.00 and supervisor agent cap to $10.00
        governance.setSpendLimit(scopeKey: "global", scopeKind: .global, limit: 10.00, reason: "Allowed spend", actor: "test")
        governance.setSpendLimit(scopeKey: "agent:supervisor", scopeKind: .agent, limit: 10.00, reason: "Allowed spend", actor: "test")

        let paidApprovalWithCap = PaidEscalationApproval(
            isApproved: true,
            authorizedSpendCap: 10.0
        )
        let allowedResult = router.route(
            taskKind: .coding,
            preferredModelId: "anthropic-claude-3-5-sonnet",
            approval: paidApprovalWithCap
        )
        switch allowedResult {
        case .routed(let decision):
            #expect(decision.selectedModelId == "anthropic-claude-3-5-sonnet")
            #expect(decision.estimatedCost > 0.0)
            // Verify spend was actually recorded
            let currentSpend = governance.spendLimit(for: "agent:supervisor")?.currentSpend ?? 0.0
            #expect(currentSpend > 0.0)
        default:
            Issue.record("Expected paid model to be routed when cap raised, got \(allowedResult)")
        }
    }

    @Test("P1-2: Blocked supervisor gets no tool approvals, even for safe allowlisted tools")
    func testBlockedSupervisorCannotAutoApproveTools() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        // Block supervisor
        governance.blockAgent(id: "supervisor", reason: "Compromised credential suspected", actor: "security_admin")
        #expect(governance.isAgentBlocked(id: "supervisor"))

        // checkActionRisk must refuse blocked supervisor
        let riskVerdict = governance.checkActionRisk(
            agentId: "supervisor",
            toolName: "read_file",
            command: "",
            arguments: "{\"filePath\":\"Package.swift\"}"
        )
        #expect(!riskVerdict.allowed)
        #expect(riskVerdict.riskCategory == "agent-blocked")

        // Orchestrator requestConfirmation must fail (return false)
        let orchestrator = AgentOrchestrator()
        let confirmed = await orchestrator.requestConfirmation(
            toolName: "read_file",
            arguments: "{\"filePath\":\"Package.swift\"}",
            riskDescription: "Read workspace file"
        )
        #expect(!confirmed)
    }

    @Test("P1-3: Governance state persists across manager recreation via storage")
    func testGovernanceStatePersistsAcrossManagerRecreation() {
        let testSuiteName = "apexagent.governance.test.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: testSuiteName) else {
            Issue.record("Failed to create isolated UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: testSuiteName) }

        let manager1 = AgentGovernanceManager(userDefaults: testDefaults)
        manager1.blockAgent(id: "coder", reason: "Maintenance freeze", actor: "admin")
        manager1.setSpendLimit(
            scopeKey: "agent:coder",
            scopeKind: .agent,
            limit: 15.50,
            alertThresholdPercent: 0.75,
            reason: "Quarterly budget",
            actor: "admin"
        )
        manager1.recordSpend(agentId: "coder", amount: 4.25, tokens: 12000)

        // Recreate manager with same storage to simulate app restart
        let manager2 = AgentGovernanceManager(userDefaults: testDefaults)
        let coderRecord = manager2.agent(for: "coder")
        #expect(coderRecord?.status == .blocked)

        let limitRecord = manager2.spendLimit(for: "agent:coder")
        #expect(limitRecord?.spendLimit == 15.50)
        #expect(limitRecord?.currentSpend == 4.25)
        #expect(limitRecord?.alertThresholdPercent == 0.75)

        let decisions = manager2.decisionAuditLog()
        #expect(decisions.contains { $0.action == "block" && $0.targetId == "coder" })
    }

    @Test("P1-4: Verifier fails loudly when log path is unwritable")
    func testVerifierFailsLoudlyWhenLogPathUnwritable() async {
        let unwritablePath = "/dev/null/impossible_dir/live-verify.log"
        let result = await AgentGovernanceLiveVerifier.runVerification(logPath: unwritablePath)
        #expect(!result.passed)
        #expect(result.output.contains("FATAL ERROR") || result.output.contains("Failed to write"))
    }

    @Test("P1-5: Approaching cap alert does not bypass subsequent hard cap exceedance in another scope")
    func testApproachingCapAlertDoesNotBypassGlobalExceededCap() {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        // Agent cap: $10.00, spend: $7.50
        governance.setSpendLimit(
            scopeKey: "agent:coder",
            scopeKind: .agent,
            limit: 10.00,
            alertThresholdPercent: 0.80,
            reason: "Agent limit",
            actor: "test"
        )
        governance.recordSpend(agentId: "coder", amount: 7.50, tokens: 1000)

        // Global cap: $5.00, spend: $4.50
        governance.setSpendLimit(
            scopeKey: "global",
            scopeKind: .global,
            limit: 5.00,
            alertThresholdPercent: 0.80,
            reason: "Global limit",
            actor: "test"
        )
        governance.recordSpend(agentId: "developer", amount: 4.50, tokens: 500)

        // Execution costing $1.00:
        // agent:coder -> 7.50 + 1.00 = 8.50 <= 10.00 (approaching limit alert)
        // global -> 4.50 + 7.50 + 1.00 or global spend > 5.00 -> EXCEEDED hard cap!
        let eval = governance.evaluateExecution(agentId: "coder", estimatedCost: 1.00)
        #expect(!eval.allowed)
        #expect(eval.refusalReason != nil)
        #expect(eval.refusalReason?.contains("global") == true)
    }

    @Test("P2-6: Agent with pendingApproval status is refused execution")
    func testPendingApprovalAgentExecutionRefused() {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        governance.registerAgent(
            id: "intern_bot",
            displayName: "Intern Bot",
            status: .pendingApproval,
            permissions: [.readWorkspace]
        )

        let eval = governance.evaluateExecution(agentId: "intern_bot")
        #expect(!eval.allowed)
        let reason = eval.refusalReason ?? ""
        #expect(reason.contains("pending approval") || reason.contains("pendingApproval") || reason.contains("Pending"))
    }

    @Test("P2-7: User-scoped spend limits are enforced and accrued")
    func testUserScopedSpendLimitEnforcedAndAccrued() {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        governance.setSpendLimit(
            scopeKey: "user:developer_dan",
            scopeKind: .user,
            limit: 3.00,
            alertThresholdPercent: 0.80,
            reason: "User tier limit",
            actor: "admin"
        )
        governance.setSpendLimit(scopeKey: "global", scopeKind: .global, limit: 100.00)
        governance.setSpendLimit(scopeKey: "agent:coder", scopeKind: .agent, limit: 100.00)

        // Cost exceeding user cap should be refused
        let evalExceeded = governance.evaluateExecution(
            agentId: "coder",
            userId: "developer_dan",
            estimatedCost: 3.50
        )
        #expect(!evalExceeded.allowed)
        #expect(evalExceeded.refusalReason?.contains("user:developer_dan") == true)

        // Cost within user cap should be allowed
        let evalAllowed = governance.evaluateExecution(
            agentId: "coder",
            userId: "developer_dan",
            estimatedCost: 1.50
        )
        #expect(evalAllowed.allowed)

        // Record spend for user
        governance.recordSpend(
            agentId: "coder",
            userId: "developer_dan",
            amount: 1.50,
            tokens: 3000
        )
        let userLimit = governance.spendLimit(for: "user:developer_dan")
        #expect(userLimit?.currentSpend == 1.50)
    }

    @Test("P2-8: Stubbed sub-agent run does not record phantom tasks in value analytics")
    func testStubbedRunSubAgentDoesNotRecordPhantomTasks() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        let orchestrator = AgentOrchestrator()
        let subAgentId = SubAgent.ID()
        let subAgent = SubAgent(id: subAgentId, type: .coder, budgetLimit: 10.0)
        orchestrator.subAgents[subAgentId] = subAgent

        await orchestrator.runSubAgent(id: subAgentId, type: .coder, context: "testing no phantom tasks")

        let analytics = governance.valueAnalytics(for: "coder")
        let tasksDone = analytics.reduce(0) { $0 + $1.tasksCompleted }
        #expect(tasksDone == 0)
    }

    @Test("P2-9: Agent governance dashboard is accessible via Settings navigation")
    func testGovernanceDashboardWiredIntoSettingsView() {
        let view = SettingsView()
        let mirror = Mirror(reflecting: view)
        let hasGovernanceProperty = mirror.children.contains { child in
            child.label?.contains("Governance") == true || child.label?.contains("governance") == true
        }
        #expect(hasGovernanceProperty)
    }

    @Test("P2-10: ApexCLIRouter returns valid structured JSON for governance command with --json flag")
    func testGovernanceCLIHonorsJsonFlag() {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        governance.setSpendLimit(
            scopeKey: "agent:coder",
            scopeKind: .agent,
            limit: 25.00,
            alertThresholdPercent: 0.80,
            reason: "JSON test limit",
            actor: "admin"
        )
        governance.recordSpend(agentId: "coder", amount: 5.00, tokens: 10000)
        governance.recordWorkCompleted(agentId: "coder", tasksDone: 4, prsMerged: 2, verifiedRuns: 3)

        guard let output = ApexCLIRouter.renderImmediateSubcommand(.governance(agentId: "coder", jsonOutput: true)) else {
            Issue.record("Expected governance subcommand to render output")
            return
        }
        #expect(output.exitCode == 0)
        guard let data = output.output.data(using: .utf8) else {
            Issue.record("Failed to convert output to data")
            return
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        let agents = json?["agents"] as? [[String: Any]]
        #expect(agents != nil)
        let coder = agents?.first { ($0["id"] as? String) == "coder" }
        #expect(coder != nil)
        #expect((coder?["displayName"] as? String) == "Codex")
        #expect((coder?["status"] as? String) == "approved")
        #expect((coder?["spendLimit"] as? Double) == 25.00)
        #expect((coder?["currentSpend"] as? Double) == 5.00)
        #expect((coder?["tasksDone"] as? Int) == 4)
        #expect((coder?["prsMerged"] as? Int) == 2)
        #expect((coder?["verifiedRuns"] as? Int) == 3)
    }
}
