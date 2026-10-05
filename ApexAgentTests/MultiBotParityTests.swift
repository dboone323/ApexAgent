import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Multi-Bot Parity Tests
//
// Tests for the P0+P1 multi-bot parity features:
//   1. Per-bot model provider assignment (P0-1)
//   2. Group chat engine routing (P0-2)
//   3. Team playbook import/export (P1-2)
//   4. ModelRegistry per-bot resolution
//
// These tests exercise real code paths with real data. No mocks.

// MARK: - P0-1: Per-Bot Model Provider

@Suite("PerBotModelProviderTests")
struct PerBotModelProviderTests {

    @Test func botProfileDefaultsToNilProvider() {
        let bot = BotProfile(name: "TestBot")
        #expect(bot.modelProviderRaw == nil)
        #expect(bot.modelProvider == nil)
        #expect(bot.ollamaModelOverride == nil)
    }

    @Test func botProfileModelProviderRoundTrip() {
        let bot = BotProfile(name: "OllamaBot")
        bot.modelProvider = .localOllama
        #expect(bot.modelProviderRaw == "localOllama")
        #expect(bot.modelProvider == .localOllama)

        bot.modelProvider = .cloudGemini
        #expect(bot.modelProviderRaw == "cloudGemini")
        #expect(bot.modelProvider == .cloudGemini)

        bot.modelProvider = nil
        #expect(bot.modelProviderRaw == nil)
        #expect(bot.modelProvider == nil)
    }

    @Test func botProfileOllamaModelOverride() {
        let bot = BotProfile(name: "Coder")
        bot.modelProvider = .localOllama
        bot.ollamaModelOverride = "deepseek-r1:14b"
        #expect(bot.ollamaModelOverride == "deepseek-r1:14b")
    }

    @Test func modelRegistryEffectiveProviderUsesBotsOwnProvider() {
        let bot = BotProfile(name: "SpecialistBot")
        bot.modelProvider = .cloudGemini
        let effective = ModelRegistry.effectiveProvider(for: bot)
        #expect(effective == .cloudGemini)
    }

    @Test func modelRegistryEffectiveProviderFallsBackToGlobal() {
        let bot = BotProfile(name: "DefaultBot")
        // bot.modelProvider is nil → should use global
        let effective = ModelRegistry.effectiveProvider(for: bot)
        #expect(effective == ModelRegistry.activeProvider())
    }

    @Test func modelRegistryModelForBotReturnsCorrectType() {
        let bot = BotProfile(name: "OllamaBot")
        bot.modelProvider = .localOllama
        let model = ModelRegistry.model(for: bot)
        #expect(model is LocalOllamaLanguageModel)
    }

    @Test func modelRegistryModelForBotFallsBackToDefault() {
        let bot = BotProfile(name: "PlainBot")
        // modelProvider is nil → uses global activeProvider
        let model = ModelRegistry.model(for: bot)
        // Just verify it returns a model without crashing
        _ = model.capabilities
    }

    @Test func allModelProviderCasesHaveDisplayNames() {
        for provider in ModelProvider.allCases {
            #expect(!provider.displayName.isEmpty)
        }
    }
}

// MARK: - P0-1: BotManager Duplicate Copies Model Fields

@MainActor
@Suite("BotManagerDuplicateModelTests")
struct BotManagerDuplicateModelTests {

    private func makeManager() -> (BotManager, AgentOrchestrator) {
        let orchestrator = AgentOrchestrator()
        let manager = BotManager(orchestrator: orchestrator, computer: Computer())
        return (manager, orchestrator)
    }

    @Test func duplicateBotCopiesModelProvider() {
        let (manager, _) = makeManager()
        let original = manager.createBot(
            name: "Coder",
            title: "Developer",
            descriptionText: "Writes code"
        )
        original.modelProvider = .localOllama
        original.ollamaModelOverride = "qwen2.5-coder:32b"

        let copy = manager.duplicateBot(original)
        #expect(copy.modelProviderRaw == "localOllama")
        #expect(copy.modelProvider == .localOllama)
        #expect(copy.ollamaModelOverride == "qwen2.5-coder:32b")
        #expect(copy.name == "Coder copy")
    }

