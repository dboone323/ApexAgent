import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Playbook Collaboration Real Functional Tests (Milestone M2)
//
// These tests validate:
// 1. All 3 built-in Collaboration Playbook presets and schemas.
// 2. Playbook participant assignment across full and partial bot rosters.
// 3. Sequential stage execution with context passing.
// 4. Parallel stage execution using Swift structured concurrency (withThrowingTaskGroup).
// 5. Human-in-the-loop approval cards with asynchronous pause, resume, and rejection gating.
// 6. Live peer delegation event tracking and TraceBus event streaming.
// 7. BotManager playbook execution and history tracking.
// 8. Playbook JSON serialization and deserialization.

@Suite("PlaybookCollaborationTests")
struct PlaybookCollaborationTests {

    // MARK: - Helper Roster Creation

    @MainActor
    private func createStandard5BotRoster() -> [BotProfile] {
        let apex = BotProfile(
            name: "Apex",
            title: "General Assistant",
            descriptionText: "General AI assistant and task handler.",
            avatarName: "bolt.fill"
        )
        let cos = BotProfile(
            name: "Chief of Staff",
            title: "Executive Coordinator",
            descriptionText: "Coordinates multi-bot workflows, delegates tasks, and synthesizes outcomes.",
            avatarName: "person.crop.square.fill"
        )
        cos.isChiefOfStaff = true

        let architect = BotProfile(
            name: "Code Architect",
            title: "Senior Engineer",
            descriptionText: "Specializes in code quality, architecture patterns, and diff review.",
            avatarName: "chevron.left.forwardslash.chevron.right"
        )

        let researcher = BotProfile(
            name: "Researcher",
            title: "Deep Research Specialist",
            descriptionText: "Performs security audits, documentation analysis, and root cause investigation.",
            avatarName: "magnifyingglass"
        )

        let automator = BotProfile(
            name: "Automator",
            title: "macOS System Automator",
            descriptionText: "Runs terminal commands, CI verification, and executes automated test suites.",
            avatarName: "terminal.fill"
        )

        return [apex, cos, architect, researcher, automator]
    }

    // MARK: - Test 1: Built-in Presets Definition and Stage Coverage

    @Test func testPresetDefinitionsAndStageCoverage() {
        let presets = CollaborationPlaybook.builtInPresets
        #expect(presets.count == 3)

        // 1. Full PR Review Loop
        let prLoop = CollaborationPlaybook.fullPRReviewLoop
        #expect(prLoop.presetKind == .fullPRReviewLoop)
        #expect(prLoop.name == "Full PR Review Loop")
        #expect(prLoop.roles.count == 4)
        #expect(prLoop.stages.count == 5)

        // Stage 1: Sequential Intake
        #expect(prLoop.stages[0].id == "stage_pr_intake")
        #expect(prLoop.stages[0].dispatchMode == .sequential)
        #expect(prLoop.stages[0].requiresApproval == false)

        // Stage 2: Parallel Dual Review
        #expect(prLoop.stages[1].id == "stage_dual_review")
        #expect(prLoop.stages[1].dispatchMode == .parallel)
        #expect(prLoop.stages[1].requiredRoles.count == 2)
        #expect(prLoop.stages[1].requiredRoleIds.contains("code_architect"))
        #expect(prLoop.stages[1].requiredRoleIds.contains("researcher"))

        // Stage 3: CI Verification
        #expect(prLoop.stages[2].id == "stage_ci_verification")
        #expect(prLoop.stages[2].dispatchMode == .sequential)

        // Stage 4: Approval Gate
        #expect(prLoop.stages[3].id == "stage_merge_approval_gate")
        #expect(prLoop.stages[3].requiresApproval == true)
        #expect(prLoop.stages[3].approvalDescription != nil)

        // Stage 5: Executive Summary
        #expect(prLoop.stages[4].id == "stage_executive_summary")
        #expect(prLoop.stages[4].dispatchMode == .sequential)

        // 2. Issue-to-Patch Pipeline
        let issuePipeline = CollaborationPlaybook.issueToPatchPipeline
        #expect(issuePipeline.presetKind == .issueToPatchPipeline)
        #expect(issuePipeline.roles.count == 4)
        #expect(issuePipeline.stages.count == 5)
        #expect(issuePipeline.stages[4].requiresApproval == true)

        // 3. Weekly Standup & Retrospective
        let standup = CollaborationPlaybook.weeklyStandupAndRetrospective
        #expect(standup.presetKind == .weeklyStandupAndRetrospective)
        #expect(standup.roles.count == 5)
        #expect(standup.stages.count == 2)
        #expect(standup.stages[0].dispatchMode == .parallel)
        #expect(standup.stages[0].requiredRoles.count == 5)
        #expect(standup.stages[1].dispatchMode == .sequential)
    }

