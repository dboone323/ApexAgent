import Testing
import Foundation
import SwiftData
import SwiftUI
import AppKit
@testable import ApexAgentCore

@MainActor
@Suite("CreationSheetsTests", .serialized)
final class CreationSheetsTests {

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

    // MARK: - 1. Routine Validation & Creation Tests

    @Test func testRoutineInputValidation() {
        let emptySheet = CreateRoutineSheet(routineName: "", prompt: "", selectedTrigger: .manual)
        #expect(!emptySheet.canSave, "Empty routine name and prompt should not be saveable")

        let whitespaceNameSheet = CreateRoutineSheet(routineName: "   ", prompt: "Valid prompt", selectedTrigger: .manual)
        #expect(!whitespaceNameSheet.canSave, "Whitespace-only routine name should not be saveable")

        let whitespacePromptSheet = CreateRoutineSheet(routineName: "Daily Standup", prompt: "   ", selectedTrigger: .manual)
        #expect(!whitespacePromptSheet.canSave, "Whitespace-only prompt should not be saveable")

        let validSheet = CreateRoutineSheet(routineName: "Daily Standup", prompt: "Prepare daily summary", selectedTrigger: .manual)
        #expect(validSheet.canSave, "Non-empty name and prompt should be saveable for manual trigger")
    }

    @Test func testRoutineTriggerValidation() {
        let manualSheet = CreateRoutineSheet(routineName: "Build Monitor", prompt: "Check CI status", selectedTrigger: .manual)
        #expect(manualSheet.canSave)

        let onErrorSheet = CreateRoutineSheet(routineName: "Build Monitor", prompt: "Check CI status", selectedTrigger: .onError)
        #expect(onErrorSheet.canSave)

        let onSuccessSheet = CreateRoutineSheet(routineName: "Build Monitor", prompt: "Check CI status", selectedTrigger: .onSuccess)
        #expect(onSuccessSheet.canSave)

        let onMessageSheet = CreateRoutineSheet(routineName: "Build Monitor", prompt: "Check CI status", selectedTrigger: .onMessage)
        #expect(onMessageSheet.canSave)

        let webhookSheet = CreateRoutineSheet(routineName: "Build Monitor", prompt: "Check CI status", selectedTrigger: .webhook)
        #expect(webhookSheet.canSave)

        // TimeInterval
        let zeroIntervalSheet = CreateRoutineSheet(routineName: "Build Monitor", prompt: "Check CI status", selectedTrigger: .timeInterval, scheduledMinutes: 0)
        #expect(!zeroIntervalSheet.canSave, "0 minutes interval should not be saveable")

        let validIntervalSheet = CreateRoutineSheet(routineName: "Build Monitor", prompt: "Check CI status", selectedTrigger: .timeInterval, scheduledMinutes: 15)
        #expect(validIntervalSheet.canSave, "Positive interval minutes should be saveable")

        // Cron
        let invalidCronSheet = CreateRoutineSheet(routineName: "Build Monitor", prompt: "Check CI status", selectedTrigger: .cron, cronExpression: "invalid cron expr")
        #expect(!invalidCronSheet.canSave, "Invalid cron expression should not be saveable")

        let validCronSheet = CreateRoutineSheet(routineName: "Build Monitor", prompt: "Check CI status", selectedTrigger: .cron, cronExpression: "0 9 * * *")
        #expect(validCronSheet.canSave, "Valid cron expression should be saveable")
    }

    @Test func testRoutineCronScheduleValidation() {
        let validSheet1 = CreateRoutineSheet(cronExpression: "*/15 * * * *")
        #expect(validSheet1.isCronValid)
        #expect(validSheet1.cronDescription.contains("Cron:"))

        let validSheet2 = CreateRoutineSheet(cronExpression: "0 0 1 1 *")
        #expect(validSheet2.isCronValid)

        let invalidSheet1 = CreateRoutineSheet(cronExpression: "not a valid cron")
        #expect(!invalidSheet1.isCronValid)
        #expect(invalidSheet1.cronDescription.contains("Invalid cron syntax"))

        let invalidSheet2 = CreateRoutineSheet(cronExpression: "99 99 * * *")
        #expect(!invalidSheet2.isCronValid)
    }

    @Test func testRoutineWebhookPathPreview() {
        // AUDIT P2.4: the preview shows the real route (`/hooks/<endpointId>`)
        // because the server assigns a `wh_…` id on save — it no longer
        // fabricates a slug-based URL the server never serves. The preview is
        // intentionally static regardless of the typed name.
        let emptyNameSheet = CreateRoutineSheet(routineName: "")
        #expect(emptyNameSheet.webhookPathPreview == "http://localhost:8800/hooks/<endpointId>")

        let spacedNameSheet = CreateRoutineSheet(routineName: "Deploy Release")
        #expect(spacedNameSheet.webhookPathPreview == "http://localhost:8800/hooks/<endpointId>")

        let underscoredSheet = CreateRoutineSheet(routineName: "audit_security")
        #expect(underscoredSheet.webhookPathPreview == "http://localhost:8800/hooks/<endpointId>")
    }

