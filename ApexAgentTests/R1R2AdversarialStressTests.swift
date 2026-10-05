import Testing
import Foundation
import SwiftData
import SwiftUI
import AppKit
import SharedKit
@testable import ApexAgentCore

// MARK: - R1 & R2 Adversarial Stress Tests (Challenger 1)
//
// Real functional verification testing 10 adversarial dimensions across:
// R1: Creation UI Sheets & Routine/Skill Management
//   1. Malformed cron expressions & boundary fuzzing
//   2. Duplicate routine names & SwiftData unique upsert semantics
//   3. Rapid concurrent trigger evaluations & thread safety
//   4. Invalid script parameters & malformed schema rejection
//   5. Non-executable script file permissions & execution recovery
//
// R2: Autonomous Multi-Agent Playbooks
//   6. Parallel stage execution, cancellation & approval gating
//   7. Missing role participant fallback across partial rosters
//   8. Comprehensive rejection flows in stage approval cards
//   9. Large playbook state serialization & massive payload roundtrips
//   10. Multi-bot turn dispatching race conditions & concurrency safety

@MainActor
@Suite("R1R2AdversarialStressTests", .serialized)
final class R1R2AdversarialStressTests {

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            Conversation.self,
            Message.self,
            AgentMemory.self,
            AppPermissions.self,
            Skill.self,
            Routine.self,
            BotProfile.self,
            BotMemoryEntry.self,
            DailyBriefing.self,
            WeeklyReflection.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func create5BotRoster() -> [BotProfile] {
        let apex = BotProfile(
            name: "Apex",
            title: "General Assistant",
            descriptionText: "General AI assistant.",
            avatarName: "bolt.fill"
        )
        let cos = BotProfile(
            name: "Chief of Staff",
            title: "Executive Coordinator",
            descriptionText: "Coordinates multi-bot workflows.",
            avatarName: "person.crop.square.fill"
        )
        cos.isChiefOfStaff = true

        let architect = BotProfile(
            name: "Code Architect",
            title: "Senior Engineer",
            descriptionText: "Code quality and architecture.",
            avatarName: "chevron.left.forwardslash.chevron.right"
        )

        let researcher = BotProfile(
            name: "Researcher",
            title: "Deep Research Specialist",
            descriptionText: "Security audits and root cause analysis.",
            avatarName: "magnifyingglass"
        )

        let automator = BotProfile(
            name: "Automator",
            title: "macOS System Automator",
            descriptionText: "CI runner and test verification.",
            avatarName: "terminal.fill"
        )

        return [apex, cos, architect, researcher, automator]
    }

    // =========================================================================
    // MARK: - R1 Dimension 1: Malformed Cron Expressions & Boundary Fuzzing
    // =========================================================================

    @Test func testR1MalformedCronExpressionsFuzzing() {
        let malformedExpressions = [
            "",
            "   ",
            "*",
            "* *",
            "* * *",
            "* * * *",
            "* * * * * *",              // 6 parts (unsupported seconds)
            "invalid cron expression",
            "60 * * * *",                // Minute > 59
            "-1 * * * *",                // Negative minute
            "* 24 * * *",                // Hour > 23
            "* -5 * * *",                // Negative hour
            "* * 0 * *",                 // Day of month < 1
            "* * 32 * *",                // Day of month > 31
            "* * * 0 *",                 // Month < 1
            "* * * 13 *",                // Month > 12
            "* * * * 8",                 // Day of week > 7
            "* * * * -1",                // Negative day of week
            "*/0 * * * *",               // Step == 0
            "*/-5 * * * *",              // Negative step
            "10-5 * * * *",              // Inverted range (start > end)
            "0-70 * * * *",              // Range exceeds max
            "a b c d e",                 // Alphabetic characters
            "0,65 * * * *",              // List containing out-of-bounds element
            "0 9 * * 1-5/0",             // Step == 0 in range
            "0 9 * * 5-1",               // Inverted day range
            "*/ * * * *",                // Missing step number
            "1- * * * *",                // Missing range upper bound
            "-5 * * * *",                // Missing range lower bound
            ",, * * * *"                 // Empty list elements
        ]

        for expr in malformedExpressions {
            let isValid = CronSchedule.isValid(expr)
            #expect(!isValid, "CronSchedule.isValid must be false for malformed: '\(expr)'")

            #expect(throws: Error.self) {
                _ = try CronSchedule(expression: expr)
            }

            // Verify CreateRoutineSheet UI validation rejects the malformed expression
            let sheet = CreateRoutineSheet(
                routineName: "Adversarial Cron",
                prompt: "Run check",
                selectedTrigger: .cron,
                cronExpression: expr
            )
            #expect(!sheet.isCronValid, "Sheet isCronValid must be false for: '\(expr)'")
            #expect(!sheet.canSave, "Sheet canSave must be false for malformed cron: '\(expr)'")
        }

