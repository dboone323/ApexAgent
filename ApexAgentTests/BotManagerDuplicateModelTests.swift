import Testing
import Foundation
@testable import ApexAgentCore

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