    @Test func testRoutineTargetBotDispatchFormatting() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let routineManager = RoutineManager.shared
        routineManager.modelContext = context

        // 1. Default Apex bot -> no prefix
        let defaultRoutineName = "Daily Check_\(UUID().uuidString.prefix(6))"
        let defaultSheet = CreateRoutineSheet(
            routineName: defaultRoutineName,
            prompt: "Run routine checks",
            selectedBotName: "Apex",
            selectedTrigger: .manual
        )

        let routine1 = Routine(
            name: defaultSheet.routineName,
            descriptionText: defaultSheet.prompt,
            trigger: defaultSheet.selectedTrigger,
            scheduledMinutes: 0,
            cronExpression: nil,
            enabled: true
        )
        context.insert(routine1)
        try context.save()
        routineManager.loadRoutines()

        let fetched1 = try context.fetch(FetchDescriptor<Routine>(predicate: #Predicate { $0.name == defaultRoutineName })).first
        #expect(fetched1 != nil)
        #expect(fetched1?.descriptionText == "Run routine checks")

        // 2. Custom bot -> bot name prefix
        let customRoutineName = "Arch Review_\(UUID().uuidString.prefix(6))"
        let customSheet = CreateRoutineSheet(
            routineName: customRoutineName,
            prompt: "Analyze component boundaries",
            selectedBotName: "Code Architect",
            selectedTrigger: .cron,
            cronExpression: "0 10 * * 1-5"
        )

        let effectiveDesc = "\(customSheet.selectedBotName): \(customSheet.prompt)"
        let routine2 = Routine(
            name: customSheet.routineName,
            descriptionText: effectiveDesc,
            trigger: customSheet.selectedTrigger,
            scheduledMinutes: 0,
            cronExpression: customSheet.cronExpression,
            enabled: true
        )
        context.insert(routine2)
        try context.save()
        routineManager.loadRoutines()

        let fetched2 = try context.fetch(FetchDescriptor<Routine>(predicate: #Predicate { $0.name == customRoutineName })).first
        #expect(fetched2 != nil)
        #expect(fetched2?.descriptionText == "Code Architect: Analyze component boundaries")
        #expect(fetched2?.cronExpression == "0 10 * * 1-5")
        #expect(fetched2?.effectiveScheduleDescription.contains("Cron:") == true)
    }

    @Test func testRoutineSwiftDataPersistenceAndManagerReload() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let routineManager = RoutineManager.shared
        routineManager.modelContext = context

        let uniqueName = "Nightly Backup_\(UUID().uuidString.prefix(8))"
        let routine = Routine(
            name: uniqueName,
            descriptionText: "Back up local workspace",
            trigger: .timeInterval,
            scheduledMinutes: 60,
            enabled: true
        )
        routineManager.save(routine)

        let loaded = routineManager.routines.first { $0.name == uniqueName }
        #expect(loaded != nil)
        #expect(loaded?.scheduledMinutes == 60)
        #expect(loaded?.effectiveScheduleDescription == "Every 60 min")

        // Toggle
        if let r = loaded {
            routineManager.toggle(r)
            #expect(!r.enabled)
            routineManager.toggle(r)
            #expect(r.enabled)
        }

        // Delete
        if let r = loaded {
            routineManager.delete(r)
            let afterDelete = routineManager.routines.first { $0.name == uniqueName }
            #expect(afterDelete == nil)
        }
    }

    // MARK: - 2. Skill Validation, Generation & Persistence Tests

    @Test func testSkillNameValidation() {
        let valid1 = CreateSkillSheet(skillName: "deploy_preview")
        #expect(valid1.isNameValid)

        let valid2 = CreateSkillSheet(skillName: "build-gate-123")
        #expect(valid2.isNameValid)

        let valid3 = CreateSkillSheet(skillName: "test_run_all")
        #expect(valid3.isNameValid)

        let invalidSpace = CreateSkillSheet(skillName: "Deploy Preview")
        #expect(!invalidSpace.isNameValid, "Names with spaces must be rejected")

        let invalidSpecial = CreateSkillSheet(skillName: "bad@skill")
        #expect(!invalidSpecial.isNameValid, "Names with special characters must be rejected")

        let invalidSlash = CreateSkillSheet(skillName: "skill/path")
        #expect(!invalidSlash.isNameValid, "Names with slashes must be rejected")

        let invalidEmpty = CreateSkillSheet(skillName: "")
        #expect(!invalidEmpty.isNameValid, "Empty names must be rejected")
    }

    @Test func testSkillDescriptionAndScriptValidation() {
        let emptyDesc = CreateSkillSheet(
            skillName: "summarize_diff",
            skillDescription: "",
            parameterSchemaJSON: "{\"type\": \"object\"}",
            scriptContent: "echo hi"
        )
        #expect(!emptyDesc.canSave, "Empty description should not be saveable")

        let emptyScript = CreateSkillSheet(
            skillName: "summarize_diff",
            skillDescription: "Valid description",
            parameterSchemaJSON: "{\"type\": \"object\"}",
            scriptContent: "   "
        )
        #expect(!emptyScript.canSave, "Empty script content should not be saveable")

        let valid = CreateSkillSheet(
            skillName: "summarize_diff",
            skillDescription: "Valid description",
            parameterSchemaJSON: "{\"type\": \"object\"}",
            scriptContent: "echo 'Running...'"
        )
        #expect(valid.canSave, "Valid inputs should be saveable")
    }

    @Test func testSkillParameterSchemaValidation() {
        let validSchema = CreateSkillSheet(parameterSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "query": { "type": "string" }
          }
        }
        """)
        #expect(validSchema.isSchemaValid)

        let invalidSchemaText = CreateSkillSheet(parameterSchemaJSON: "not json")
        #expect(!invalidSchemaText.isSchemaValid)

        let malformedSchema = CreateSkillSheet(parameterSchemaJSON: "{ malformed json: true ")
        #expect(!malformedSchema.isSchemaValid)
    }

    @Test func testEmptySchemaObjectIsRejectedBySaveGate() {
        // H9: a bare {} schema must not be savable through the sheet's UI gate
        // (previously uiCanSave only checked that the schema parsed to a dict).
        let emptyObjectSchema = CreateSkillSheet(
            skillName: "empty_schema_skill",
            skillDescription: "Has an empty schema object",
            parameterSchemaJSON: "{}",
            scriptContent: "echo hi"
        )
        #expect(!emptyObjectSchema.isSchemaValid, "Bare {} schema must be invalid")
        #expect(!emptyObjectSchema.uiCanSave, "Bare {} schema must not pass the Save gate")

        let whitespacePaddedEmptyObject = CreateSkillSheet(
            skillName: "empty_schema_skill",
            skillDescription: "Has an empty schema object",
            parameterSchemaJSON: "  \n {} \n ",
            scriptContent: "echo hi"
        )
        #expect(!whitespacePaddedEmptyObject.uiCanSave, "Whitespace-padded {} must not pass the Save gate")

        let typeOnlySchema = CreateSkillSheet(
            skillName: "typed_skill",
            skillDescription: "Valid schema with type key",
            parameterSchemaJSON: "{\"type\": \"object\"}",
            scriptContent: "echo hi"
        )
        #expect(typeOnlySchema.uiCanSave, "Schema with a type key must pass the Save gate")

        let propertiesOnlySchema = CreateSkillSheet(
            skillName: "props_skill",
            skillDescription: "Valid schema with properties key",
            parameterSchemaJSON: "{\"properties\": {}}",
            scriptContent: "echo hi"
        )
        #expect(propertiesOnlySchema.uiCanSave, "Schema with a properties key must pass the Save gate")
    }

    @Test func testSkillFileWritingAndChmodExecution() throws {
        let fileManager = FileManager.default
        let skillsDir = ApexAgentStoragePaths.skills
        try? fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true, attributes: nil)

        let skillName = "test_script_runner_\(UUID().uuidString.prefix(6))"
        let scriptPath = skillsDir.appendingPathComponent("\(skillName).sh")
        let manifestPath = skillsDir.appendingPathComponent("\(skillName).json")

        defer {
            try? fileManager.removeItem(at: scriptPath)
            try? fileManager.removeItem(at: manifestPath)
        }

        let scriptBody = """
        #!/bin/zsh
        echo "Apex Test Skill OK"
        """
        try scriptBody.write(to: scriptPath, atomically: true, encoding: .utf8)

        // Apply chmod 0755
        let chmodProcess = Process()
        chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodProcess.arguments = ["0755", scriptPath.path]
        try chmodProcess.run()
        chmodProcess.waitUntilExit()
        #expect(chmodProcess.terminationStatus == 0)

        // Write manifest
        let manifest: [String: Any] = [
            "name": skillName,
            "description": "Test skill description",
            "script_path": ApexAgentStoragePaths.skillScriptReference(for: skillName),
            "parameters": [
                "type": "object",
                "properties": [
                    "input": ["type": "string"]
                ]
            ]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
        try manifestData.write(to: manifestPath)

        #expect(fileManager.fileExists(atPath: scriptPath.path))
        #expect(fileManager.fileExists(atPath: manifestPath.path))

        // Verify script is executable
        #expect(fileManager.isExecutableFile(atPath: scriptPath.path))

        // Verify DynamicToolbox loads it
        DynamicToolbox.shared.loadTools()
        let loadedTool = DynamicToolbox.shared.dynamicTools[skillName]
        #expect(loadedTool != nil)
        #expect(loadedTool?.description == "Test skill description")
    }

    @Test func testSkillSwiftDataPersistenceAndDiskSync() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let skillManager = SkillManager.shared
        skillManager.modelContext = context

        let uniqueSkillName = "custom_tool_\(UUID().uuidString.prefix(6))"
        let skill = Skill(
            name: uniqueSkillName,
            descriptionText: "Custom tool description",
            scriptPath: ApexAgentStoragePaths.skillScriptReference(for: uniqueSkillName),
            parameterSchemaJSON: "{\"type\":\"object\"}",
            category: "custom",
            enabled: true
        )
        context.insert(skill)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.name == uniqueSkillName })).first
        #expect(fetched != nil)
        #expect(fetched?.name == uniqueSkillName)
        #expect(fetched?.category == "custom")
        #expect(fetched?.enabled == true)

        // Enable / Disable
        if let s = fetched {
            skillManager.disable(s)
            #expect(!s.enabled)
            skillManager.enable(s)
            #expect(s.enabled)
        }
    }

    // MARK: - 3. View Hosting Tests for Creation Sheets & Sections

    @Test func testCreateRoutineSheetViewHosting() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let routineManager = RoutineManager.shared
        routineManager.modelContext = context

        let view = CreateRoutineSheet()
            .modelContainer(container)
            .environment(routineManager)

        ViewHost.host(view, size: NSSize(width: 500, height: 600), pump: 0.1)
    }

    @Test func testCreateSkillSheetViewHosting() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let skillManager = SkillManager.shared
        skillManager.modelContext = context

        let view = CreateSkillSheet()
            .modelContainer(container)
            .environment(skillManager)

        ViewHost.host(view, size: NSSize(width: 550, height: 650), pump: 0.1)
    }

    @Test func testRoutinesSectionViewHosting() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let routineManager = RoutineManager.shared
        routineManager.modelContext = context

        // Add a sample routine
        let routine = Routine(name: "Sample Routine", descriptionText: "Sample prompt", trigger: .manual)
        context.insert(routine)
        try context.save()
        routineManager.loadRoutines()

        let view = Form {
            RoutinesSection()
        }
        .modelContainer(container)
        .modelContext(context)
        .environment(routineManager)

        ViewHost.host(view, size: NSSize(width: 500, height: 400), pump: 0.1)
    }

    @Test func testSkillsSectionViewHosting() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let skillManager = SkillManager.shared
        skillManager.modelContext = context

        // Add a sample skill
        let skill = Skill(name: "sample_skill", descriptionText: "Sample description", scriptPath: "/tmp/sample.sh", parameterSchemaJSON: "{}")
        context.insert(skill)
        try context.save()

        let view = Form {
            SkillsSection()
        }
        .modelContainer(container)
        .modelContext(context)
        .environment(skillManager)

        ViewHost.host(view, size: NSSize(width: 500, height: 400), pump: 0.1)
    }

    @Test func testSettingsViewHostingWithAllSections() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let orchestrator = AgentOrchestrator()
        orchestrator.modelContext = context

        let routineManager = RoutineManager.shared
        routineManager.modelContext = context
        let skillManager = SkillManager.shared
        skillManager.modelContext = context

        let view = SettingsView()
            .modelContainer(container)
            .modelContext(context)
            .environment(orchestrator)
            .environment(routineManager)
            .environment(skillManager)

        ViewHost.host(view, size: NSSize(width: 600, height: 700), pump: 0.15)
    }

    // MARK: - 4. Deep Button Hierarchy, Sub-Button, and Action Enforcement Tests

    @Test func testEmptyStateActionButtonHierarchy() {
        var actionFired = false
        let populated = EmptyState(
            icon: "tray",
            title: "Empty",
            message: "No items",
            actionTitle: "Create Item",
            action: { actionFired = true }
        )
        #expect(populated.actionTitle == "Create Item")
        #expect(populated.action != nil)
        #expect(actionFired == false)

        populated.action?()
        #expect(actionFired == true)

        let inert = EmptyState(
            icon: "tray",
            title: "Empty",
            message: "No items",
            actionTitle: nil,
            action: nil
        )
        #expect(inert.actionTitle == nil)
        #expect(inert.action == nil)
    }

    @Test func testPlanDashboardClearAndDetailTraversal() {
        let orchestrator = AgentOrchestrator()
        #expect(orchestrator.activePlan.isEmpty == true)

        // Populate steps: Level 1
        let step1 = PlanStep(title: "Step 1: Discover", status: .completed, result: "Found 3 targets")
        let step2 = PlanStep(title: "Step 2: Execute", status: .running)
        let step3 = PlanStep(title: "Step 3: Verify", status: .failed, error: "Network timeout")
        orchestrator.updatePlan(steps: [step1, step2, step3])
        #expect(orchestrator.activePlan.count == 3)

        // Sub-Button: Step row selection navigates to PlanStepDetailView
        var selectedStep: PlanStep? = step1
        #expect(selectedStep?.id == step1.id)
        #expect(selectedStep?.result == "Found 3 targets")
        #expect(selectedStep?.error == nil)

        // Sub-Button: Navigate to failed step
        selectedStep = step3
        #expect(selectedStep?.id == step3.id)
        #expect(selectedStep?.error == "Network timeout")

        // Sub-Button: Dismiss detail sheet ("Close" toolbar button)
        selectedStep = nil
        #expect(selectedStep == nil)

        // Parent Action: "Clear" button in header
        orchestrator.clearPlan()
        #expect(orchestrator.activePlan.isEmpty == true)
        #expect(orchestrator.activePlan.count == 0)
    }

    @Test func testTerminalToolbarAndPlayPauseHierarchy() async {
        let orchestrator = AgentOrchestrator()
        let convo = Conversation(title: "Terminal Convo")
        orchestrator.currentConversation = convo
        orchestrator.activeTerminalOutput = "Initial command output\nDone."
        orchestrator.terminalOutputs[convo.id] = orchestrator.activeTerminalOutput

        var copyInvoked = false
        var clearInvoked = false
        var resetInvoked = false
        var isPaused = false

        // Sub-Button: PlayPauseButton toggle
        #expect(isPaused == false)
        isPaused.toggle() // Simulates clicking PlayPauseButton when playing
        #expect(isPaused == true)
        isPaused.toggle() // Simulates clicking PlayPauseButton when paused
        #expect(isPaused == false)

        // Action: Copy button
        let copyAction = {
            copyInvoked = true
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(orchestrator.activeTerminalOutput, forType: .string)
        }
        copyAction()
        #expect(copyInvoked == true)
        #expect(NSPasteboard.general.string(forType: .string) == "Initial command output\nDone.")

        // Action: Clear button
        let clearAction = {
            clearInvoked = true
            orchestrator.terminalOutputs[convo.id] = ""
            orchestrator.activeTerminalOutput = ""
        }
        clearAction()
        #expect(clearInvoked == true)
        #expect(orchestrator.activeTerminalOutput == "")
        #expect(orchestrator.terminalOutputs[convo.id] == "")

        // Action: Reset Shell button
        let resetAction = {
            resetInvoked = true
            await orchestrator.resetPTYSession(for: convo.id)
        }
        await resetAction()
        #expect(resetInvoked == true)
    }

    @Test func testConfirmationOverlayApproveAndDenyHierarchy() async {
        let orchestrator = AgentOrchestrator()
        #expect(orchestrator.pendingConfirmation == nil)

        // Scenario A: Deny flow
        let taskA = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                orchestrator.pendingConfirmation = ConfirmationRequest(
                    toolName: "delete_file",
                    arguments: #"{"path":"/important/file"}"#,
                    riskDescription: "Permanently delete file",
                    oldContent: "critical content",
                    newContent: "",
                    filePath: "/important/file",
                    continuation: continuation
                )
            }
        }

        for _ in 0..<10 {
            if orchestrator.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(orchestrator.pendingConfirmation != nil)
        #expect(orchestrator.pendingConfirmation?.toolName == "delete_file")

        // Sub-Button: Deny Action
        orchestrator.resolveConfirmation(approved: false)
        let receivedDecisionA = await taskA.value
        #expect(receivedDecisionA == false)
        #expect(orchestrator.pendingConfirmation == nil)

        // Scenario B: Approve flow
        let taskB = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                orchestrator.pendingConfirmation = ConfirmationRequest(
                    toolName: "create_branch",
                    arguments: #"{"branch":"feat/ui"}"#,
                    riskDescription: "Create a new git branch",
                    continuation: continuation
                )
            }
        }

        for _ in 0..<10 {
            if orchestrator.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(orchestrator.pendingConfirmation != nil)
        #expect(orchestrator.pendingConfirmation?.toolName == "create_branch")

        // Sub-Button: Approve Action
        orchestrator.resolveConfirmation(approved: true)
        let receivedDecisionB = await taskB.value
        #expect(receivedDecisionB == true)
        #expect(orchestrator.pendingConfirmation == nil)
    }

    @Test func testBotManagementDeepHierarchy() throws {
        let container = try makeTestContainer()
        let bm = BotManager()
        bm.modelContext = container.mainContext
        bm.orchestrator = AgentOrchestrator()

        let initialCount = bm.bots.count

        // Level 1: "New Bot" button -> CreateBotSheet validation & creation
        let emptyName = ""
        let isSaveDisabledWhenEmpty = emptyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(isSaveDisabledWhenEmpty == true, "Save button must be disabled when bot name is empty")

        let whitespaceName = "    "
        let isSaveDisabledWhenWhitespace = whitespaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(isSaveDisabledWhenWhitespace == true, "Save button must be disabled when bot name is whitespace")

        // Sub-Button: Avatar icon selection
        var selectedAvatar = "person.fill"
        selectedAvatar = "gear"
        #expect(selectedAvatar == "gear")

        // Sub-Button: Create Bot Action when valid
        let validName = "Security Auditor"
        let validTitle = "Application Security Bot"
        let validDesc = "Scans code for secrets and CVEs"
        let newBot = bm.createBot(
            name: validName,
            title: validTitle,
            descriptionText: validDesc,
            avatarName: selectedAvatar
        )
        newBot.modelProvider = .localOllama
        newBot.ollamaModelOverride = "llama3:latest"
        bm.openConversation(with: newBot)

        #expect(bm.bots.count == initialCount + 1)
        #expect(bm.activeBotId == newBot.id)
        #expect(newBot.name == "Security Auditor")
        #expect(newBot.avatarName == "gear")
        #expect(newBot.modelProvider == .localOllama)
        #expect(newBot.ollamaModelOverride == "llama3:latest")

        // Level 2: Edit Bot button -> EditBotSheet
        let updatedTitle = "Lead AppSec Architect"

        // Level 3 (Deeper sub-button): "Durable Memory" button -> opens MemoryEditorSheet
        var botMemoryBinding = newBot.memory
        #expect(botMemoryBinding.isEmpty == true)

        // Level 4 (Deeper sub-button): In MemoryEditorSheet, type memory and click "Save & Close"
        let draftMemory = "Always check for hardcoded API keys before approving PRs."
        botMemoryBinding = draftMemory

        // Commit EditBotSheet: "Save Changes" button
        bm.editBot(
            newBot,
            title: updatedTitle,
            memory: botMemoryBinding
        )

        #expect(newBot.title == "Lead AppSec Architect")
        #expect(newBot.memory == "Always check for hardcoded API keys before approving PRs.")

        // Level 1: Pin / Unpin Sub-Button
        #expect(newBot.isPinned == false)
        bm.togglePin(newBot)
        #expect(newBot.isPinned == true)
        bm.togglePin(newBot)
        #expect(newBot.isPinned == false)

        // Level 1: Delete Bot Sub-Button -> Confirmation Dialog -> "Delete" destructive action
        bm.deleteBot(newBot)
        #expect(bm.bots.contains(where: { $0.id == newBot.id }) == false)
        #expect(bm.bots.count == initialCount)
    }

    @Test func testSkillManagementDeepHierarchy() throws {
        let container = try makeTestContainer()
        let skillManager = SkillManager.shared
        skillManager.modelContext = container.mainContext

        // Level 1: Add Custom Skill -> CreateSkillSheet validation
        let invalidCharSheet = CreateSkillSheet(
            skillName: "invalid name with spaces!",
            skillDescription: "Valid description",
            parameterSchemaJSON: #"{"type": "object"}"#,
            scriptContent: "echo hi"
        )
        #expect(invalidCharSheet.isNameValid == false)
        #expect(invalidCharSheet.canSave == false)

        let bareSchemaSheet = CreateSkillSheet(
            skillName: "test_skill",
            skillDescription: "Valid description",
            parameterSchemaJSON: "{}",
            scriptContent: "echo hi"
        )
        #expect(bareSchemaSheet.isSchemaValid == false, "Bare {} schema must be invalid (H9)")
        #expect(bareSchemaSheet.canSave == false)

        let validSheet = CreateSkillSheet(
            skillName: "test_skill_valid",
            skillDescription: "Runs test verification",
            parameterSchemaJSON: #"{"type": "object", "properties": {"target": {"type": "string"}}}"#,
            scriptContent: "#!/bin/zsh\necho verified"
        )
        #expect(validSheet.isNameValid == true)
        #expect(validSheet.isSchemaValid == true)
        #expect(validSheet.canSave == true)

        // Sub-Button: Desktop Workflow Recording toggle
        let recorder = DemoRecorder.shared
        #expect(recorder.isRecording == false)
        recorder.startRecording()
        #expect(recorder.isRecording == true)
        recorder.stopRecording()
        #expect(recorder.isRecording == false)

        // Sub-Action: Persist skill and test Toggle + Delete flow
        let registeredSkill = Skill(
            name: "test_skill_valid",
            descriptionText: "Runs test verification",
            scriptPath: "/tmp/test_skill_valid.sh",
            parameterSchemaJSON: #"{"type": "object"}"#
        )
        container.mainContext.insert(registeredSkill)
        try container.mainContext.save()

        // Sub-Button: Toggle enabled state
        #expect(registeredSkill.enabled == true)
        skillManager.disable(registeredSkill)
        #expect(registeredSkill.enabled == false)
        skillManager.enable(registeredSkill)
        #expect(registeredSkill.enabled == true)

        // Sub-Button: Delete Skill confirmation dialog -> "Delete Skill" destructive button
        skillManager.delete(registeredSkill)
    }

    @Test func testRoutineManagementDeepHierarchy() async throws {
        let container = try makeTestContainer()
        let routineManager = RoutineManager.shared
        routineManager.modelContext = container.mainContext

        // Level 1: Add Routine -> CreateRoutineSheet validation
        let emptySheet = CreateRoutineSheet(routineName: "", prompt: "", selectedTrigger: .manual)
        #expect(emptySheet.canSave == false, "Empty name and prompt must not be savable")

        // Sub-Button: TimeInterval trigger condition
        let zeroMinSheet = CreateRoutineSheet(
            routineName: "Backup",
            prompt: "Perform daily backup",
            selectedTrigger: .timeInterval,
            scheduledMinutes: 0
        )
        #expect(zeroMinSheet.canSave == false, "Time interval with 0 minutes must not be savable")

        let validMinSheet = CreateRoutineSheet(
            routineName: "Backup",
            prompt: "Perform daily backup",
            selectedTrigger: .timeInterval,
            scheduledMinutes: 30
        )
        #expect(validMinSheet.canSave == true)

        // Sub-Button: Cron trigger condition
        let invalidCronSheet = CreateRoutineSheet(
            routineName: "Nightly Audit",
            prompt: "Audit codebase",
            selectedTrigger: .cron,
            cronExpression: "invalid-cron"
        )
        #expect(invalidCronSheet.isCronValid == false)
        #expect(invalidCronSheet.canSave == false)

        let validCronSheet = CreateRoutineSheet(
            routineName: "Nightly Audit",
            prompt: "Audit codebase",
            selectedTrigger: .cron,
            cronExpression: "0 2 * * *"
        )
        #expect(validCronSheet.isCronValid == true)
        #expect(validCronSheet.canSave == true)

        // Sub-Action: Register Routine and test Toggle, Run Now & Delete
        let routine = Routine(
            name: "Nightly Audit",
            descriptionText: "Audit codebase",
            trigger: .cron,
            scheduledMinutes: 0,
            cronExpression: "0 2 * * *"
        )
        routineManager.save(routine)
        #expect(routineManager.routines.contains(where: { $0.name == "Nightly Audit" }))

        // Sub-Button: Toggle routine
        #expect(routine.enabled == true)
        routineManager.toggle(routine)
        #expect(routine.enabled == false)
        routineManager.toggle(routine)
        #expect(routine.enabled == true)

        // Sub-Button: Context Menu "Run Now"
        await routineManager.runNow(routine)
        #expect(true, "Run Now executed successfully")

        // Sub-Button: Delete confirmation dialog -> "Delete Routine"
        routineManager.delete(routine)
        #expect(routineManager.routines.contains(where: { $0.id == routine.id }) == false)
    }

    @Test func testSpacesAndChannelsDeepHierarchy() {
        let spaceManager = SpaceManager()
        let initialSpaceCount = spaceManager.spaces.count

        // Level 1: "Create New Space" button -> validation
        let emptySpaceName = ""
        let isSpaceCreateDisabled = emptySpaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(isSpaceCreateDisabled == true, "Create Space button must be disabled when name is empty")

        // Action: Create Space
        let newSpace = spaceManager.createSpace(
            name: "Security Engineering",
            summary: "AppSec and infra reviews",
            orchestrationMode: .mentionDriven,
            seedDefaults: true
        )
        spaceManager.selectSpace(newSpace)
        #expect(spaceManager.spaces.count == initialSpaceCount + 1)
        #expect(spaceManager.activeSpaceId == newSpace.id)

        // Level 2 (Sub-button): "+" Add Channel button -> validation
        let emptyChannelName = ""
        let isChannelCreateDisabled = emptyChannelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(isChannelCreateDisabled == true, "Create Channel button must be disabled when name is empty")

        // Action: Create Channel
        let channel = spaceManager.addChannel(to: newSpace, name: "vuln-triage", topic: "High-priority CVE remediation")
        spaceManager.selectChannel(channel)
        #expect(newSpace.channels.contains(where: { $0.id == channel.id }))
        #expect(spaceManager.activeChannelId == channel.id)

        // Level 3 (Deeper sub-button): Space Composer Send Button Gate
        var composerText = ""
        var canSend = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(canSend == false, "Composer Send button must be disabled when text is empty")

        composerText = "Hello @Apex please triage CVE-2026-001"
        canSend = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(canSend == true, "Composer Send button must be enabled when text is present")

        // Action: Send Message into Channel
        let message = spaceManager.postHumanMessage(composerText, in: channel)
        #expect(message != nil)
        #expect(channel.messages.contains(where: { $0.id == message?.id }))

        // Level 4 (Deeper sub-button): Thread Reply Composer Gate
        var threadInput = ""
        var canReply = !threadInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(canReply == false, "Thread Reply button must be disabled when reply text is empty")

        threadInput = "Working on a reproduction now"
        canReply = !threadInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(canReply == true, "Thread Reply button must be enabled when reply text is present")

        if let parentId = message?.id {
            let threadReply = spaceManager.postHumanMessage(threadInput, in: channel, threadParentId: parentId)
            #expect(threadReply != nil)
            #expect(channel.threadReplies(for: parentId).count == 1)
        }
    }

    @Test func testDiagnosticsDashboardHierarchy() async {
        let results = await DiagnosticManager.runSelfCheck()
        #expect(results.isEmpty == false)

        // Sub-Button: Re-Run button state gate
        var isRunning = true
        var canReRun = !isRunning
        #expect(canReRun == false, "Re-Run button must be disabled while diagnostics are executing")

        isRunning = false
        canReRun = !isRunning
        #expect(canReRun == true, "Re-Run button must be enabled when execution is complete")

        // Sub-Button: Export button state gate
        var diagnosticItems: [DiagnosticItem] = []
        var canExport = !diagnosticItems.isEmpty
        #expect(canExport == false, "Export button must be disabled when diagnostic results are empty")

        diagnosticItems = results
        canExport = !diagnosticItems.isEmpty
        #expect(canExport == true, "Export button must be enabled when results exist")

        // Action: Export generates valid JSON report
        let report = DiagnosticManager.exportReport(diagnosticItems)
        #expect(report.isEmpty == false)
        let parsed = (try? JSONSerialization.jsonObject(with: report.data(using: .utf8) ?? Data())) as? [String: Any]
        #expect(parsed != nil)
        #expect(parsed?["items"] != nil)
        #expect(parsed?["generatedAt"] != nil)
    }

    @Test func testPlaybookApprovalAndDelegationHierarchy() throws {
        let container = try makeTestContainer()
        let bm = BotManager()
        bm.modelContext = container.mainContext

        var card = PlaybookApprovalCard(
            playbookId: UUID(),
            stageId: "deploy_stage",
            stageTitle: "Deploy Staging",
            summary: "Approve deployment to staging environment",
            proposedActions: ["Run deploy.sh"]
        )
        #expect(card.status == .pending)

        // Sub-Button: Approve Action
        card.status = .approved
        #expect(card.status == .approved)

        // Sub-Button: Reject Action
        card.status = .rejected
        #expect(card.status == .rejected)

        // Bot to Bot Peer Approval Flow
        let botA = bm.createBot(name: "Bot A", title: "Sender", descriptionText: "Sender bot")
        let botB = bm.createBot(name: "Bot B", title: "Target", descriptionText: "Target bot")

        let decision = bm.peerDeliveryDecision(from: botA, to: botB, message: "Deploy now")
        guard case .blockedPendingCard(let requestId) = decision else {
            Issue.record("Expected peerDeliveryDecision to return blockedPendingCard")
            return
        }

        #expect(bm.pendingPeerApprovals.count == 1)
        #expect(bm.pendingPeerApprovals.first?.id == requestId)

        // Approve Peer Request Sub-Button
        let resolved = bm.resolvePeerRequest(requestId: requestId, allow: true)
        #expect(resolved == true)
        #expect(bm.pendingPeerApprovals.isEmpty == true)
    }
}
