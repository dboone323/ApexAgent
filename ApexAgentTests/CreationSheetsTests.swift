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
        let emptyNameSheet = CreateRoutineSheet(routineName: "")
        #expect(emptyNameSheet.webhookPathPreview == "http://localhost:8800/api/v1/webhook/:routineName")

        let spacedNameSheet = CreateRoutineSheet(routineName: "Deploy Release")
        #expect(spacedNameSheet.webhookPathPreview == "http://localhost:8800/api/v1/webhook/deploy-release")

        let underscoredSheet = CreateRoutineSheet(routineName: "audit_security")
        #expect(underscoredSheet.webhookPathPreview == "http://localhost:8800/api/v1/webhook/audit_security")
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

    @Test func testSkillFileWritingAndChmodExecution() throws {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let skillsDir = homeDir.appendingPathComponent(".apex/skills")
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
            "script_path": "~/.apex/skills/\(skillName).sh",
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
            scriptPath: "~/.apex/skills/\(uniqueSkillName).sh",
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
            .environment(orchestrator)
            .environment(routineManager)
            .environment(skillManager)

        ViewHost.host(view, size: NSSize(width: 600, height: 700), pump: 0.15)
    }
}