    // MARK: - Test 2: JSON Serialization and Deserialization

    @Test func testPlaybookJSONSerialization() throws {
        for preset in CollaborationPlaybook.builtInPresets {
            let data = try preset.encode()
            #expect(!data.isEmpty)

            let decoded = try CollaborationPlaybook.decode(from: data)
            #expect(decoded.id == preset.id)
            #expect(decoded.name == preset.name)
            #expect(decoded.presetKind == preset.presetKind)
            #expect(decoded.roles.count == preset.roles.count)
            #expect(decoded.stages.count == preset.stages.count)

            for (origStage, decStage) in zip(preset.stages, decoded.stages) {
                #expect(origStage.id == decStage.id)
                #expect(origStage.dispatchMode == decStage.dispatchMode)
                #expect(origStage.requiresApproval == decStage.requiresApproval)
                #expect(origStage.promptTemplate == decStage.promptTemplate)
            }
        }
    }

    // MARK: - Test 3: Participant Assigner with Full Standard Roster

    @Test @MainActor func testParticipantAssignerFullStandardRoster() {
        let roster = createStandard5BotRoster()
        let prPlaybook = CollaborationPlaybook.fullPRReviewLoop

        let assignments = PlaybookParticipantAssigner.assignParticipants(
            for: prPlaybook,
            availableBots: roster
        )

        #expect(assignments.count == 4)
        #expect(assignments[.chiefOfStaff]?.name == "Chief of Staff")
        #expect(assignments[.codeArchitect]?.name == "Code Architect")
        #expect(assignments[.researcher]?.name == "Researcher")
        #expect(assignments[.automator]?.name == "Automator")

        // Standup uses all 5 bots
        let standupPlaybook = CollaborationPlaybook.weeklyStandupAndRetrospective
        let standupAssignments = PlaybookParticipantAssigner.assignParticipants(
            for: standupPlaybook,
            availableBots: roster
        )

        #expect(standupAssignments.count == 5)
        #expect(standupAssignments[.generalAssistant]?.name == "Apex")
    }

    // MARK: - Test 4: Participant Assigner with Partial Roster & Fallback

    @Test @MainActor func testParticipantAssignerPartialRosterWithFallback() {
        // Only 1 single bot available
        let soloBot = BotProfile(
            name: "SoloBot",
            title: "General Engineer",
            descriptionText: "Handles everything."
        )

        let prPlaybook = CollaborationPlaybook.fullPRReviewLoop
        let assignments = PlaybookParticipantAssigner.assignParticipants(
            for: prPlaybook,
            availableBots: [soloBot]
        )

        #expect(assignments.count == 4)
        #expect(assignments[.chiefOfStaff]?.id == soloBot.id)
        #expect(assignments[.codeArchitect]?.id == soloBot.id)
        #expect(assignments[.researcher]?.id == soloBot.id)
        #expect(assignments[.automator]?.id == soloBot.id)

        // Snapshot conversion
        let snapshots = PlaybookParticipantAssigner.assignParticipantSnapshots(
            for: prPlaybook,
            availableBots: [soloBot]
        )
        #expect(snapshots.count == 4)
        #expect(snapshots[.chiefOfStaff]?.name == "SoloBot")
    }

    // MARK: - Test 5: Sequential Stage Execution and Context Propagation