    @Test func duplicateBotPreservesNilModelProvider() {
        let (manager, _) = makeManager()
        let original = manager.createBot(
            name: "Default",
            title: "General",
            descriptionText: "General bot"
        )
        // Leave modelProvider as nil (global default)
        let copy = manager.duplicateBot(original)
        #expect(copy.modelProviderRaw == nil)
        #expect(copy.modelProvider == nil)
        #expect(copy.ollamaModelOverride == nil)
    }

    @Test func duplicateBotCopiesToolAndMCPAllowlists() {
        let (manager, _) = makeManager()
        let original = manager.createBot(
            name: "SecuritySpecialist",
            title: "Auditor",
            descriptionText: "Audits security posture"
        )
        original.allowedToolNames = ["read_file", "search_memory", "system_info"]
        original.allowedMCPServers = ["Docs MCP", "GitHub Enterprise"]

        let copy = manager.duplicateBot(original)
        #expect(copy.name == "SecuritySpecialist copy")
        #expect(copy.allowedToolNames == ["read_file", "search_memory", "system_info"])
        #expect(copy.allowedMCPServers == ["Docs MCP", "GitHub Enterprise"])
    }
}

// MARK: - P0-2: Group Chat Engine Routing

@MainActor
@Suite("GroupChatEngineRoutingTests")
struct GroupChatEngineRoutingTests {

    @Test func groupChatSessionCreatesWithParticipants() {
        let bot1 = BotProfile(name: "Alice", title: "Researcher")
        let bot2 = BotProfile(name: "Bob", title: "Developer")
        let group = GroupChatSession(name: "Research Team", participants: [bot1, bot2])
        #expect(group.participants.count == 2)
        #expect(group.generationOrder.count == 2)
        #expect(group.name == "Research Team")
    }

    @Test func groupToolPermissionAllowsWhitelistedTools() {
        let group = GroupChatSession(
            name: "Test",
            participants: [BotProfile(name: "A"), BotProfile(name: "B")]
        )
        #expect(group.groupToolPermission(tool: "web_search") == .allowed)
        #expect(group.groupToolPermission(tool: "read_file") == .allowed)
        #expect(group.groupToolPermission(tool: "list_directory") == .allowed)
    }

    @Test func groupToolPermissionDeniesUnlistedTools() {
        let group = GroupChatSession(
            name: "Test",
            participants: [BotProfile(name: "A"), BotProfile(name: "B")]
        )
        let permission = group.groupToolPermission(tool: "run_shell_command")
        #expect(permission != .allowed)
    }

    @Test func groupToolPermissionDeniesWhenDisabled() {
        let group = GroupChatSession(
            name: "Test",
            participants: [BotProfile(name: "A"), BotProfile(name: "B")]
        )
        group.toolCallsEnabled = false
        if case .denied(let reason) = group.groupToolPermission(tool: "web_search") {
            #expect(reason.contains("disabled"))
        } else {
            Issue.record("Expected denied when tools disabled")
        }
    }
}

// MARK: - P1-2: Team Playbook

@Suite("TeamPlaybookTests")
struct TeamPlaybookTests {

    @Test func jsonRoundTrip() throws {
        let playbook = TeamPlaybook(
            name: "Dev Team",
            description: "A development team",
            bots: [
                PlaybookBot(
                    name: "Coder",
                    title: "Developer",
                    description: "Writes Swift code",
                    avatarName: "hammer.fill",
                    isChiefOfStaff: false,
                    modelProvider: "localOllama",
                    ollamaModel: "qwen2.5-coder:32b"
                ),
                PlaybookBot(
                    name: "Lead",
                    title: "Chief of Staff",
                    description: "Coordinates the team",
                    avatarName: "person.3.fill",
                    isChiefOfStaff: true
                )
            ]
        )

        let data = try playbook.encode()
        let decoded = try TeamPlaybook.decode(from: data)

        #expect(decoded.name == "Dev Team")
        #expect(decoded.description == "A development team")
        #expect(decoded.version == "1.0")
        #expect(decoded.bots.count == 2)
        #expect(decoded.bots[0].name == "Coder")
        #expect(decoded.bots[0].modelProvider == "localOllama")
        #expect(decoded.bots[0].ollamaModel == "qwen2.5-coder:32b")
        #expect(decoded.bots[1].name == "Lead")
        #expect(decoded.bots[1].isChiefOfStaff == true)
        #expect(decoded.bots[1].modelProvider == nil)
    }

