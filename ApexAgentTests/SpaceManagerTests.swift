import XCTest
import SwiftData
@testable import ApexAgentCore

@MainActor
final class SpaceManagerTests: XCTestCase {

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            Conversation.self,
            Message.self,
            AgentMemory.self,
            AppPermissions.self,
            BotProfile.self,
            SpaceModel.self,
            SpaceParticipant.self,
            SpaceChannel.self,
            SpaceMessage.self,
            SpacePage.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    func testSpaceSeedingAndParticipantSync() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        botManager.modelContext = context
        botManager.loadBotsFromDisk()

        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context
        spaceManager.loadSpacesFromDisk()

        XCTAssertEqual(spaceManager.spaces.count, 1)
        let hq = try XCTUnwrap(spaceManager.activeSpace)
        XCTAssertEqual(hq.name, "Apex HQ")
        XCTAssertEqual(hq.sortedChannels.map(\.name), ["general", "architecture", "ship-room"])
        XCTAssertEqual(hq.humanParticipants.count, 1)
        XCTAssertEqual(hq.agentParticipants.count, botManager.allBots.count)
        XCTAssertEqual(hq.pages.count, 1)
    }

    func testMentionExtractionAndHumanToHumanSilence() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        botManager.modelContext = context
        botManager.loadBotsFromDisk()

        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context
        spaceManager.loadSpacesFromDisk()

        let space = try XCTUnwrap(spaceManager.activeSpace)
        let general = try XCTUnwrap(space.sortedChannels.first)

        // Add a second human user
        let alex = spaceManager.addHumanParticipant(
            to: space,
            displayName: "Alex Rivera",
            handle: "alex",
            roleTitle: "iOS Lead",
            role: .member,
            isRemote: true
        )
        XCTAssertEqual(alex.handle, "alex")
        XCTAssertEqual(space.humanParticipants.count, 2)

        // 1. Mentioning only a human (@alex) must return ZERO bots (human-to-human awareness)
        let targetsForHumanChat = spaceManager.resolveTargetBots(
            for: "Hey @alex can you check the new SwiftUI layout?",
            in: space,
            channel: general,
            senderKind: .human
        )
        XCTAssertTrue(targetsForHumanChat.isEmpty, "Bots must stay silent when a human tags only another human")

        // 2. Mentioning a specific bot (@code-architect) routes only to Code Architect
        let targetsForSingleBot = spaceManager.resolveTargetBots(
            for: "Hey @code-architect please review our actor isolation.",
            in: space,
            channel: general,
            senderKind: .human
        )
        XCTAssertEqual(targetsForSingleBot.map(\.name), ["Code Architect"])

        // 3. Mentioning @all routes to all bots in the Space
        let targetsForAll = spaceManager.resolveTargetBots(
            for: "@all share your status updates for the release.",
            in: space,
            channel: general,
            senderKind: .human
        )
        XCTAssertEqual(targetsForAll.count, botManager.allBots.count)
    }

    func testBotToBotChainedMentions() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        botManager.modelContext = context
        botManager.loadBotsFromDisk()

        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context
        spaceManager.loadSpacesFromDisk()

        let space = try XCTUnwrap(spaceManager.activeSpace)
        let general = try XCTUnwrap(space.sortedChannels.first)

        // Bot message tagging another bot (@CodeArchitect) should resolve target bots
        let targetsFromBot = spaceManager.resolveTargetBots(
            for: "I have prepared the spec. @CodeArchitect please review and implement.",
            in: space,
            channel: general,
            senderKind: .bot
        )
        XCTAssertEqual(targetsFromBot.map(\.name), ["Code Architect"])

        // Bot message tagging multiple bots (@Researcher and @Automator)
        let multipleTargetsFromBot = spaceManager.resolveTargetBots(
            for: "@Researcher please find documentation, and @Automator run the test suite.",
            in: space,
            channel: general,
            senderKind: .bot
        )
        XCTAssertTrue(multipleTargetsFromBot.contains(where: { $0.name == "Researcher" }))
        XCTAssertTrue(multipleTargetsFromBot.contains(where: { $0.name == "Automator" }))

        // Bot message with no @mentions returns empty (prevents infinite broadcast chatter)
        let unpromptedBotMessage = spaceManager.resolveTargetBots(
            for: "Here is my final report for the sprint.",
            in: space,
            channel: general,
            senderKind: .bot
        )
        XCTAssertTrue(unpromptedBotMessage.isEmpty)
    }

    func testRoleBasedOllamaModelTiers() throws {
        let apexBot = BotProfile(name: "Apex", title: "General Assistant", descriptionText: "Assistant")
        let archBot = BotProfile(name: "Code Architect", title: "Senior Engineer", descriptionText: "Swift code")
        let resBot = BotProfile(name: "Researcher", title: "Deep Research Specialist", descriptionText: "Research")
        let autoBot = BotProfile(name: "Automator", title: "macOS System Automator", descriptionText: "Automations")

        // 1. General fast response bot
        XCTAssertEqual(ModelRegistry.ollamaModel(for: apexBot), ModelRegistry.defaultFastOllamaModel)

        // 2. Code Architect routes to coding model
        XCTAssertEqual(ModelRegistry.ollamaModel(for: archBot), ModelRegistry.defaultCodingOllamaModel)

        // 3. Researcher routes to deep research model
        XCTAssertEqual(ModelRegistry.ollamaModel(for: resBot), ModelRegistry.defaultResearchOllamaModel)

        // 4. Automator routes to automation model
        XCTAssertEqual(ModelRegistry.ollamaModel(for: autoBot), ModelRegistry.defaultAutomationOllamaModel)

        // 5. Explicit user override takes priority
        apexBot.ollamaModelOverride = "custom-llama:latest"
        XCTAssertEqual(ModelRegistry.ollamaModel(for: apexBot), "custom-llama:latest")
    }

    func testRemoteHumanMessageAndSharedPagesAndSnapshotExport() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        botManager.modelContext = context
        botManager.loadBotsFromDisk()

        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context
        spaceManager.loadSpacesFromDisk()

        let space = try XCTUnwrap(spaceManager.activeSpace)
        let general = try XCTUnwrap(space.sortedChannels.first)

        // Post local human message without triggering LLM network call
        let rootMsg = try XCTUnwrap(
            spaceManager.postHumanMessage(
                "Starting sprint planning in #general",
                in: general,
                triggerAgents: false
            )
        )

        // Post thread reply
        let replyMsg = try XCTUnwrap(
            spaceManager.postHumanMessage(
                "Adding acceptance criteria to the thread",
                in: general,
                threadParentId: rootMsg.id,
                triggerAgents: false
            )
        )
        XCTAssertEqual(general.threadReplies(for: rootMsg.id).map(\.id), [replyMsg.id])

        // Simulate remote human message payload ( mentioning another human so no LLM turn starts)
        let ownerHandle = try XCTUnwrap(space.humanParticipants.first?.handle)
        let payload = SpaceMessagePostPayload(
            spaceId: space.id,
            channelId: general.id,
            senderName: "Sam Taylor",
            senderHandle: "sam",
            content: "Hey @\(ownerHandle) I just joined from my MacBook!"
        )
        let remoteMsg = try XCTUnwrap(spaceManager.receiveRemoteHumanMessage(payload))
        XCTAssertEqual(remoteMsg.senderHandle, "sam")
        XCTAssertTrue(space.humanParticipants.contains(where: { $0.handle == "sam" }))

        // Create and update a Shared SpacePage
        let page = spaceManager.createPage(
            in: space,
            title: "Architecture ADR-01",
            markdownBody: "## Decision\nUse SwiftData + Network.framework for Spaces.",
            authorName: "Sam Taylor"
        )
        spaceManager.updatePage(page, markdownBody: "## Decision\nApproved by team.", editorName: "Sam Taylor")
        XCTAssertEqual(page.markdownBody, "## Decision\nApproved by team.")

        // Verify JSON snapshot export for CollaborativeServer
        let snapshots = spaceManager.exportSpacesSnapshot()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].name, "Apex HQ")
        XCTAssertTrue(snapshots[0].participants.contains(where: { $0.handle == "sam" }))
        XCTAssertTrue(snapshots[0].pages.contains(where: { $0.title == "Architecture ADR-01" }))
    }
}
