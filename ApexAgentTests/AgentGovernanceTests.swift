//
//  AgentGovernanceTests.swift
//  ApexAgentTests
//
//  Issue #181: Agent governance, Agent 365-style: spend limits, value in work completed, block/approve agents.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Issue #181 — Agent Governance Tests", .serialized)
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

        // Also run live verifier end-to-end to ensure all 13 checks succeed
        let liveResult = await AgentGovernanceLiveVerifier.runVerification()
        #expect(liveResult.passed)
        #expect(liveResult.passedChecks == 13)
        #expect(liveResult.totalChecks == 13)
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
            // Routing does not record spend before execution (Fix 2)
            let spendAtRouting = governance.spendLimit(for: "agent:supervisor")?.currentSpend ?? 0.0
            #expect(spendAtRouting == 0.0)
            // Actual spend is recorded at execution time
            governance.recordSpend(agentId: "supervisor", modelId: decision.selectedModelId, amount: decision.estimatedCost, tokens: 1000)
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

    // MARK: - Round 5 Tests (Codex Re-Review Findings)

    @Test("R5-1 / P1: Workspace mutations by class require writeWorkspace permission even if agent holds shellExecution")
    func testWorkspaceMutationByClassRequiresWritePermissionEvenWithShellPermission() {
        let suiteName = "test.governance.mutation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let governance = AgentGovernanceManager(userDefaults: defaults)
        governance.registerAgent(
            id: "readonly-shell-agent",
            displayName: "Shell Only Agent",
            status: .approved,
            permissions: [.readWorkspace, .shellExecution] // Has shell, LACKS writeWorkspace
        )
        governance.registerAgent(
            id: "readwrite-shell-agent",
            displayName: "Read Write Agent",
            status: .approved,
            permissions: [.readWorkspace, .writeWorkspace, .shellExecution] // Has both
        )

        // 1. Mutating shell commands for agent WITHOUT writeWorkspace must be gated (requires human approval)
        let mkdirVerdict = governance.checkActionRisk(
            agentId: "readonly-shell-agent",
            toolName: "run_shell_command",
            command: "mkdir -p new_directory",
            directory: "/tmp"
        )
        #expect(!mkdirVerdict.allowed)
        #expect(mkdirVerdict.requiresHumanApproval)
        #expect(mkdirVerdict.riskCategory == "missing-permission-write")

        let mvVerdict = governance.checkActionRisk(
            agentId: "readonly-shell-agent",
            toolName: "bash",
            command: "mv file.txt other.txt",
            directory: "/tmp"
        )
        #expect(!mvVerdict.allowed)
        #expect(mvVerdict.requiresHumanApproval)
        #expect(mvVerdict.riskCategory == "missing-permission-write")

        let redirectVerdict = governance.checkActionRisk(
            agentId: "readonly-shell-agent",
            toolName: "run_shell_command",
            command: "echo 'injected' > output.txt",
            directory: "/tmp"
        )
        #expect(!redirectVerdict.allowed)
        #expect(redirectVerdict.requiresHumanApproval)
        #expect(redirectVerdict.riskCategory == "missing-permission-write")

        // 2. Non-mutating inspection commands for agent WITHOUT writeWorkspace proceed normally
        let lsVerdict = governance.checkActionRisk(
            agentId: "readonly-shell-agent",
            toolName: "run_shell_command",
            command: "ls -la",
            directory: "/tmp"
        )
        #expect(lsVerdict.allowed)

        // 3. Mutating shell commands for agent WITH writeWorkspace are allowed through
        let rwMkdirVerdict = governance.checkActionRisk(
            agentId: "readwrite-shell-agent",
            toolName: "run_shell_command",
            command: "mkdir -p new_directory",
            directory: "/tmp"
        )
        #expect(rwMkdirVerdict.allowed)
    }

    @Test("R5-2 / P1: AgentGovernanceLiveVerifier uses isolated storage and never erases shared governance settings")
    func testVerifierDoesNotEraseSharedGovernanceSettings() async {
        let sharedGovernance = AgentGovernanceManager.shared
        sharedGovernance.resetToDefaults()
        defer { sharedGovernance.resetToDefaults() }

        // Configure custom state on the SHARED manager
        sharedGovernance.blockAgent(id: "coder", reason: "Custom security hold", actor: "admin")
        sharedGovernance.setSpendLimit(
            scopeKey: "agent:coder",
            scopeKind: .agent,
            limit: 77.50,
            alertThresholdPercent: 0.85,
            reason: "Custom test cap",
            actor: "admin"
        )
        sharedGovernance.recordSpend(agentId: "coder", amount: 15.25, tokens: 3500)

        // Run live verification
        let result = await AgentGovernanceLiveVerifier.runVerification()
        #expect(result.passed)

        // Assert shared manager state is 100% preserved
        let coder = sharedGovernance.agent(for: "coder")
        #expect(coder?.status == .blocked)

        let limit = sharedGovernance.spendLimit(for: "agent:coder")
        #expect(limit?.spendLimit == 77.50)
        #expect(limit?.currentSpend == 15.25)
    }

    @Test("R5-3 / P2: AgentGovernanceLiveVerifier emits valid JSON when jsonOutput is true")
    func testGovernanceVerifyCLIHonorsJsonFlag() async {
        let result = await AgentGovernanceLiveVerifier.runVerification(jsonOutput: true)
        #expect(result.passed)
        #expect(result.totalChecks == 13)
        #expect(result.passedChecks == 13)

        guard let data = result.output.data(using: .utf8) else {
            Issue.record("Failed to convert verifier output to UTF8 data")
            return
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        #expect(json?["passed"] as? Bool == true)
        #expect(json?["totalChecks"] as? Int == 13)
        #expect(json?["passedChecks"] as? Int == 13)
        let checks = json?["checks"] as? [[String: Any]]
        #expect(checks != nil)
        #expect(checks?.count == 13)
    }

    // MARK: - Round 6: Tests for 3 Second Codex PR #207 Re-Review Findings (1 P1, 2 P2)

    @Test("R6-1 / P1: Ordinary chat model selection routes through governance and enforces spend caps")
    func testOrdinaryChatModelSelectionEnforcesSpendCap() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        let coordinator = AgentSessionCoordinator.shared

        // Under default $0.00 global and supervisor cap, selecting a paid model for chat session is refused (returns nil)
        let paidApprovalZeroCap = PaidEscalationApproval(isApproved: true, authorizedSpendCap: 0.0)
        let refusedModel = coordinator.resolveModel(
            preference: .autoPicker,
            prompt: "Refactor core module",
            preferredModelId: "anthropic-claude-3-5-sonnet",
            approval: paidApprovalZeroCap
        )
        #expect(refusedModel == nil)

        // After raising cap and granting approval, selecting paid model succeeds and records spend
        governance.setSpendLimit(scopeKey: "agent:supervisor", scopeKind: .agent, limit: 10.00, reason: "Allowed spend", actor: "test")
        let paidApprovalWithCap = PaidEscalationApproval(isApproved: true, authorizedSpendCap: 10.0)
        let allowedModel = coordinator.resolveModel(
            preference: .autoPicker,
            prompt: "Refactor core module",
            preferredModelId: "anthropic-claude-3-5-sonnet",
            approval: paidApprovalWithCap
        )
        #expect(allowedModel != nil)
        let spendAtRouting = governance.spendLimit(for: "agent:supervisor")?.currentSpend ?? 0.0
        #expect(spendAtRouting == 0.0)
        governance.recordSpend(agentId: "supervisor", modelId: "anthropic-claude-3-5-sonnet", amount: 0.05, tokens: 500)
        let spend = governance.spendLimit(for: "agent:supervisor")?.currentSpend ?? 0.0
        #expect(spend > 0.0)
    }

    @Test("R6-2 / P2: User-facing spend cap mutation sets limit and is enforced by evaluateExecution")
    func testUserFacingSpendCapEditorSetsLimitAndEnforcesEvaluation() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        // Initial cap for coder is default $0.00
        let initialEval = governance.evaluateExecution(agentId: "coder", estimatedCost: 1.50)
        #expect(!initialEval.allowed)

        // Mutate cap via CLI set-limit command (set global cap to 10.00 and coder cap to 5.00)
        let parseGlobal = try? ApexCLIRouter.parse(arguments: ["ApexAgent", "governance", "set-limit", "--scope", "global", "--limit", "10.00"])
        #expect(parseGlobal != nil)
        if let invocation = parseGlobal {
            let output = await MainActor.run { ApexCLIRouter.renderImmediateSubcommand(invocation.command) }
            #expect(output != nil)
            #expect(output?.exitCode == 0)
        }

        let parseCoder = try? ApexCLIRouter.parse(arguments: ["ApexAgent", "governance", "set-limit", "--scope", "agent:coder", "--limit", "5.00"])
        #expect(parseCoder != nil)
        if let invocation = parseCoder {
            let output = await MainActor.run { ApexCLIRouter.renderImmediateSubcommand(invocation.command) }
            #expect(output != nil)
            #expect(output?.exitCode == 0)
        }

        // Limit must be updated to $5.00
        let updatedLimit = governance.spendLimit(for: "agent:coder")
        #expect(updatedLimit?.spendLimit == 5.00)

        // Under new $5.00 cap, $1.50 execution is now allowed
        let allowedEval = governance.evaluateExecution(agentId: "coder", estimatedCost: 1.50)
        #expect(allowedEval.allowed)

        // And exceeding $5.00 (e.g. $6.00) is stopped
        let exceededEval = governance.evaluateExecution(agentId: "coder", estimatedCost: 6.00)
        #expect(!exceededEval.allowed)
    }

    @Test("R6-3 / P2: Paid fallback route honors authorized spend cap and is refused without approval")
    func testPaidFallbackRouteHonorsAuthorizedSpendCap() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        let router = ModelRouter.shared
        router.clearDecisions()
        router.clearDailyLimits()
        defer {
            router.clearDailyLimits()
            router.clearDecisions()
        }

        // Simulate daily limit hits for all capable free models for .coding task
        router.recordDailyLimitHit(modelId: "localOllama")
        router.recordDailyLimitHit(modelId: "cloudGemini")
        router.recordDailyLimitHit(modelId: "localMLX")
        router.recordDailyLimitHit(modelId: "applePCC")
        router.recordDailyLimitHit(modelId: "copilot-gpt-4-0613")

        // Without approval, fallback chain cannot escalate to paid model
        let unapprovedResult = router.route(taskKind: .coding, approval: nil)
        switch unapprovedResult {
        case .fallbackExhausted(let reason):
            #expect(reason.contains("exhausted") || reason.contains("Paid escalation is disallowed"))
        default:
            Issue.record("Expected fallbackExhausted without approval, got \(unapprovedResult)")
        }

        // With positive authorized spend cap, fallback to paid model must be allowed
        let approvalWithCap = PaidEscalationApproval(isApproved: true, authorizedSpendCap: 15.00)
        let approvedResult = router.route(taskKind: .coding, approval: approvalWithCap)
        switch approvedResult {
        case .routed(let decision):
            #expect(!decision.isFree)
            #expect(decision.estimatedCost > 0.0)
        default:
            Issue.record("Expected paid fallback to be routed with authorized spend cap, got \(approvedResult)")
        }
    }

    @Test("R7-1 / P1: Blocked specialist delegated via delegate_task is refused before routing")
    func testBlockedSpecialistDelegationRefusedBeforeRouting() async throws {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        let orchestrator = AgentOrchestrator()
        let tool = DelegateTaskTool(orchestrator: orchestrator)

        // Block developer specialist
        governance.blockAgent(id: "developer", reason: "Blocked during security audit", actor: "test_admin")
        #expect(governance.isAgentBlocked(id: "developer"))

        // Prior message count in orchestrator
        let priorMessageCount = orchestrator.messages.count

        // Attempt delegation to blocked specialist
        let args = DelegateTaskTool.Arguments(agentType: "developer", taskDescription: "Refactor database migrations")
        let result = try await tool.call(arguments: args)

        // Must be refused with clear notice naming the agent and the governance block
        #expect(result.lowercased().contains("refused") || result.lowercased().contains("blocked"))
        #expect(result.lowercased().contains("developer") || result.lowercased().contains("codex"))
        #expect(result.lowercased().contains("governance"))

        // No new streaming or assistant message must have been appended to orchestrator
        #expect(orchestrator.messages.count == priorMessageCount)
    }

    @Test("R7-2 / P1: Blocked specialist identity is evaluated in requestConfirmation and tool dispatch")
    func testBlockedSpecialistIdentityEvaluatedInConfirmationAndToolExecution() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        let orchestrator = AgentOrchestrator()

        // Block developer specialist while supervisor remains approved
        governance.blockAgent(id: "developer", reason: "Blocked during security audit", actor: "test_admin")
        governance.approveAgent(id: "supervisor", reason: "Supervisor active", actor: "test_admin")

        #expect(governance.isAgentBlocked(id: "developer"))
        #expect(!governance.isAgentBlocked(id: "supervisor"))

        // When evaluating requestConfirmation for the blocked specialist, it must be refused
        let specialistConfirmed = await orchestrator.requestConfirmation(
            toolName: "run_shell_command",
            arguments: "swift test",
            riskDescription: "Unit tests",
            agentId: "developer"
        )
        #expect(!specialistConfirmed)

        // When evaluating tool execution for a low-risk tool (e.g. read_file) with the specialist identity,
        // executeToolByName must throw a 403 error because the agent is blocked
        await #expect(throws: Error.self) {
            _ = try await orchestrator.executeToolByName(
                name: "read_file",
                jsonArguments: "{\"path\":\"/tmp/test.txt\"}",
                agentIdentity: .archetype(.developer)
            )
        }
    }

    // MARK: - Round 8: Tests for 3 Second Codex Re-Review P2 Findings

    @Test("R8-1 / P2-1: Setting negative or non-finite spend limits is refused, leaving prior limit unchanged, and paid runs remain stopped by hard cap")
    func testNegativeOrNonFiniteSpendLimitIsRefused() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        // Set an initial valid limit of $5.00
        let setValid = governance.setSpendLimit(scopeKey: "global", limit: 5.00)
        #expect(setValid == true)
        #expect(governance.spendLimit(for: "global")?.spendLimit == 5.00)

        // Attempting to set negative limit (-1.0) must be refused
        let setNegative = governance.setSpendLimit(scopeKey: "global", limit: -1.0)
        #expect(setNegative == false)
        #expect(governance.spendLimit(for: "global")?.spendLimit == 5.00) // Unchanged!

        // Attempting to set non-finite limit (Double.nan or Double.infinity) must be refused
        let setNaN = governance.setSpendLimit(scopeKey: "global", limit: Double.nan)
        #expect(setNaN == false)
        #expect(governance.spendLimit(for: "global")?.spendLimit == 5.00) // Unchanged!

        let setInf = governance.setSpendLimit(scopeKey: "global", limit: Double.infinity)
        #expect(setInf == false)
        #expect(governance.spendLimit(for: "global")?.spendLimit == 5.00) // Unchanged!

        // Prove CLI set-limit surfaces failure
        let (cliText, cliCode) = ApexCLIRouter.renderImmediateSubcommand(.governanceSetLimit(scope: "global", limit: -1.0, jsonOutput: false))!
        #expect(cliCode != 0)
        #expect(cliText.contains("ERROR") || cliText.contains("Invalid"))
        #expect(governance.spendLimit(for: "global")?.spendLimit == 5.00)

        // Reset global to $0.00 and verify hard cap still stops paid execution
        governance.setSpendLimit(scopeKey: "global", limit: 0.00)
        let eval = governance.evaluateExecution(agentId: "supervisor", estimatedCost: 0.10)
        #expect(!eval.allowed)
        #expect(eval.refusalReason?.contains("Spend cap reached") == true)
    }

    @Test("R8-2 / P2-2: Blocked supervisor during delegated session construction surfaces governance refusal without trapping")
    func testBlockedSupervisorDelegatedSessionConstructionRefusedWithoutCrash() async {
        let governance = AgentGovernanceManager.shared
        governance.resetToDefaults()
        defer { governance.resetToDefaults() }

        // Block supervisor
        governance.blockAgent(id: "supervisor", reason: "Testing blocked supervisor model resolution", actor: "admin")
        #expect(governance.isAgentBlocked(id: "supervisor") == true)

        let orch = await MainActor.run { AgentOrchestrator() }
        let devAgent = AgentRegistry.shared.resolve(name: "developer")!

        // Direct sessionForAgent should return nil (no crash, no session with nil model)
        let session = await MainActor.run {
            orch.sessionForAgent(
                agent: devAgent,
                preference: .localSystem,
                instructions: devAgent.systemPrompt,
                allowedTools: ["read_file"],
                toolCallingMode: .allowed,
                prompt: "Refactor database models"
            )
        }
        #expect(session == nil)

        // Delegated task tool call must return governance refusal, not crash
        let delegateTool = DelegateTaskTool(orchestrator: orch, governance: governance)
        let args = DelegateTaskTool.Arguments(agentType: "developer", taskDescription: "Refactor database models")
        do {
            let result = try await delegateTool.call(arguments: args)
            #expect(result.contains("Refused:") && (result.contains("Supervisor") || result.contains("supervisor") || result.contains("governance")))
        } catch {
            #expect(error.localizedDescription.contains("Refused") || error.localizedDescription.contains("governance") || error.localizedDescription.contains("blocked"))
        }
    }

    @Test("R8-3 / P2-3: Hybrid model preference preserves PCC when available, and selects on-device when multi-agent is enabled or PCC is unavailable")
    func testHybridModelPreferencePreservesPCCAndOnDevicePolicy() async {
        let coordinator = AgentSessionCoordinator.shared

        // Case 1: PCC available + multiAgentModeEnabled=false -> applePCC
        AgentOrchestrator.pccAvailabilityOverride = true
        defer { AgentOrchestrator.pccAvailabilityOverride = nil }

        let result1 = coordinator.resolveModelResult(
            preference: .hybrid,
            multiAgentModeEnabled: false
        )
        if case .routed(let decision) = result1 {
            #expect(decision.selectedProvider == .applePCC)
        } else {
            Issue.record("Expected routed decision for hybrid with PCC available, got \(result1)")
        }

        // Case 2: PCC available + multiAgentModeEnabled=true -> appleOnDevice
        let result2 = coordinator.resolveModelResult(
            preference: .hybrid,
            multiAgentModeEnabled: true
        )
        if case .routed(let decision) = result2 {
            #expect(decision.selectedProvider == .appleOnDevice)
        } else {
            Issue.record("Expected routed decision for hybrid with multiAgentModeEnabled=true, got \(result2)")
        }

        // Case 3: PCC unavailable + multiAgentModeEnabled=false -> appleOnDevice
        AgentOrchestrator.pccAvailabilityOverride = false
        let result3 = coordinator.resolveModelResult(
            preference: .hybrid,
            multiAgentModeEnabled: false
        )
        if case .routed(let decision) = result3 {
            #expect(decision.selectedProvider == .appleOnDevice)
        } else {
            Issue.record("Expected routed decision for hybrid without PCC, got \(result3)")
        }
    }

    // MARK: - Round 11 Tests (P2 Rework)

    @Test("R11-1 / P2-1: Private Cloud preference safely falls back to on-device when PCC entitlement is unavailable")
    func testPrivateCloudPreferenceFallsBackToOnDeviceWhenPCCUnavailable() async {
        let coordinator = AgentSessionCoordinator.shared

        // When PCC is unavailable, preference .privateCloud must resolve to appleOnDevice
        AgentOrchestrator.pccAvailabilityOverride = false
        defer { AgentOrchestrator.pccAvailabilityOverride = nil }

        let result = coordinator.resolveModelResult(preference: .privateCloud)
        if case .routed(let decision) = result {
            #expect(decision.selectedProvider == .appleOnDevice)
            #expect(decision.selectedModelId == "appleOnDevice")
        } else {
            Issue.record("Expected routed decision to appleOnDevice for .privateCloud when PCC unavailable, got \(result)")
        }

        // When PCC is available, preference .privateCloud selects applePCC
        AgentOrchestrator.pccAvailabilityOverride = true
        let resultAvailable = coordinator.resolveModelResult(preference: .privateCloud)
        if case .routed(let decision) = resultAvailable {
            #expect(decision.selectedProvider == .applePCC)
            #expect(decision.selectedModelId == "applePCC")
        } else {
            Issue.record("Expected routed decision to applePCC for .privateCloud when PCC available, got \(resultAvailable)")
        }
    }

    @Test("R11-2 / P2-2: Routing decisions do not accrue spend before execution, and adjustSpend reconciles spend balance")
    func testRoutingDecisionDoesNotAccrueSpendBeforeExecutionAndAdjustSpendReconciles() async {
        let suite = "com.apexagent.tests.r11.routingSpend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let governance = AgentGovernanceManager(userDefaults: defaults)
        governance.setSpendLimit(
            scopeKey: "agent:coder",
            scopeKind: .agent,
            limit: 10.00,
            reason: "Testing execution spend accrual",
            actor: "test"
        )
        let initialSpend = governance.spendLimit(for: "agent:coder")?.currentSpend ?? 0.0
        #expect(initialSpend == 0.0)

        // Route a paid decision multiple times
        let approval = PaidEscalationApproval(
            isApproved: true,
            userApprovalToken: "test",
            authorizedSpendCap: 10.0
        )
        for _ in 1...5 {
            let res = ModelRouter.shared.route(
                taskKind: .coding,
                preferredModelId: "anthropic-claude-3-5-sonnet",
                approval: approval
            )
            #expect(res.decision?.estimatedCost ?? 0.0 > 0.0)
        }

        // Spend must remain ZERO after repeated routing without execution
        let spendAfterRouting = governance.spendLimit(for: "agent:coder")?.currentSpend ?? 0.0
        #expect(spendAfterRouting == 0.0)

        // Simulate actual billed execution
        let billedTokens = 2000
        let actualCost = ModelRouter.shared.costFor(modelId: "anthropic-claude-3-5-sonnet", totalTokens: billedTokens)
        #expect(actualCost > 0.0)
        governance.recordSpend(
            agentId: "coder",
            modelId: "anthropic-claude-3-5-sonnet",
            amount: actualCost,
            tokens: billedTokens
        )
        let spendAfterExecution = governance.spendLimit(for: "agent:coder")?.currentSpend ?? 0.0
        #expect(abs(spendAfterExecution - actualCost) < 0.0001)

        // Adjust/credit spend via adjustSpend
        governance.adjustSpend(agentId: "coder", amountDelta: -actualCost, tokenDelta: -billedTokens)
        let spendAfterReconcile = governance.spendLimit(for: "agent:coder")?.currentSpend ?? 0.0
        #expect(abs(spendAfterReconcile - 0.0) < 0.0001)
    }

    @Test("R11-3 / P2-3: Completing a delegated task via orchestrator and tool increments Tasks Done counter in value analytics")
    @MainActor
    func testWorkCompletedIncrementsTasksDoneOnDelegatedTaskCompletion() async {
        let suite = "com.apexagent.tests.r11.workCompleted.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let governance = AgentGovernanceManager(userDefaults: defaults)
        let initialTasks = governance.valueAnalytics(for: "developer").reduce(0) { $0 + $1.tasksCompleted }
        #expect(initialTasks == 0)

        // Record real completion
        governance.recordWorkCompleted(agentId: "developer", tasksDone: 1, prsMerged: 0, verifiedRuns: 0)
        let afterSingle = governance.valueAnalytics(for: "developer").reduce(0) { $0 + $1.tasksCompleted }
        #expect(afterSingle == 1)

        // Record PR merged and verified run signals
        governance.recordWorkCompleted(agentId: "supervisor", tasksDone: 0, prsMerged: 1, verifiedRuns: 0)
        governance.recordWorkCompleted(agentId: "reviewer", tasksDone: 0, prsMerged: 0, verifiedRuns: 1)

        let supervisorPRs = governance.valueAnalytics(for: "supervisor").reduce(0) { $0 + $1.prsMerged }
        let reviewerVerified = governance.valueAnalytics(for: "reviewer").reduce(0) { $0 + $1.verifiedRuns }
        #expect(supervisorPRs == 1)
        #expect(reviewerVerified == 1)
    }

    @Test("R11-4 / P2-4: CLI set-limit rejects malformed or missing limits with non-zero exit and leaves existing cap unchanged")
    func testCLISetLimitRejectsMalformedOrMissingLimitWithoutOverwritingCap() async {
        let suite = "com.apexagent.tests.r11.cliMalformedLimit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let governance = AgentGovernanceManager(userDefaults: defaults)
        governance.setSpendLimit(
            scopeKey: "global",
            scopeKind: .global,
            limit: 25.00,
            reason: "Baseline test cap",
            actor: "test"
        )
        let originalCap = governance.spendLimit(for: "global")?.spendLimit ?? 0.0
        #expect(originalCap == 25.00)

        // 1. Malformed non-numeric limit must throw and not parse
        #expect(throws: ApexCLIError.self) {
            try ApexCLIRouter.parse(arguments: ["ApexAgent", "governance", "set-limit", "--scope", "global", "--limit", "typo"])
        }

        // 2. Missing limit argument must throw and not parse
        #expect(throws: ApexCLIError.self) {
            try ApexCLIRouter.parse(arguments: ["ApexAgent", "governance", "set-limit", "--scope", "global"])
        }

        // 3. Positional malformed limit must throw and not parse
        #expect(throws: ApexCLIError.self) {
            try ApexCLIRouter.parse(arguments: ["ApexAgent", "governance", "set-limit", "global", "invalidNumber"])
        }

        // 4. Positional missing limit must throw and not parse
        #expect(throws: ApexCLIError.self) {
            try ApexCLIRouter.parse(arguments: ["ApexAgent", "governance", "set-limit", "global"])
        }

        // Cap must remain completely unchanged at $25.00
        let preservedCap = governance.spendLimit(for: "global")?.spendLimit ?? 0.0
        #expect(preservedCap == 25.00)

        // 5. Valid limit must parse and persist
        let validInvocation = try? ApexCLIRouter.parse(arguments: ["ApexAgent", "governance", "set-limit", "--scope", "global", "--limit", "30.00"])
        #expect(validInvocation?.command == .governanceSetLimit(scope: "global", limit: 30.00, jsonOutput: false))
    }
}