    @Test func markdownRoundTrip() throws {
        let playbook = TeamPlaybook(
            name: "Support Team",
            description: "Customer support bots",
            bots: [
                PlaybookBot(
                    name: "Triage",
                    title: "Support Triage",
                    description: "Routes tickets",
                    avatarName: "tray.full.fill",
                    isChiefOfStaff: false,
                    modelProvider: "appleOnDevice"
                ),
                PlaybookBot(
                    name: "Escalation",
                    title: "Escalation Manager",
                    description: "Handles escalated issues",
                    avatarName: "exclamationmark.triangle.fill",
                    isChiefOfStaff: true,
                    memory: "Always CC the VP on P0s"
                )
            ]
        )

        let markdown = playbook.toMarkdown()
        let decoded = try TeamPlaybook.decodeFromMarkdown(markdown)

        #expect(decoded.name == "Support Team")
        #expect(decoded.description == "Customer support bots")
        #expect(decoded.bots.count == 2)
        #expect(decoded.bots[0].name == "Triage")
        #expect(decoded.bots[0].modelProvider == "appleOnDevice")
        #expect(decoded.bots[1].name == "Escalation")
        #expect(decoded.bots[1].isChiefOfStaff == true)
        #expect(decoded.bots[1].memory?.contains("Always CC the VP") == true)
    }

    @Test func markdownFormatContainsFrontmatter() {
        let playbook = TeamPlaybook(
            name: "Test",
            description: "A test playbook",
            bots: [
                PlaybookBot(name: "Bot", title: "Helper", description: "Helps",
                            avatarName: "person.fill", isChiefOfStaff: false)
            ]
        )
        let md = playbook.toMarkdown()
        #expect(md.hasPrefix("---\n"))
        #expect(md.contains("name: \"Test\""))
        #expect(md.contains("## Bot: Bot"))
    }

    @Test func decodeFromMarkdownRejectsInvalidFormat() {
        let invalid = "No frontmatter here\nJust plain text"
        #expect(throws: TeamPlaybook.PlaybookError.self) {
            try TeamPlaybook.decodeFromMarkdown(invalid)
        }
    }

    @Test func emptyPlaybookEncodesAndDecodes() throws {
        let playbook = TeamPlaybook(name: "Empty", description: "No bots", bots: [])
        let data = try playbook.encode()
        let decoded = try TeamPlaybook.decode(from: data)
        #expect(decoded.bots.isEmpty)
        #expect(decoded.name == "Empty")
    }
}

// MARK: - P1-2: BotManager Playbook Import/Export

@MainActor
@Suite("BotManagerPlaybookTests")
struct BotManagerPlaybookTests {

    private func makeManager() -> (BotManager, AgentOrchestrator) {
        let orchestrator = AgentOrchestrator()
        let manager = BotManager(orchestrator: orchestrator, computer: Computer())
        return (manager, orchestrator)
    }

    @Test func exportPlaybookContainsAllBots() {
        let (manager, _) = makeManager()
        let bot1 = manager.createBot(name: "Alpha", title: "Lead", descriptionText: "Leads")
        bot1.isChiefOfStaff = true
        bot1.modelProvider = .localOllama
        bot1.ollamaModelOverride = "qwen2.5-coder:32b"

        _ = manager.createBot(name: "Beta", title: "Worker", descriptionText: "Works")

        let playbook = manager.exportPlaybook(name: "My Team", description: "Test export")
        #expect(playbook.name == "My Team")
        #expect(playbook.bots.count == 2)

        let alphaPB = playbook.bots.first { $0.name == "Alpha" }
        #expect(alphaPB?.isChiefOfStaff == true)
        #expect(alphaPB?.modelProvider == "localOllama")
        #expect(alphaPB?.ollamaModel == "qwen2.5-coder:32b")
    }