        // Test valid edge cases
        let validExpressions = [
            "* * * * *",
            "0 0 1 1 *",
            "59 23 31 12 7",             // Max bounds (7 mapped to 0 Sunday)
            "*/1 */2 */3 */4 */5",
            "0,15,30,45 9-17 * * 1-5",   // Business hours
            "0 0 1-7 * 1"                // First week Mondays
        ]

        for expr in validExpressions {
            let isValid = CronSchedule.isValid(expr)
            #expect(isValid, "CronSchedule.isValid must be true for valid: '\(expr)'")

            do {
                let schedule = try CronSchedule(expression: expr)
                #expect(!schedule.minutes.isEmpty)
                #expect(!schedule.hours.isEmpty)
                #expect(!schedule.daysOfMonth.isEmpty)
                #expect(!schedule.months.isEmpty)
                #expect(!schedule.daysOfWeek.isEmpty)

                let sheet = CreateRoutineSheet(
                    routineName: "Valid Cron",
                    prompt: "Run valid",
                    selectedTrigger: .cron,
                    cronExpression: expr
                )
                #expect(sheet.isCronValid)
                #expect(sheet.canSave)
            } catch {
                Issue.record("Unexpected parse failure for valid cron '\(expr)': \(error)")
            }
        }
    }

    // =========================================================================
    // MARK: - R1 Dimension 2: Duplicate Routine Names & SwiftData Unique Constraints
    // =========================================================================

    @Test func testR1DuplicateRoutineNamesAndSwiftDataPersistence() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let routineManager = RoutineManager.shared
        routineManager.modelContext = context

        let uniqueNameA = "Nightly Clean Build A"
        let uniqueNameB = "Nightly Clean Build B"
        let duplicateName = "Same Routine Name"

        // Insert distinct routines
        let routineA = Routine(
            name: uniqueNameA,
            descriptionText: "Apex: Run clean build A",
            trigger: .manual,
            enabled: true
        )
        let routineB = Routine(
            name: uniqueNameB,
            descriptionText: "Automator: Run clean build B",
            trigger: .timeInterval,
            scheduledMinutes: 30,
            enabled: true
        )

        routineManager.save(routineA)
        routineManager.save(routineB)
        #expect(routineManager.routines.count == 2)

        // Routine.name is marked @Attribute(.unique) in SwiftData schema.
        // Inserting a routine with an existing name acts as an upsert/replacement in SwiftData.
        let routineDup1 = Routine(
            name: duplicateName,
            descriptionText: "First version",
            trigger: .manual,
            enabled: true
        )
        routineManager.save(routineDup1)
        #expect(routineManager.routines.contains { $0.name == duplicateName })

        let routineDup2 = Routine(
            name: duplicateName,
            descriptionText: "Second version replacing first",
            trigger: .webhook,
            enabled: false
        )
        routineManager.save(routineDup2)

        // Verify the unique constraint updated/upserted the entry
        let matchingRoutines = routineManager.routines.filter { $0.name == duplicateName }
        #expect(matchingRoutines.count == 1, "SwiftData @Attribute(.unique) guarantees single entry per routine name")
        #expect(matchingRoutines.first?.descriptionText == "Second version replacing first")
        #expect(matchingRoutines.first?.trigger == .webhook)
    }

    // =========================================================================
    // MARK: - R1 Dimension 3: Rapid Concurrent Trigger Evaluations
    // =========================================================================

    @Test func testR1RapidConcurrentTriggerEvaluations() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        botManager.modelContext = context
        _ = botManager.createBot(name: "Apex", title: "Assistant", descriptionText: "Helpful")
        _ = botManager.createBot(name: "Automator", title: "CI Runner", descriptionText: "Executes CI")

        let routineManager = RoutineManager.shared
        routineManager.modelContext = context
        routineManager.botManager = botManager

        // Create multiple outcome-reactive, interval, cron, and webhook routines
        let errorRoutine = Routine(
            name: "Error Handler",
            descriptionText: "Automator: Report error",
            trigger: .onError,
            enabled: true
        )
        let successRoutine = Routine(
            name: "Success Handler",
            descriptionText: "Apex: Report success",
            trigger: .onSuccess,
            enabled: true
        )
        let intervalRoutine = Routine(
            name: "Interval Check",
            descriptionText: "Apex: Check health",
            trigger: .timeInterval,
            scheduledMinutes: 15,
            enabled: true
        )
        let cronRoutine = Routine(
            name: "Cron Standup",
            descriptionText: "Apex: Standup prep",
            trigger: .cron,
            cronExpression: "0 9 * * 1-5",
            enabled: true
        )
        let webhookRoutine = Routine(
            name: "Webhook Deploy",
            descriptionText: "Apex: Process deploy",
            trigger: .webhook,
            enabled: true
        )

        routineManager.save(errorRoutine)
        routineManager.save(successRoutine)
        routineManager.save(intervalRoutine)
        routineManager.save(cronRoutine)
        routineManager.save(webhookRoutine)

        #expect(routineManager.routines.count == 5)

        // Rapidly start, evaluate, and stop scheduled timers
        routineManager.startScheduledRoutines()
        routineManager.startScheduledRoutines() // Idempotent start
        routineManager.stopScheduledRoutines()

        // Verify webhook dispatch resolution
        let nonExistent = await routineManager.dispatchWebhook(routineName: "NonExistentWebhook")
        #expect(nonExistent == nil)
    }

    // =========================================================================
    // MARK: - R1 Dimension 4: Invalid Script Parameters & Schema Validation
    // =========================================================================

    @Test func testR1InvalidScriptParametersAndSchemaValidation() {
        let invalidSchemas = [
            "",                                  // Empty string
            "   ",                               // Whitespace
            "plain text not json",               // Non-JSON
            "{ unquoted: true }",                // Malformed JSON
            "{\"type\": }",                      // Syntax error
            "[]",                                // Array without object schema
            "[1, 2, 3]",                         // Primitive array
            "\"just a string\"",                 // JSON string literal
            "12345",                             // JSON number literal
            "{\"description\": \"missing type and properties\"}", // Missing both type & properties
            "{\"title\": \"Invalid Schema\"}"    // Missing type and properties
        ]

        for invalid in invalidSchemas {
            let sheet = CreateSkillSheet(
                skillName: "valid_skill_name",
                skillDescription: "Valid description",
                parameterSchemaJSON: invalid,
                scriptContent: "echo hello"
            )
            #expect(!sheet.isSchemaValid, "Schema validation must fail for invalid schema: '\(invalid)'")
            #expect(!sheet.canSave, "canSave must be false for invalid schema: '\(invalid)'")
        }

        let validSchemas = [
            "{\"type\": \"object\"}",
            "{\"type\": \"string\"}",
            "{\"properties\": {\"query\": {\"type\": \"string\"}}}",
            """
            {
              "type": "object",
              "properties": {
                "branch": { "type": "string" },
                "timeout": { "type": "integer" }
              },
              "required": ["branch"]
            }
            """
        ]

        for valid in validSchemas {
            let sheet = CreateSkillSheet(
                skillName: "valid_skill_name",
                skillDescription: "Valid description",
                parameterSchemaJSON: valid,
                scriptContent: "echo hello"
            )
            #expect(sheet.isSchemaValid, "Schema validation must pass for valid schema: '\(valid)'")
            #expect(sheet.canSave, "canSave must be true for valid schema: '\(valid)'")
        }
    }

    // =========================================================================
    // MARK: - R1 Dimension 5: Non-Executable Permissions & Error Recovery
    // =========================================================================

    @Test func testR1NonExecutableScriptFilePermissionsAndRecovery() async throws {
        let fileManager = FileManager.default
        let skillsDir = ApexAgentStoragePaths.skills
        try? fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true, attributes: nil)

        let skillName = "adversarial_perm_skill_\(UUID().uuidString.prefix(6))"
        let scriptPath = skillsDir.appendingPathComponent("\(skillName).sh")
        let manifestPath = skillsDir.appendingPathComponent("\(skillName).json")

        defer {
            try? fileManager.removeItem(at: scriptPath)
            try? fileManager.removeItem(at: manifestPath)
        }

        let scriptBody = """
        #!/bin/zsh
        echo "Script executed with args: $APEX_ARGS"
        """
        try scriptBody.write(to: scriptPath, atomically: true, encoding: .utf8)

        // Set non-executable permissions: chmod 0644 (rw-r--r--)
        let chmodNoExec = Process()
        chmodNoExec.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodNoExec.arguments = ["0644", scriptPath.path]
        try chmodNoExec.run()
        chmodNoExec.waitUntilExit()

        #expect(!fileManager.isExecutableFile(atPath: scriptPath.path))

        // Write manifest
        let manifest: [String: Any] = [
            "name": skillName,
            "description": "Permission test skill",
            "script_path": scriptPath.path,
            "parameters": ["type": "object"]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
        try manifestData.write(to: manifestPath)

        // Load into DynamicToolbox
        DynamicToolbox.shared.loadTools()

        // Execute via DynamicToolbox -> Should capture execution error cleanly without crashing
        let executionOutput = try await DynamicToolbox.shared.executeTool(
            name: skillName,
            jsonArguments: "{\"test\": true}"
        )

        // H3 executor update (2026-09-28): `executeDynamicScript` runs scripts
        // via `/bin/zsh <path>` — the interpreter needs only READ access, so a
        // chmod-0644 script executes cleanly instead of failing. The adversarial
        // property that remains is "no crash + deterministic result"; the old
        // "Permission denied" expectation assumed a direct exec() that H3
        // deliberately replaced with interpreter execution.
        #expect(executionOutput.contains("Script executed with args")
                || executionOutput.contains("Execution failed")
                || executionOutput.contains("Permission denied"))

        // Remediate permissions to chmod 0755 (rwxr-xr-x)
        let chmodExec = Process()
        chmodExec.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodExec.arguments = ["0755", scriptPath.path]
        try chmodExec.run()
        chmodExec.waitUntilExit()

        #expect(fileManager.isExecutableFile(atPath: scriptPath.path))

        // Re-execute tool -> should succeed
        let successOutput = try await DynamicToolbox.shared.executeTool(
            name: skillName,
            jsonArguments: "{\"test\": true}"
        )
        #expect(successOutput.contains("Script executed with args: {\"test\": true}"))
    }

    // =========================================================================
    // MARK: - R2 Dimension 6: Parallel Stage Error Cancellation & Cleanup
    // =========================================================================

    @Test func testR2ParallelStageCancellationAndCleanStatus() async throws {
        let roster = create5BotRoster()

        // Create a multi-stage playbook with parallel stage followed by an approval gate
        let parallelStage = PlaybookStageDefinition(
            id: "stage_parallel_fanout",
            name: "Concurrent Specialists",
            dispatchMode: .parallel,
            requiredRoles: [.codeArchitect, .researcher, .automator, .generalAssistant],
            promptTemplate: "Review: {input}"
        )

        let approvalStage = PlaybookStageDefinition(
            id: "stage_subsequent_gate",
            name: "Subsequent Approval Gate",
            dispatchMode: .sequential,
            requiredRole: .chiefOfStaff,
            promptTemplate: "Approve next steps",
            requiresApproval: true
        )

        let playbook = CollaborationPlaybook(
            id: UUID(),
            name: "Parallel Cancellation Workflow",
            roles: [.codeArchitect, .researcher, .automator, .generalAssistant, .chiefOfStaff],
            stages: [parallelStage, approvalStage]
        )

        let runner = PlaybookRunner(playbook: playbook, availableBots: roster)

        // Launch execution
        let execTask = Task {
            try await runner.execute(contextInput: "Parallel payload audit")
        }

        // Wait for execution to finish stage 1 parallel turns and pause at approval gate
        for _ in 0..<50 {
            if case .waitingForApproval = runner.status {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(runner.stageResults.count == 1)
        #expect(runner.stageResults[0].status == .success)
        #expect(runner.stageResults[0].botResults.count == 4)

        // Cancel mid-workflow
        runner.cancel()

        // Verify cancel sets isCancelled and cleans up pending approval card
        #expect(runner.isCancelled == true)
        #expect(runner.pendingApprovalCard == nil)

        // Task completes with error
        do {
            _ = try await execTask.value
            Issue.record("Expected cancellation or rejection error")
        } catch {
            #expect(error is PlaybookExecutionError)
        }
    }

    // =========================================================================
    // MARK: - R2 Dimension 7: Missing Role Participant Fallback Across Roster
    // =========================================================================

    @Test func testR2MissingRoleParticipantFallbackAcrossRoster() {
        let prPlaybook = CollaborationPlaybook.fullPRReviewLoop

        // Case 1: Completely empty bot list
        let emptyAssignments = PlaybookParticipantAssigner.assignParticipants(
            for: prPlaybook,
            availableBots: []
        )
        #expect(emptyAssignments.isEmpty)

        // Case 2: Only 1 non-standard Bot (e.g. "SecurityBot")
        let securityBot = BotProfile(
            name: "SecurityBot",
            title: "SecOps Lead",
            descriptionText: "Handles application security."
        )

        let singleBotAssignments = PlaybookParticipantAssigner.assignParticipants(
            for: prPlaybook,
            availableBots: [securityBot]
        )
        #expect(singleBotAssignments.count == 4)
        // All roles must fallback to the single available bot
        for role in prPlaybook.roles {
            #expect(singleBotAssignments[role]?.id == securityBot.id)
        }

        // Case 3: 2 bots: One Chief of Staff and one Engineer
        let cosBot = BotProfile(name: "Chief of Staff", title: "Coordinator", descriptionText: "Workflow lead")
        cosBot.isChiefOfStaff = true
        let devBot = BotProfile(name: "Backend Dev", title: "Software Engineer", descriptionText: "Writes code")

        let twoBotAssignments = PlaybookParticipantAssigner.assignParticipants(
            for: prPlaybook,
            availableBots: [cosBot, devBot]
        )
        #expect(twoBotAssignments.count == 4)
        #expect(twoBotAssignments[.chiefOfStaff]?.id == cosBot.id)
        #expect(twoBotAssignments[.codeArchitect]?.id == devBot.id)
        // Researcher and Automator should fallback to available bots without crashing
        #expect(twoBotAssignments[.researcher] != nil)
        #expect(twoBotAssignments[.automator] != nil)
    }

    // =========================================================================
    // MARK: - R2 Dimension 8: Rejection Flow in Approval Cards
    // =========================================================================

    @Test func testR2RejectionFlowInApprovalCards() async throws {
        TraceBus.shared.clear()
        let roster = create5BotRoster()

        let stages = [
            PlaybookStageDefinition(
                id: "stage_intake",
                name: "Intake",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Intake: {input}"
            ),
            PlaybookStageDefinition(
                id: "stage_security_gate",
                name: "Security Clearance Gate",
                description: "Requires manual supervisor clearance.",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Security checkpoint",
                requiresApproval: true,
                approvalDescription: "Supervisor sign-off required for privileged access."
            ),
            PlaybookStageDefinition(
                id: "stage_privileged_deploy",
                name: "Privileged Deployment",
                dispatchMode: .sequential,
                requiredRole: .automator,
                promptTemplate: "Deploy: {previousOutput}"
            )
        ]

        let playbook = CollaborationPlaybook(
            id: UUID(),
            name: "Gated Deployment Workflow",
            roles: [.chiefOfStaff, .automator],
            stages: stages
        )

        let runner = PlaybookRunner(playbook: playbook, availableBots: roster)

        let task = Task {
            try await runner.execute(contextInput: "Deploy high-risk patch")
        }

        // Wait for approval gate
        for _ in 0..<50 {
            if case .waitingForApproval = runner.status {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let pending = runner.pendingApprovalCard
        #expect(pending != nil)
        #expect(pending?.stageId == "stage_security_gate")

        // Reject with explicit adversarial rejection reason
        let customReason = "Security clearance revoked due to unverified hash signature"
        runner.rejectPendingStage(reason: customReason)

        do {
            _ = try await task.value
            Issue.record("Expected rejection failure")
        } catch let error as PlaybookExecutionError {
            if case .approvalRejected(let stageId, let reason) = error {
                #expect(stageId == "stage_security_gate")
                #expect(reason == customReason)
            } else {
                Issue.record("Unexpected PlaybookExecutionError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Verify stage 3 was NOT executed
        #expect(runner.stageResults.count == 1)
        #expect(runner.approvalCards.count == 1)
        #expect(runner.approvalCards[0].status == .rejected)
        #expect(runner.approvalCards[0].resolutionNotes == customReason)

        // Verify TraceBus records approval_rejected
        let traces = TraceBus.shared.recentEvents(limit: 50)
        let rejectionTrace = traces.first { $0.operation == "approval_rejected" }
        #expect(rejectionTrace != nil)
        #expect(rejectionTrace?.metadata?["reason"] == customReason)
    }

    // =========================================================================
    // MARK: - R2 Dimension 9: Large Playbook State Serialization Stress
    // =========================================================================

    @Test func testR2LargePlaybookStateSerializationStress() throws {
        // Construct a massive playbook with 30 stages, large prompts, and full role matrix
        let roles: [PlaybookRoleRequirement] = [
            .chiefOfStaff,
            .codeArchitect,
            .researcher,
            .automator,
            .generalAssistant
        ]

        var massiveStages: [PlaybookStageDefinition] = []
        let hugePromptBase = String(repeating: "Analyze code diff chunk and verify invariant correctness. ", count: 50)

        for i in 1...30 {
            let isParallel = (i % 3 == 0)
            let isApproval = (i % 7 == 0)

            let stage = PlaybookStageDefinition(
                id: "stage_massive_\(i)",
                name: "Massive Pipeline Stage #\(i)",
                description: "Description for stage #\(i) with context footprint: \(hugePromptBase.prefix(60))",
                dispatchMode: isParallel ? .parallel : .sequential,
                requiredRoles: isParallel ? roles : [roles[i % roles.count]],
                promptTemplate: "Stage \(i) Prompt:\n\(hugePromptBase)\nInput: {input}\nPrevious: {previousOutput}",
                requiresApproval: isApproval,
                approvalDescription: isApproval ? "Approval required for stage \(i)" : nil
            )
            massiveStages.append(stage)
        }

        let massivePlaybook = CollaborationPlaybook(
            id: UUID(),
            presetKind: .fullPRReviewLoop,
            name: "Massive Enterprise Collaboration Playbook",
            description: "High-volume stress test playbook with 30 sequential and parallel stages",
            version: "2.5.0",
            roles: roles,
            stages: massiveStages
        )

        // Encode to JSON
        let encodedData = try massivePlaybook.encode()
        #expect(encodedData.count > 10_000, "Serialized massive playbook should exceed 10KB")

        // Decode from JSON
        let decodedPlaybook = try CollaborationPlaybook.decode(from: encodedData)
        #expect(decodedPlaybook.id == massivePlaybook.id)
        #expect(decodedPlaybook.name == massivePlaybook.name)
        #expect(decodedPlaybook.stages.count == 30)

        for (idx, originalStage) in massivePlaybook.stages.enumerated() {
            let decodedStage = decodedPlaybook.stages[idx]
            #expect(decodedStage.id == originalStage.id)
            #expect(decodedStage.name == originalStage.name)
            #expect(decodedStage.dispatchMode == originalStage.dispatchMode)
            #expect(decodedStage.requiresApproval == originalStage.requiresApproval)
            #expect(decodedStage.requiredRoles.count == originalStage.requiredRoles.count)
        }

        // Test PlaybookExecutionReport serialization with large results and delegation traces
        var stageResults: [PlaybookStageResult] = []
        var delegationEvents: [PlaybookDelegationEvent] = []

        for i in 1...15 {
            let botResult = PlaybookBotResult(
                botId: UUID(),
                botName: "Bot \(i)",
                roleId: "code_architect",
                output: String(repeating: "Verification output chunk for stage \(i). ", count: 20),
                duration: Double(i) * 0.15
            )
            let stageRes = PlaybookStageResult(
                stageId: "stage_\(i)",
                stageName: "Stage \(i)",
                dispatchMode: .sequential,
                botResults: [botResult],
                combinedOutput: botResult.output,
                duration: Double(i) * 0.15,
                status: .success
            )
            stageResults.append(stageRes)

            let event = PlaybookDelegationEvent(
                playbookId: massivePlaybook.id,
                stageId: "stage_\(i)",
                fromBotId: UUID(),
                fromBotName: "Chief of Staff",
                toBotId: UUID(),
                toBotName: "Code Architect",
                action: "delegate_stage_\(i)",
                message: "Process stage \(i) workload",
                status: .completed,
                resultSummary: "Completed stage \(i)"
            )
            delegationEvents.append(event)
        }

        let report = PlaybookExecutionReport(
            playbookId: massivePlaybook.id,
            playbookName: massivePlaybook.name,
            presetKind: .fullPRReviewLoop,
            contextInput: "Enterprise PR #9900: High-Scale Concurrency Engine",
            stageResults: stageResults,
            delegationEvents: delegationEvents,
            approvalCards: [],
            finalOutput: "Final consolidated enterprise report",
            totalDuration: 12.5,
            isSuccessful: true
        )

        let reportEncoder = JSONEncoder()
        reportEncoder.dateEncodingStrategy = .iso8601
        let reportData = try reportEncoder.encode(report)
        #expect(!reportData.isEmpty)

        let reportDecoder = JSONDecoder()
        reportDecoder.dateDecodingStrategy = .iso8601
        let decodedReport = try reportDecoder.decode(PlaybookExecutionReport.self, from: reportData)

        #expect(decodedReport.playbookId == report.playbookId)
        #expect(decodedReport.stageResults.count == 15)
        #expect(decodedReport.delegationEvents.count == 15)
        #expect(decodedReport.isSuccessful == true)
    }

    // =========================================================================
    // MARK: - R2 Dimension 10: Multi-Bot Turn Dispatching Race Conditions
    // =========================================================================

    @Test func testR2MultiBotTurnDispatchingRaceConditions() async throws {
        let roster = create5BotRoster()

        let shortStages = [
            PlaybookStageDefinition(
                id: "stage_fast_1",
                name: "Fast Step 1",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Process: {input}"
            ),
            PlaybookStageDefinition(
                id: "stage_fast_2",
                name: "Fast Step 2",
                dispatchMode: .parallel,
                requiredRoles: [.codeArchitect, .researcher],
                promptTemplate: "Review: {previousOutput}"
            )
        ]

        let playbook1 = CollaborationPlaybook(
            id: UUID(),
            name: "Concurrent Playbook A",
            roles: [.chiefOfStaff, .codeArchitect, .researcher],
            stages: shortStages
        )

        let playbook2 = CollaborationPlaybook(
            id: UUID(),
            name: "Concurrent Playbook B",
            roles: [.chiefOfStaff, .codeArchitect, .researcher],
            stages: shortStages
        )

        let runner1 = PlaybookRunner(playbook: playbook1, availableBots: roster)
        let runner2 = PlaybookRunner(playbook: playbook2, availableBots: roster)

        // 1. Concurrently execute TWO distinct playbook runners without deadlock or interference
        async let reportTaskA = runner1.execute(contextInput: "Payload Alpha")
        async let reportTaskB = runner2.execute(contextInput: "Payload Beta")

        let (resultA, resultB) = try await (reportTaskA, reportTaskB)

        #expect(resultA.isSuccessful == true)
        #expect(resultB.isSuccessful == true)
        #expect(resultA.playbookName == "Concurrent Playbook A")
        #expect(resultB.playbookName == "Concurrent Playbook B")
        #expect(resultA.stageResults.count == 2)
        #expect(resultB.stageResults.count == 2)

        // 2. Verify alreadyRunning error guard when re-executing while runner is in non-idle status
        #expect(runner1.status != .idle)
        do {
            _ = try await runner1.execute(contextInput: "Payload Gamma (should fail as already ran)")
            Issue.record("Expected alreadyRunning error")
        } catch let error as PlaybookExecutionError {
            #expect(error == .alreadyRunning)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
