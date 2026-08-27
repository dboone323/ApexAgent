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