    @Test func importPlaybookCreatesBots() {
        let (manager, _) = makeManager()
        let playbook = TeamPlaybook(
            name: "Imported Team",
            description: "From playbook",
            bots: [
                PlaybookBot(name: "Imported1", title: "Role1", description: "Desc1",
                            avatarName: "star.fill", isChiefOfStaff: false,
                            modelProvider: "cloudGemini"),
                PlaybookBot(name: "Imported2", title: "Role2", description: "Desc2",
                            avatarName: "bolt.fill", isChiefOfStaff: true,
                            memory: "Remember to summarize")
            ]
        )

        let created = manager.importPlaybook(playbook)
        #expect(created.count == 2)
        #expect(manager.botByName("Imported1") != nil)
        #expect(manager.botByName("Imported2") != nil)

        let bot1 = manager.botByName("Imported1")!
        #expect(bot1.modelProviderRaw == "cloudGemini")
        #expect(bot1.modelProvider == .cloudGemini)

        let bot2 = manager.botByName("Imported2")!
        #expect(bot2.isChiefOfStaff == true)
        #expect(bot2.memory.contains("Remember to summarize"))
    }

    @Test func importPlaybookSkipsDuplicateNames() {
        let (manager, _) = makeManager()
        _ = manager.createBot(name: "Existing", title: "Already here", descriptionText: "Pre-existing")

        let playbook = TeamPlaybook(
            name: "Team",
            description: "Test",
            bots: [
                PlaybookBot(name: "Existing", title: "Duplicate", description: "Should skip",
                            avatarName: "xmark", isChiefOfStaff: false),
                PlaybookBot(name: "NewBot", title: "Fresh", description: "Should import",
                            avatarName: "plus", isChiefOfStaff: false)
            ]
        )

        let created = manager.importPlaybook(playbook)
        #expect(created.count == 1)
        #expect(created[0].name == "NewBot")
    }

    @Test func exportImportRoundTrip() throws {
        let (manager1, _) = makeManager()
        let bot = manager1.createBot(name: "RoundTrip", title: "Tester", descriptionText: "Tests round trips")
        bot.modelProvider = .fmCLI
        bot.isChiefOfStaff = true

        let playbook = manager1.exportPlaybook()
        let data = try playbook.encode()
        let decoded = try TeamPlaybook.decode(from: data)

        let (manager2, _) = makeManager()
        let imported = manager2.importPlaybook(decoded)
        #expect(imported.count >= 1)

        let roundTripped = manager2.botByName("RoundTrip")
        #expect(roundTripped != nil)
        #expect(roundTripped?.modelProviderRaw == "fmCLI")
        #expect(roundTripped?.isChiefOfStaff == true)
        #expect(roundTripped?.title == "Tester")
    }
}

// MARK: - Workstream 3: Bot Capability Controls Tests

@Suite("BotCapabilityControlTests")
struct BotCapabilityControlTests {

    @Test func presetsContainExpectedTools() {
        // Read-only preset should include safe retrieval and inspection tools
        #expect(BotCapabilityPresets.readOnlyTools.contains("read_file"))
        #expect(BotCapabilityPresets.readOnlyTools.contains("list_directory"))
        #expect(BotCapabilityPresets.readOnlyTools.contains("file_search"))
        #expect(BotCapabilityPresets.readOnlyTools.contains("web_search"))
        #expect(BotCapabilityPresets.readOnlyTools.contains("fetch_web_content"))
        #expect(BotCapabilityPresets.readOnlyTools.contains("search_memory"))
        #expect(!BotCapabilityPresets.readOnlyTools.contains("run_shell_command"))
        #expect(!BotCapabilityPresets.readOnlyTools.contains("write_file"))

        // Developer preset should include mutating filesystem, git, and shell tools
        #expect(BotCapabilityPresets.developerTools.contains("read_file"))
        #expect(BotCapabilityPresets.developerTools.contains("write_file"))
        #expect(BotCapabilityPresets.developerTools.contains("patch_file"))
        #expect(BotCapabilityPresets.developerTools.contains("git_operation"))
        #expect(BotCapabilityPresets.developerTools.contains("run_shell_command"))
    }

