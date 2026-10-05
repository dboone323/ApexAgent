import XCTest
import SwiftData
@testable import ApexAgentCore

// MARK: - Space Orchestration Routing Matrix
//
// Exhaustive coverage of `SpaceManager.resolveTargetBots`: every
// `SpaceOrchestrationMode` crossed with every mention category. Previously only
// the "human tags human" path was tested, so the routing that decides *which
// agent owns a turn* was almost entirely uncovered.

@MainActor
final class SpaceRoutingMatrixTests: XCTestCase {

    private func makeRig() throws -> (SpaceManager, BotManager, ModelContext, SpaceModel, SpaceChannel) {
        let schema = Schema([
            Conversation.self, Message.self, AgentMemory.self, AppPermissions.self,
            BotProfile.self, SpaceModel.self, SpaceParticipant.self,
            SpaceChannel.self, SpaceMessage.self, SpacePage.self
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let orchestrator = AgentOrchestrator()
        let botManager = BotManager(orchestrator: orchestrator, computer: Computer())
        botManager.modelContext = context
        botManager.loadBotsFromDisk()

        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context
        spaceManager.loadSpacesFromDisk()

        let space = try XCTUnwrap(spaceManager.activeSpace)
        let channel = try XCTUnwrap(space.sortedChannels.first)
        return (spaceManager, botManager, context, space, channel)
    }

    private func targetNames(
        _ spaceManager: SpaceManager,
        _ text: String,
        _ space: SpaceModel,
        _ channel: SpaceChannel,
        sender: SpaceSenderKind
    ) -> [String] {
        spaceManager.resolveTargetBots(
            for: text, in: space, channel: channel, senderKind: sender
        ).map(\.name)
    }

    // MARK: - Explicit mentions route to exactly that bot

    func testExplicitMentionRoutesToSingleBot() throws {
        let (spaceManager, botManager, _, space, channel) = try makeRig()
        let bot = try XCTUnwrap(botManager.allBots.first)

        let targets = targetNames(
            spaceManager, "@\(SpaceParticipant.normalizeHandle(bot.name)) hello",
            space, channel, sender: .human
        )
        XCTAssertEqual(targets, [bot.name], "Explicit @mention must route to exactly one bot")
    }

    func testEveryBotIsReachableByItsOwnHandle() throws {
        let (spaceManager, botManager, _, space, channel) = try makeRig()
        for bot in botManager.allBots {
            let targets = targetNames(
                spaceManager, "@\(SpaceParticipant.normalizeHandle(bot.name)) ping",
                space, channel, sender: .human
            )
            XCTAssertEqual(
                targets, [bot.name],
                "Bot '\(bot.name)' must be reachable via its normalized handle"
            )
        }
    }

    // MARK: - Human vs bot sender

    func testHumanTaggingHumanSilencesBots() throws {
        let (spaceManager, _, _, space, channel) = try makeRig()
        let humanHandle = try XCTUnwrap(space.humanParticipants.first).handle

        XCTAssertTrue(
            targetNames(spaceManager, "@\(humanHandle) can you review this?",
                        space, channel, sender: .human).isEmpty,
            "Bots must stay silent for human-to-human messages"
        )
    }

    func testBotSenderWithoutMentionsIsIgnored() throws {
        let (spaceManager, botManager, _, space, channel) = try makeRig()
        _ = botManager

        XCTAssertTrue(
            targetNames(spaceManager, "here is my status update",
                        space, channel, sender: .bot).isEmpty,
            "A bot speaking without @mentions must not trigger other bots"
        )
    }

    func testBotSenderMentioningPeerTriggersThatPeer() throws {
        let (spaceManager, botManager, _, space, channel) = try makeRig()
        let bots = botManager.allBots
        let speaker = try XCTUnwrap(bots.first)
        let peer = try XCTUnwrap(bots.dropFirst().first)

        let targets = targetNames(
            spaceManager, "@\(SpaceParticipant.normalizeHandle(peer.name)) thoughts?",
            space, channel, sender: .bot
        )
        XCTAssertEqual(targets, [peer.name], "Bot-to-bot mention must reach the peer")
        XCTAssertFalse(targets.contains(speaker.name), "A bot must not trigger itself")
    }

    func testBotSenderBroadcastHitsEverySpaceAgent() throws {
        let (spaceManager, _, _, space, channel) = try makeRig()
        let expected = space.agentParticipants.count

        for token in SpaceManager.broadcastHandles {
            let targets = targetNames(
                spaceManager, "@\(token) status check", space, channel, sender: .bot
            )
            XCTAssertEqual(targets.count, expected, "Broadcast @\(token) must reach all agents")
        }
    }

    // MARK: - Every orchestration mode, no mention present

    func testMentionDrivenSoloHumanNoQuestionRoutesToLead() throws {
        let (spaceManager, _, _, space, channel) = try makeRig()
        space.orchestrationMode = .mentionDriven

        XCTAssertEqual(
            targetNames(spaceManager, "ship the release", space, channel, sender: .human).count,
            1,
            "Solo human with no mention routes to a single lead bot"
        )
    }

    func testMentionDrivenMultiHumanStatementStaysSilent() throws {
        let (spaceManager, _, _, space, channel) = try makeRig()
        space.orchestrationMode = .mentionDriven
        _ = spaceManager.addHumanParticipant(
            to: space, displayName: "Second Human", isRemote: false
        )
        XCTAssertGreaterThan(space.humanParticipants.count, 1)

        XCTAssertTrue(
            targetNames(spaceManager, "shipping the release today",
                        space, channel, sender: .human).isEmpty,
            "Multi-human non-question with no mention must not interrupt"
        )
    }

    func testMentionDrivenMultiHumanQuestionGetsLead() throws {
        let (spaceManager, _, _, space, channel) = try makeRig()
        space.orchestrationMode = .mentionDriven
        _ = spaceManager.addHumanParticipant(
            to: space, displayName: "Second Human", isRemote: false
        )

        XCTAssertEqual(
            targetNames(spaceManager, "what is our deploy status?",
                        space, channel, sender: .human).count,
            1,
            "Multi-human direct question must still reach a lead bot"
        )
    }

    func testChiefOfStaffModeratedAlwaysRoutesToChief() throws {
        let (spaceManager, botManager, _, space, channel) = try makeRig()
        space.orchestrationMode = .chiefOfStaffModerated
        let chief = botManager.allBots.first { $0.isChiefOfStaff } ?? botManager.allBots[0]

        XCTAssertEqual(
            targetNames(spaceManager, "unaddressed chatter",
                        space, channel, sender: .human),
            [chief.name],
            "Moderated mode must always route to the chief"
        )
    }

    func testRoundRobinBroadcastsToAllAgents() throws {
        let (spaceManager, _, _, space, channel) = try makeRig()
        space.orchestrationMode = .roundRobin
        XCTAssertEqual(
            targetNames(spaceManager, "unaddressed", space, channel, sender: .human).count,
            space.agentParticipants.count,
            "Round-robin mode must fan out to every agent"
        )
    }

    func testParallelSwarmBroadcastsToAllAgents() throws {
        let (spaceManager, _, _, space, channel) = try makeRig()
        space.orchestrationMode = .parallelSwarm
        XCTAssertEqual(
            targetNames(spaceManager, "unaddressed", space, channel, sender: .human).count,
            space.agentParticipants.count,
            "Parallel swarm mode must fan out to every agent"
        )
    }

    // MARK: - Explicit mention beats the orchestration mode

    func testExplicitMentionOverridesEachOrchestrationMode() throws {
        let (spaceManager, botManager, _, space, channel) = try makeRig()
        let target = try XCTUnwrap(botManager.allBots.first)
        let handle = SpaceParticipant.normalizeHandle(target.name)

        for mode in SpaceOrchestrationMode.allCases {
            space.orchestrationMode = mode
            XCTAssertEqual(
                targetNames(spaceManager, "@\(handle) just for you",
                             space, channel, sender: .human),
                [target.name],
                "Explicit @mention must win in .\(mode.rawValue) mode"
            )
        }
    }

    // MARK: - Handle normalization

    func testEveryBroadcastHandleIsRecognized() {
        XCTAssertEqual(
            SpaceManager.broadcastHandles,
            ["all", "agents", "bots", "channel", "everyone", "team"]
        )
    }

    func testNormalizeHandleProducesSlug() {
        XCTAssertEqual(SpaceParticipant.normalizeHandle("Code Architect"), "code-architect")
        XCTAssertEqual(SpaceParticipant.normalizeHandle("@Apex"), "apex")
        XCTAssertEqual(SpaceParticipant.normalizeHandle("!!!"), "member")
    }

    func testExtractMentionsHandlesEdgeCases() {
        XCTAssertEqual(SpaceManager.extractMentions(from: "@Codex fix it"), ["codex"])
        XCTAssertEqual(
            SpaceManager.extractMentions(from: "@Codex and @codex are the same"),
            ["codex"],
            "Duplicate mentions must be collapsed"
        )
        XCTAssertEqual(SpaceManager.extractMentions(from: "email me@example.com"), [],
                       "An email address must not parse as a mention")
        XCTAssertEqual(SpaceManager.extractMentions(from: "no mentions here"), [])
    }
}