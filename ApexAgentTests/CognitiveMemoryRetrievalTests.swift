import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("CognitiveMemoryRetrievalTests")
struct CognitiveMemoryRetrievalTests {

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