    @Test func categoryToolCoverage() {
        let categories = BotCapabilityPresets.categories
        #expect(categories.count >= 5)

        let categoryIDs = Set(categories.map { $0.id })
        #expect(categoryIDs.contains("fs_code"))
        #expect(categoryIDs.contains("system_shell"))
        #expect(categoryIDs.contains("web_search"))
        #expect(categoryIDs.contains("memory_plan"))
        #expect(categoryIDs.contains("collaboration"))

        let allTools = categories.flatMap { $0.toolNames }
        #expect(allTools.contains("read_file"))
        #expect(allTools.contains("run_shell_command"))
        #expect(allTools.contains("web_search"))
        #expect(allTools.contains("search_memory"))
        #expect(allTools.contains("ask_bot"))
    }

    @MainActor
    @Test func botCapabilityAllowlistConfiguration() {
        let bot = BotProfile(name: "AuditBot", title: "Security")
        #expect(bot.allowedToolNames.isEmpty) // Unrestricted by default
        #expect(bot.allowedMCPServers.isEmpty)

        bot.allowedToolNames = Array(BotCapabilityPresets.readOnlyTools)
        bot.allowedMCPServers = ["SecurityServer"]

        #expect(bot.allowedToolNames.contains("read_file"))
        #expect(!bot.allowedToolNames.contains("run_shell_command"))
        #expect(bot.allowedMCPServers == ["SecurityServer"])
    }
}

// MARK: - Workstream 4: Durable Automation Receipts Tests

@MainActor
@Suite("DurableAutomationReceiptTests")
struct DurableAutomationReceiptTests {

    @Test func routineStableUUIDDeterministic() {
        let routine1 = Routine(name: "Nightly Audit", descriptionText: "audit codebase")
        let routine2 = Routine(name: "Nightly Audit", descriptionText: "different prompt")
        let routine3 = Routine(name: "Morning Brief", descriptionText: "morning summary")

        #expect(routine1.stableUUID == routine2.stableUUID)
        #expect(routine1.stableUUID != routine3.stableUUID)
    }

    @Test func routineRunDurationFormatting() {
        let now = Date()
        var run = RoutineRun(
            routineId: UUID(),
            routineName: "Test Run",
            prompt: "do work",
            status: .running,
            startedAt: now
        )
        #expect(run.formattedDuration == "Running...")

        // Subsecond duration
        run.finishedAt = now.addingTimeInterval(0.35)
        #expect(run.formattedDuration == "350 ms")

        // Multi-second duration
        run.finishedAt = now.addingTimeInterval(12.4)
        #expect(run.formattedDuration == "12.4 s")

        // Multi-minute duration
        run.finishedAt = now.addingTimeInterval(135.0)
        #expect(run.formattedDuration == "2m 15s")
    }

    @Test func routineManagerRecordsAndFiltersReceipts() {
        let manager = RoutineManager.shared
        manager.clearRuns()
        #expect(manager.recentRuns.isEmpty)

        let routineId1 = UUID()
        let routineId2 = UUID()

        let run1 = RoutineRun(
            routineId: routineId1,
            routineName: "Build Check",
            prompt: "check build",
            status: .completed,
            startedAt: Date().addingTimeInterval(-10),
            finishedAt: Date(),
            output: "Build clean: 0 warnings"
        )
        let run2 = RoutineRun(
            routineId: routineId2,
            routineName: "Lint Code",
            prompt: "lint code",
            status: .failed,
            startedAt: Date().addingTimeInterval(-5),
            finishedAt: Date(),
            output: nil,
            error: "2 lint violations found"
        )

        manager.recordRun(run1)
        manager.recordRun(run2)

        #expect(manager.recentRuns.count == 2)
        #expect(manager.runReceipts(for: routineId1).count == 1)
        #expect(manager.runReceipts(for: routineId1).first?.routineName == "Build Check")
        #expect(manager.runReceipts(for: routineId2).count == 1)
        #expect(manager.runReceipts(for: routineId2).first?.error == "2 lint violations found")

        // Updating an existing run replaces in place
        var updatedRun2 = run2
        updatedRun2.status = .completed
        updatedRun2.output = "Violations fixed"
        updatedRun2.error = nil
        manager.recordRun(updatedRun2)

        #expect(manager.recentRuns.count == 2)
        #expect(manager.runReceipts(for: routineId2).first?.status == .completed)
        #expect(manager.runReceipts(for: routineId2).first?.output == "Violations fixed")

        // Cleanup
        manager.clearRuns()
        #expect(manager.recentRuns.isEmpty)
    }
}
// MARK: - Workstream 5: Integrated Per-Bot Cognitive Memory Tests

