import Testing
import Foundation
@testable import ApexAgentCore

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