    @Test @MainActor func testSequentialStageExecutionAndContextPropagation() async throws {
        let roster = createStandard5BotRoster()

        let customStages = [
            PlaybookStageDefinition(
                id: "stage_intake",
                name: "Intake",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Process input: {input}"
            ),
            PlaybookStageDefinition(
                id: "stage_architecture",
                name: "Architecture Review",
                dispatchMode: .sequential,
                requiredRole: .codeArchitect,
                promptTemplate: "Review architecture based on: {previousOutput}"
            ),
            PlaybookStageDefinition(
                id: "stage_summary",
                name: "Final Summary",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Compile final verdict: {previousOutput}"
            )
        ]

        let playbook = CollaborationPlaybook(
            id: UUID(),
            name: "Sequential Workflow Test",
            roles: [.chiefOfStaff, .codeArchitect],
            stages: customStages
        )

        let runner = PlaybookRunner(playbook: playbook, availableBots: roster)
        let report = try await runner.execute(contextInput: "Pull Request #402: Add Swift 6.4 Concurrency Safety")

        #expect(report.isSuccessful == true)
        #expect(report.stageResults.count == 3)
        #expect(report.stageResults[0].status == .success)
        #expect(report.stageResults[1].status == .success)
        #expect(report.stageResults[2].status == .success)
        #expect(!report.finalOutput.isEmpty)
        #expect(report.totalDuration >= 0)

        // Verify stage outputs carry simulated turn placeholders (no canned claims)
        #expect(report.executionMode == .simulated)

        let architectTurn = report.stageResults[1].botResults[0]
        #expect(architectTurn.botName == "Code Architect")
        #expect(architectTurn.roleId == "code_architect")
        #expect(architectTurn.isSimulated == true)
        #expect(architectTurn.output.contains("[SIMULATION"))

        let chiefTurn = report.stageResults[2].botResults[0]
        #expect(chiefTurn.botName == "Chief of Staff")
        #expect(chiefTurn.isSimulated == true)
        #expect(report.stageResults[2].combinedOutput.contains("Chief of Staff"))
    }

    // MARK: - Test 6: Parallel Turn Fan-Out Execution

    @Test @MainActor func testParallelTurnFanOutExecution() async throws {
        let roster = createStandard5BotRoster()

        let parallelStage = PlaybookStageDefinition(
            id: "stage_parallel_specialists",
            name: "Parallel Specialist Audit",
            dispatchMode: .parallel,
            requiredRoles: [.codeArchitect, .researcher, .automator],
            promptTemplate: "Audit the payload: {input}"
        )

        let playbook = CollaborationPlaybook(
            id: UUID(),
            name: "Parallel Fan-Out Test",
            roles: [.codeArchitect, .researcher, .automator],
            stages: [parallelStage]
        )

        let runner = PlaybookRunner(playbook: playbook, availableBots: roster)
        let report = try await runner.execute(contextInput: "Audit security, architecture, and CI pipeline")

        #expect(report.isSuccessful == true)
        #expect(report.stageResults.count == 1)

        let stageResult = report.stageResults[0]
        #expect(stageResult.dispatchMode == .parallel)
        #expect(stageResult.botResults.count == 3)

        // Verify all 3 specialist outputs were collected
        let roleIds = Set(stageResult.botResults.map(\.roleId))
        #expect(roleIds.contains("code_architect"))
        #expect(roleIds.contains("researcher"))
        #expect(roleIds.contains("automator"))

        // All turns are clearly-marked simulation (no canned success claims)
        #expect(report.executionMode == .simulated)
        #expect(stageResult.botResults.allSatisfy { $0.isSimulated })
        #expect(stageResult.combinedOutput.contains("[SIMULATION"))
        let botNames = Set(stageResult.botResults.map(\.botName))
        #expect(botNames == ["Code Architect", "Researcher", "Automator"])
    }

    // MARK: - Test 7: Approval Card Pausing and Resuming