@MainActor
@Suite("CognitiveMemoryParityTests")
struct CognitiveMemoryParityTests {

    @Test func testPerBotSemanticFactScoping() {
        let engine = CognitiveMemoryEngine.shared
        let botAId = UUID()
        let botBId = UUID()

        engine.storeBotFact(
            botId: botAId,
            subject: "Architecture",
            predicate: "uses",
            object: "SwiftData and SwiftUI",
            confidence: 0.95,
            source: "unit_test"
        )
        engine.storeBotFact(
            botId: botBId,
            subject: "Deployment",
            predicate: "targets",
            object: "macOS 27",
            confidence: 0.90,
            source: "unit_test"
        )

        let botAFacts = engine.searchFacts(keyword: "Architecture", botId: botAId)
        #expect(botAFacts.contains(where: { $0.subject == "Architecture" && $0.object == "SwiftData and SwiftUI" }))

        let botBFactsForArchitecture = engine.searchFacts(keyword: "Architecture", botId: botBId)
        #expect(botBFactsForArchitecture.isEmpty)

        let botBFacts = engine.searchFacts(keyword: "Deployment", botId: botBId)
        #expect(botBFacts.contains(where: { $0.subject == "Deployment" && $0.object == "macOS 27" }))
    }

    @Test func testBotSessionSystemInstructionsInjectsCognitiveMemory() {
        let engine = CognitiveMemoryEngine.shared
        let orchestrator = AgentOrchestrator()
        let bot = BotProfile(
            name: "MemoryTester",
            title: "Memory Testing Specialist",
            descriptionText: "Tests memory injection",
            avatarName: "brain.head.profile",
            memory: "Local baseline notes"
        )

        engine.storeBotFact(
            botId: bot.id,
            subject: "SecurityPolicy",
            predicate: "mandates",
            object: "Strict sandboxing",
            confidence: 1.0,
            source: "test"
        )

        let session = BotSession(bot: bot, orchestrator: orchestrator)
        let instructions = session.systemInstructions

        #expect(instructions.contains("MemoryTester"))
        #expect(instructions.contains("Local baseline notes"))
        #expect(instructions.contains("--- Remembered Knowledge Graph ---"))
        #expect(instructions.contains("SecurityPolicy mandates Strict sandboxing"))
    }
}

// MARK: - Workstream 6: Canonical Direct Mentions Tests

@MainActor
@Suite("CanonicalDirectMentionTests")
struct CanonicalDirectMentionTests {

    @Test func testGroupChatUserMessageWithMentionAddsParticipantAndPrioritizesTurn() {
        let orchestrator = AgentOrchestrator()
        let bm = BotManager(orchestrator: orchestrator, computer: Computer())
        let hostBot = bm.createBot(name: "HostBot", title: "Host", descriptionText: "Host bot")
        let taggedBot = bm.createBot(name: "Piper", title: "Reviewer", descriptionText: "Code reviewer")
        let thirdBot = bm.createBot(name: "Archie", title: "Architect", descriptionText: "Architect bot")

        let session = GroupChatSession(
            name: "Parity Group",
            participants: [hostBot, thirdBot],
            hostBot: hostBot
        )
        session.botManager = bm

        #expect(session.participants.count == 2)
        #expect(!session.participants.contains(where: { $0.id == taggedBot.id }))

        // User posts a message mentioning @Piper
        session.sendUserMessage("Hey @Piper, please review the latest patch!")

        // Tagged bot is dynamically added to participants
        #expect(session.participants.contains(where: { $0.id == taggedBot.id }))
        #expect(session.participants.count == 3)

        // System message announced the join
        #expect(session.messages.contains(where: { $0.content.contains("Piper was tagged by user and joined") }))

        // Tagged bot is placed in generation queue
        #expect(session.generationOrder.contains(taggedBot.id))
    }

