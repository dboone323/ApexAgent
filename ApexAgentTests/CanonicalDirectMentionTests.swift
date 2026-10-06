import Testing
import Foundation
@testable import ApexAgentCore

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
            name: "Coordination Group",
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