    @Test @MainActor func testApprovalCardPausingAndResuming() async throws {
        let roster = createStandard5BotRoster()

        let stages = [
            PlaybookStageDefinition(
                id: "stage_pre_gate",
                name: "Pre-Gate Analysis",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Initial analysis: {input}"
            ),
            PlaybookStageDefinition(
                id: "stage_human_gate",
                name: "Production Deployment Gate",
                description: "Requires human sign-off before deploy.",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Approval check",
                requiresApproval: true,
                approvalDescription: "Human sign-off required: Confirm readiness to deploy."
            ),
            PlaybookStageDefinition(
                id: "stage_post_gate",
                name: "Post-Gate Verification",
                dispatchMode: .sequential,
                requiredRole: .automator,
                promptTemplate: "Deploy and verify: {previousOutput}"
            )
        ]

        let playbook = CollaborationPlaybook(
            id: UUID(),
            name: "Approval Gate Workflow",
            roles: [.chiefOfStaff, .automator],
            stages: stages
        )

        let runner = PlaybookRunner(playbook: playbook, availableBots: roster)

        // Launch execution in background task
        let executionTask = Task {
            try await runner.execute(contextInput: "Release v2.0 to Production")
        }

        // Give runner a moment to reach the approval gate
        var isWaiting = false
        for _ in 0..<50 {
            let status = runner.status
            if case .waitingForApproval = status {
                isWaiting = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }

        #expect(isWaiting == true)

        let pendingCard = runner.pendingApprovalCard
        #expect(pendingCard != nil)
        #expect(pendingCard?.stageId == "stage_human_gate")
        #expect(pendingCard?.status == .pending)

        // Approve the pending card
        runner.approvePendingStage(notes: "Approved by Release Engineer")

        // Execution should complete successfully
        let report = try await executionTask.value
        #expect(report.isSuccessful == true)
        #expect(report.stageResults.count == 3)
        #expect(report.approvalCards.count == 1)
        #expect(report.approvalCards[0].status == .approved)
        #expect(report.approvalCards[0].resolutionNotes == "Approved by Release Engineer")
    }

    // MARK: - Test 8: Approval Card Rejection Aborts Execution

    @Test @MainActor func testApprovalCardRejectionAbortsExecution() async throws {
        let roster = createStandard5BotRoster()

        let stages = [
            PlaybookStageDefinition(
                id: "stage_1",
                name: "Initial Check",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Analyze: {input}"
            ),
            PlaybookStageDefinition(
                id: "stage_gate",
                name: "Security Gate",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Gate",
                requiresApproval: true,
                approvalDescription: "Verify security clearance"
            ),
            PlaybookStageDefinition(
                id: "stage_3",
                name: "Should Not Run",
                dispatchMode: .sequential,
                requiredRole: .automator,
                promptTemplate: "Execute: {previousOutput}"
            )
        ]

        let playbook = CollaborationPlaybook(
            id: UUID(),
            name: "Rejection Gate Test",
            roles: [.chiefOfStaff, .automator],
            stages: stages
        )

        let runner = PlaybookRunner(playbook: playbook, availableBots: roster)

        let executionTask = Task {
            try await runner.execute(contextInput: "Unverified Payload")
        }

        // Wait for approval gate
        for _ in 0..<50 {
            let status = runner.status
            if case .waitingForApproval = status {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // Reject the approval gate
        runner.rejectPendingStage(reason: "Security clearance denied")

        // Expect rejection error
        do {
            _ = try await executionTask.value
            Issue.record("Expected approvalRejected error but execution succeeded")
        } catch let error as PlaybookExecutionError {
            if case .approvalRejected(let stageId, let reason) = error {
                #expect(stageId == "stage_gate")
                #expect(reason == "Security clearance denied")
            } else {
                Issue.record("Unexpected PlaybookExecutionError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let finalStatus = runner.status
        if case .failed(let err) = finalStatus {
            #expect(err.contains("Security clearance denied"))
        } else {
            Issue.record("Expected failed status")
        }

        let stageResults = runner.stageResults
        #expect(stageResults.count == 1) // Only stage 1 ran, stage 3 did not run
    }

    // MARK: - Test 9: Peer Delegation Tracking and TraceBus Streaming

    @Test @MainActor func testPeerDelegationTrackingAndTraceBus() async throws {
        TraceBus.shared.clear()
        let roster = createStandard5BotRoster()
        let prPlaybook = CollaborationPlaybook.fullPRReviewLoop

        let runner = PlaybookRunner(playbook: prPlaybook, availableBots: roster)

        let executionTask = Task {
            try await runner.execute(contextInput: "PR #550: Refactor Storage Layer")
        }

        // Wait for approval gate in stage 4
        for _ in 0..<50 {
            let status = runner.status
            if case .waitingForApproval = status {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        runner.approvePendingStage(notes: "All reviews passed")
        let report = try await executionTask.value

        #expect(report.isSuccessful == true)
        #expect(!report.delegationEvents.isEmpty)

        // Verify delegation events
        for event in report.delegationEvents {
            #expect(!event.fromBotName.isEmpty)
            #expect(!event.toBotName.isEmpty)
            #expect(!event.action.isEmpty)
            #expect(event.status == .completed)
        }

        // Verify TraceBus received trace events
        let traces = TraceBus.shared.recentEvents(limit: 100)
        let playbookTraces = traces.filter { $0.source == "PlaybookRunner" }
        #expect(!playbookTraces.isEmpty)

        let operations = Set(playbookTraces.map(\.operation))
        #expect(operations.contains("playbook_started"))
        #expect(operations.contains("stage_started"))
        #expect(operations.contains("peer_delegation"))
        #expect(operations.contains("approval_gate_paused"))
        #expect(operations.contains("approval_resolved"))
        #expect(operations.contains("stage_completed"))
        #expect(operations.contains("playbook_completed"))
    }

    // MARK: - Test 10: BotManager Playbook Execution Integration

    @Test @MainActor func testBotManagerPlaybookExecutionIntegration() async throws {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)

        // Seed standard roster in botManager
        _ = botManager.createBot(name: "Apex", title: "General Assistant", descriptionText: "Helpful assistant")
        let cos = botManager.createBot(name: "Chief of Staff", title: "Executive Coordinator", descriptionText: "Workflow manager")
        cos.isChiefOfStaff = true
        _ = botManager.createBot(name: "Code Architect", title: "Senior Engineer", descriptionText: "Architecture lead")
        _ = botManager.createBot(name: "Researcher", title: "Deep Research Specialist", descriptionText: "Security analyst")
        _ = botManager.createBot(name: "Automator", title: "macOS System Automator", descriptionText: "CI runner")

        #expect(botManager.allBots.count == 5)

        // Execute Weekly Standup & Retrospective through BotManager
        let report = try await botManager.executeCollaborationPlaybook(
            preset: .weeklyStandupAndRetrospective,
            context: "Cycle 34 Engineering Sprint"
        )

        #expect(report.isSuccessful == true)
        #expect(report.stageResults.count == 2)
        #expect(report.stageResults[0].dispatchMode == .parallel)
        #expect(report.stageResults[0].botResults.count == 5)
        #expect(report.stageResults[1].dispatchMode == .sequential)

        // Test host has no live model access: report must be honest simulation,
        // never canned "briefing" claims.
        #expect(report.executionMode == .simulated)
        #expect(report.stageResults[1].botResults.allSatisfy { $0.isSimulated })
        #expect(report.finalOutput.contains("[SIMULATION"))
        #expect(report.finalOutput.contains("Chief of Staff"))

        // Check history tracking in BotManager
        #expect(botManager.playbookHistory.count == 1)
        #expect(botManager.playbookHistory[0].id == report.id)
    }

    // MARK: - Test 11: End-to-End Issue-to-Patch Pipeline

    @Test @MainActor func testEndToEndIssueToPatchPipeline() async throws {
        let roster = createStandard5BotRoster()
        let pipeline = CollaborationPlaybook.issueToPatchPipeline

        let runner = PlaybookRunner(playbook: pipeline, availableBots: roster)

        let executionTask = Task {
            try await runner.execute(contextInput: "Issue #210: Sandbox symlink traversal vulnerability detected in /private/tmp")
        }

        // Wait for Stage 5 Approval Gate
        for _ in 0..<50 {
            let status = runner.status
            if case .waitingForApproval = status {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        runner.approvePendingStage(notes: "Verified patched symlink resolution")
        let report = try await executionTask.value

        #expect(report.isSuccessful == true)
        #expect(report.stageResults.count == 5)
        #expect(report.stageResults[0].stageId == "stage_issue_triage")
        #expect(report.stageResults[1].stageId == "stage_root_cause")
        #expect(report.stageResults[2].stageId == "stage_patch_authoring")
        #expect(report.stageResults[3].stageId == "stage_test_benchmark")
        #expect(report.stageResults[4].stageId == "stage_patch_approval_gate")
    }

    // MARK: - Test 12: Approval Timeout Auto-Rejects (Fail-Safe Against Hanging)

    @Test @MainActor func testApprovalTimeoutAutoRejects() async throws {
        let roster = createStandard5BotRoster()

        let stages = [
            PlaybookStageDefinition(
                id: "stage_gate",
                name: "Unattended Gate",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Gate",
                requiresApproval: true,
                approvalDescription: "Nobody will answer this gate"
            ),
            PlaybookStageDefinition(
                id: "stage_should_not_run",
                name: "Should Not Run",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "After gate"
            )
        ]

        let playbook = CollaborationPlaybook(
            id: UUID(),
            name: "Timeout Gate Test",
            roles: [.chiefOfStaff],
            stages: stages
        )

        let runner = PlaybookRunner(playbook: playbook, availableBots: roster)
        runner.approvalTimeout = 0.2 // fail fast in test

        // Never answer the gate — the fail-safe timeout must resolve it.
        do {
            _ = try await runner.execute(contextInput: "unattended")
            Issue.record("Expected approvalRejected after timeout but execution succeeded")
        } catch let error as PlaybookExecutionError {
            if case .approvalRejected(let stageId, let reason) = error {
                #expect(stageId == "stage_gate")
                #expect(reason.lowercased().contains("timed out"))
            } else {
                Issue.record("Unexpected PlaybookExecutionError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        // Timeout never auto-approves; the timed-out card is rejected and
        // later stages never run.
        #expect(runner.approvalCards.count == 1)
        #expect(runner.approvalCards[0].status == .rejected)
        #expect((runner.approvalCards[0].resolutionNotes ?? "").lowercased().contains("timed out"))
        #expect(runner.stageResults.isEmpty)
        #expect(runner.pendingApprovalCard == nil)
    }

    // MARK: - Test 13: onApprovalRequired Callback Fires (PROJECT M2 Contract)

    @Test @MainActor func testOnApprovalRequiredCallbackFires() async throws {
        let roster = createStandard5BotRoster()

        let stages = [
            PlaybookStageDefinition(
                id: "stage_gate",
                name: "Callback Gate",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Gate",
                requiresApproval: true,
                approvalDescription: "Callback should fire for this card"
            )
        ]

        let playbook = CollaborationPlaybook(
            id: UUID(),
            name: "Approval Callback Test",
            roles: [.chiefOfStaff],
            stages: stages
        )

        let runner = PlaybookRunner(playbook: playbook, availableBots: roster)

        var receivedCard: PlaybookApprovalCard?
        let executionTask = Task {
            try await runner.execute(
                contextInput: "callback",
                onApprovalRequired: { card in receivedCard = card }
            )
        }

        // Wait for approval gate
        for _ in 0..<50 {
            let status = runner.status
            if case .waitingForApproval = status {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        runner.approvePendingStage(notes: "Approved after callback")
        let report = try await executionTask.value

        #expect(report.isSuccessful == true)
        #expect(receivedCard?.stageId == "stage_gate")
        #expect(receivedCard?.playbookId == playbook.id)
        // Callback fires while the card is still pending so UI can present it.
        #expect(receivedCard?.status == .pending)
    }

    // MARK: - Test 14: onDelegationEvent Callback Fires (PROJECT M2 Contract)

    @Test @MainActor func testOnDelegationEventCallbackFires() async throws {
        let roster = createStandard5BotRoster()

        let stages = [
            PlaybookStageDefinition(
                id: "stage_one",
                name: "First",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Start: {input}"
            ),
            PlaybookStageDefinition(
                id: "stage_two",
                name: "Second",
                dispatchMode: .sequential,
                requiredRole: .codeArchitect,
                promptTemplate: "Continue: {previousOutput}"
            )
        ]

        let playbook = CollaborationPlaybook(
            id: UUID(),
            name: "Delegation Callback Test",
            roles: [.chiefOfStaff, .codeArchitect],
            stages: stages
        )

        let runner = PlaybookRunner(playbook: playbook, availableBots: roster)

        var receivedEvents: [PlaybookDelegationEvent] = []
        let report = try await runner.execute(
            contextInput: "delegate",
            onDelegationEvent: { receivedEvents.append($0) }
        )

        #expect(report.isSuccessful == true)
        // Sequential handoff from Chief of Staff to Code Architect
        #expect(!receivedEvents.isEmpty)
        #expect(receivedEvents.count == report.delegationEvents.count)
        #expect(receivedEvents.allSatisfy { !$0.fromBotName.isEmpty && !$0.toBotName.isEmpty })
        #expect(receivedEvents.contains(where: { $0.action == "sequential_handoff" }))
    }

    // MARK: - Test 15: Backward-Compatible Decoding of Pre-Change Reports

    @Test func testLegacyReportDecodingDefaultsToSimulated() throws {
        // Reports written before executionMode/isSimulated existed lack those
        // keys; they must still decode, defaulting to the honest `.simulated`.
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "playbookId": "\(UUID().uuidString)",
            "playbookName": "Legacy Report",
            "contextInput": "old input",
            "stageResults": [],
            "delegationEvents": [],
            "approvalCards": [],
            "finalOutput": "old canned output",
            "totalDuration": 1.5,
            "startedAt": 0,
            "completedAt": 1,
            "isSuccessful": true
        }
        """
        let report = try JSONDecoder().decode(
            PlaybookExecutionReport.self,
            from: legacyJSON.data(using: .utf8)!
        )
        #expect(report.executionMode == .simulated)
        #expect(report.playbookName == "Legacy Report")
        #expect(report.isSuccessful == true)

        let legacyTurnJSON = """
        {
            "id": "\(UUID().uuidString)",
            "botId": "\(UUID().uuidString)",
            "botName": "Old Bot",
            "roleId": "code_architect",
            "output": "old canned output",
            "duration": 0.1,
            "timestamp": 0
        }
        """
        let turn = try JSONDecoder().decode(
            PlaybookBotResult.self,
            from: legacyTurnJSON.data(using: .utf8)!
        )
        #expect(turn.isSimulated == true)
        #expect(turn.botName == "Old Bot")
    }

    // MARK: - Test: BotManager Active Playbook Runner Approval Resolution

    @Test @MainActor func testBotManagerActivePlaybookApprovalResolution() async throws {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let manager = BotManager(orchestrator: orchestrator, computer: computer)
        if manager.allBots.isEmpty {
            _ = manager.createBot(name: "Apex", title: "General Assistant", descriptionText: "Helpful assistant")
            let cos = manager.createBot(name: "Chief of Staff", title: "Executive Coordinator", descriptionText: "Workflow manager")
            cos.isChiefOfStaff = true
            _ = manager.createBot(name: "Code Architect", title: "Senior Engineer", descriptionText: "Architecture lead")
            _ = manager.createBot(name: "Researcher", title: "Deep Research Specialist", descriptionText: "Research lead")
            _ = manager.createBot(name: "Automator", title: "macOS System Automator", descriptionText: "Automation lead")
        }

        var approvalHookCalled = false
        var observedRunnerDuringHook: PlaybookRunner?

        let report = try await manager.executeCollaborationPlaybook(
            preset: .fullPRReviewLoop,
            context: "PR #429 real functional review",
            onApprovalRequired: { card in
                approvalHookCalled = true
                observedRunnerDuringHook = manager.activePlaybookRunner
                #expect(observedRunnerDuringHook != nil)
                #expect(observedRunnerDuringHook?.pendingApprovalCard?.id == card.id)
                // Resolve approval using BotManager API
                let handled = manager.resolvePlaybookApproval(cardId: card.id, approved: true, notes: "Approved by test auditor")
                #expect(handled == true)
            }
        )

        #expect(approvalHookCalled == true)
        #expect(report.isSuccessful == true)
        #expect(report.approvalCards.count == 1)
        #expect(report.approvalCards.first?.status == PlaybookApprovalStatus.approved)
        #expect(report.approvalCards.first?.resolutionNotes == "Approved by test auditor")

        // Active runner must be nil after execution completes
        #expect(manager.activePlaybookRunner == nil)
    }

    @Test @MainActor func testBotManagerActivePlaybookRejectionResolution() async throws {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let manager = BotManager(orchestrator: orchestrator, computer: computer)
        if manager.allBots.isEmpty {
            _ = manager.createBot(name: "Apex", title: "General Assistant", descriptionText: "Helpful assistant")
            let cos = manager.createBot(name: "Chief of Staff", title: "Executive Coordinator", descriptionText: "Workflow manager")
            cos.isChiefOfStaff = true
            _ = manager.createBot(name: "Code Architect", title: "Senior Engineer", descriptionText: "Architecture lead")
            _ = manager.createBot(name: "Researcher", title: "Deep Research Specialist", descriptionText: "Research lead")
            _ = manager.createBot(name: "Automator", title: "macOS System Automator", descriptionText: "Automation lead")
        }

        var rejectionHookCalled = false

        await #expect(throws: PlaybookExecutionError.self) {
            try await manager.executeCollaborationPlaybook(
                preset: .fullPRReviewLoop,
                context: "PR #430 rejection check",
                onApprovalRequired: { card in
                    rejectionHookCalled = true
                    manager.rejectActivePlaybookStage(reason: "Rejected by test auditor")
                }
            )
        }

        #expect(rejectionHookCalled == true)
        #expect(manager.activePlaybookRunner == nil)
    }

    @Test @MainActor func testConcurrentPlaybookApprovalsRoutedByCardId() async throws {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let manager = BotManager(orchestrator: orchestrator, computer: computer)
        if manager.allBots.isEmpty {
            _ = manager.createBot(name: "Apex", title: "General Assistant", descriptionText: "Helpful assistant")
            let cos = manager.createBot(name: "Chief of Staff", title: "Executive Coordinator", descriptionText: "Workflow manager")
            cos.isChiefOfStaff = true
            _ = manager.createBot(name: "Code Architect", title: "Senior Engineer", descriptionText: "Architecture lead")
            _ = manager.createBot(name: "Researcher", title: "Deep Research Specialist", descriptionText: "Research lead")
            _ = manager.createBot(name: "Automator", title: "macOS System Automator", descriptionText: "Automation lead")
        }

        async let task1 = manager.executeCollaborationPlaybook(
            preset: .fullPRReviewLoop,
            context: "PR #1 concurrent test",
            onApprovalRequired: { card in
                let resolved = await MainActor.run {
                    manager.resolvePlaybookApproval(cardId: card.id, approved: true, notes: "Approved PR 1")
                }
                #expect(resolved == true)
            }
        )

        async let task2 = manager.executeCollaborationPlaybook(
            preset: .fullPRReviewLoop,
            context: "PR #2 concurrent test",
            onApprovalRequired: { card in
                let resolved = await MainActor.run {
                    manager.resolvePlaybookApproval(cardId: card.id, approved: true, notes: "Approved PR 2")
                }
                #expect(resolved == true)
            }
        )

        let (report1, report2) = try await (task1, task2)
        #expect(report1.isSuccessful == true)
        #expect(report2.isSuccessful == true)
        #expect(manager.activePlaybookRunners.isEmpty == true)
    }
}