    @Test func testDirectAddressedParticipantPrioritizesTargetBot() {
        let botA = BotProfile(name: "Alpha", title: "Alpha", descriptionText: "Alpha bot", avatarName: "a")
        let botB = BotProfile(name: "Beta", title: "Beta", descriptionText: "Beta bot", avatarName: "b")

        let session = GroupChatSession(
            name: "Direct Mention Test",
            participants: [botA, botB],
            hostBot: botA
        )

        session.sendUserMessageToParticipant("Please handle the database migration", addressedTo: botB)

        #expect(session.messages.last?.content == "[Beta] Please handle the database migration")
        #expect(session.generationOrder.first == botB.id)
    }
}

// MARK: - Workstream 7: End-to-End Execution Verification Tests

@MainActor
@Suite("EndToEndExecutionVerificationTests")
struct EndToEndExecutionVerificationTests {

    @Test func testVerifyExecutionFileExistsAndContains() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("verify_test_\(UUID().uuidString).txt")
        let testContent = "APEX_AGENT_VERIFICATION_PAYLOAD_12345"

        try testContent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let orchestrator = AgentOrchestrator()
        let tool = VerifyExecutionTool(orchestrator: orchestrator)

        // 1. file_exists check
        let existsResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "file_exists",
            targetPath: testFile.path,
            expectedPattern: nil,
            command: nil
        ))
        #expect(existsResult.hasPrefix("VERIFIED: File exists on disk"))

        // 2. file_contains check
        let containsResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "file_contains",
            targetPath: testFile.path,
            expectedPattern: "VERIFICATION_PAYLOAD_12345",
            command: nil
        ))
        #expect(containsResult.hasPrefix("VERIFIED: File"))

        // 3. file_not_contains check
        let notContainsResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "file_not_contains",
            targetPath: testFile.path,
            expectedPattern: "FORBIDDEN_STRING_99999",
            command: nil
        ))
        #expect(notContainsResult.hasPrefix("VERIFIED: File"))

        // 4. file_contains failure on missing pattern
        let failResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "file_contains",
            targetPath: testFile.path,
            expectedPattern: "NON_EXISTENT_PATTERN",
            command: nil
        ))
        #expect(failResult.hasPrefix("VERIFICATION_FAILED:"))
    }

    @Test func testVerifyExecutionCommandSucceeds() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = VerifyExecutionTool(orchestrator: orchestrator)

        let successResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "command_succeeds",
            targetPath: nil,
            expectedPattern: "verified_output",
            command: "echo 'verified_output'"
        ))
        #expect(successResult.hasPrefix("VERIFIED: Command succeeded"))

        let failResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "command_succeeds",
            targetPath: nil,
            expectedPattern: nil,
            command: "exit 1"
        ))
        #expect(failResult.hasPrefix("VERIFICATION_FAILED:"))
    }

    @Test func testFileWriteToolVerifiedPostCondition() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("write_verify_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: testFile) }

        let orchestrator = AgentOrchestrator()
        let writeTool = FileWriteTool(orchestrator: orchestrator)

        let result = try await writeTool.call(arguments: FileWriteTool.Arguments(
            path: testFile.path,
            content: "Verified disk write test content",
            append: false
        ))

        #expect(result.contains("✅ Written"))
        #expect(result.contains("[Verified:"))
        #expect(FileManager.default.fileExists(atPath: testFile.path))
    }
}

