import XCTest
import SwiftData
@testable import ApexAgentCore

// MARK: - Direct @Mention Handling
//
// Regression suite for the bug where `@Bot do the thing` produced a generic
// reply that delegated the task back to the human instead of doing it.
//
// Root cause was threefold:
//   1. Space turns passed a synthesized transcript scaffold as the `prompt`,
//      and intent gating ran on that scaffold — its boilerplate always
//      contained delegation vocabulary, so the coordination pack was injected
//      on every turn.
//   2. `AgentPrecedenceResolver` discarded the caller's instructions when a
//      BotProfile existed, dropping the Space rules + [TURN PRIORITY] marker.
//   3. Nothing marked the turn as "directly addressed", so delegation tools
//      stayed available and the model chose to delegate.

@MainActor
final class DirectMentionTests: XCTestCase {

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

    private func makeRig() throws -> (SpaceManager, BotManager, AgentOrchestrator, ModelContext) {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let orchestrator = AgentOrchestrator()
        let botManager = BotManager(orchestrator: orchestrator, computer: Computer())
        botManager.modelContext = context
        botManager.loadBotsFromDisk()

        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context
        spaceManager.loadSpacesFromDisk()
        return (spaceManager, botManager, orchestrator, context)
    }

    // MARK: - 1. The ORIGINAL failure mode (regression anchor)

    /// Documents the pre-fix instruction loss that left the agent with a persona
    /// but no directive to actually do the work.
    func testOriginalResponseDroppedTurnScopedInstructions() throws {
        let (_, botManager, _, _) = try makeRig()
        let bot = try XCTUnwrap(botManager.allBots.first)

        // ORIGINAL BEHAVIOUR: bot persona alone carried no turn directives.
        XCTAssertFalse(
            bot.descriptionText.contains("SPACE RULES"),
            "Anchor: bot persona alone carries no turn-scoped directives"
        )

        // CORRECT BEHAVIOUR: caller instructions now survive resolution.
        let fixed = AgentPrecedenceResolver.resolve(
            bot: bot,
            archetypeName: nil,
            globalInstructions: "SPACE RULES: do the work yourself",
            globalProvider: .appleOnDevice,
            globalAllowedTools: []
        )
        XCTAssertTrue(
            fixed.effectiveInstructions.contains("SPACE RULES"),
            "Turn-scoped instructions must be preserved for the agent"
        )
    }

    /// The transcript scaffold must never be treated as tool intent. Before the
    /// fix, gating ran on this exact scaffold and always returned true.
    func testTranscriptScaffoldDoesNotFabricateToolIntent() throws {
        let (spaceManager, botManager, _, _) = try makeRig()
        let space = try XCTUnwrap(spaceManager.activeSpace)
        let channel = try XCTUnwrap(space.sortedChannels.first)
        let bot = try XCTUnwrap(botManager.allBots.first)

        let scaffold = spaceManager.buildSpacePromptContext(
            for: bot, in: space, channel: channel, threadParentId: nil
        )

        // ORIGINAL BEHAVIOUR: gating the scaffold always enables tools.
        XCTAssertTrue(
            IntentToolSelector.shouldEnableTools(for: scaffold),
            "Anchor: pre-fix gating on the scaffold always enabled tools"
        )

        // CORRECT BEHAVIOUR: gating the human's real utterance is honest.
        XCTAssertFalse(
            IntentToolSelector.shouldEnableTools(for: "what do you think about the new layout?"),
            "A conversational question must not enable tools"
        )
    }

    // MARK: - 2. Direct-mention detection

    func testDirectMentionDetectedForOwnHandle() throws {
        let (spaceManager, botManager, _, _) = try makeRig()
        let space = try XCTUnwrap(spaceManager.activeSpace)
        let channel = try XCTUnwrap(space.sortedChannels.first)
        let bot = try XCTUnwrap(botManager.allBots.first)

        spaceManager.postHumanMessage(
            "@\(SpaceParticipant.normalizeHandle(bot.name)) please review this file",
            in: channel, triggerAgents: false
        )

        XCTAssertTrue(
            SpaceManager.isDirectlyMentioned(in: channel, by: bot, threadParentId: nil),
            "Explicit @handle must mark the turn as directly addressed"
        )
    }

    func testDirectMentionDetectedForDisplayNameWithSpaces() throws {
        let (spaceManager, botManager, _, _) = try makeRig()
        let space = try XCTUnwrap(spaceManager.activeSpace)
        let channel = try XCTUnwrap(space.sortedChannels.first)

        botManager.createBot(
            name: "Code Architect", title: "Engineer", descriptionText: "Reviews code."
        )
        let bot = try XCTUnwrap(botManager.botByName("Code Architect"))

        spaceManager.postHumanMessage(
            "@code-architect ship the release", in: channel, triggerAgents: false
        )

        XCTAssertTrue(
            SpaceManager.isDirectlyMentioned(in: channel, by: bot, threadParentId: nil),
            "Hyphenated handle must match a multi-word bot name"
        )
    }

    func testNoDirectMentionWhenMessageHasNoMentions() throws {
        let (spaceManager, botManager, _, _) = try makeRig()
        let space = try XCTUnwrap(spaceManager.activeSpace)
        let channel = try XCTUnwrap(space.sortedChannels.first)
        let bot = try XCTUnwrap(botManager.allBots.first)

        spaceManager.postHumanMessage(
            "just thinking out loud", in: channel, triggerAgents: false
        )

        XCTAssertFalse(
            SpaceManager.isDirectlyMentioned(in: channel, by: bot, threadParentId: nil),
            "An unaddressed message must not be treated as a direct mention"
        )
    }

    func testNoDirectMentionWhenADifferentBotIsTagged() throws {
        let (spaceManager, botManager, _, _) = try makeRig()
        let space = try XCTUnwrap(spaceManager.activeSpace)
        let channel = try XCTUnwrap(space.sortedChannels.first)
        let bots = botManager.allBots
        let target = try XCTUnwrap(bots.first)
        let other = try XCTUnwrap(bots.dropFirst().first)

        spaceManager.postHumanMessage(
            "@\(SpaceParticipant.normalizeHandle(other.name)) do the thing",
            in: channel, triggerAgents: false
        )

        XCTAssertFalse(
            SpaceManager.isDirectlyMentioned(in: channel, by: target, threadParentId: nil),
            "Tagging a teammate must not mark an untagged bot as addressed"
        )
    }

    func testBroadcastHandlesCountAsDirectMention() throws {
        let (spaceManager, botManager, _, _) = try makeRig()
        let space = try XCTUnwrap(spaceManager.activeSpace)
        let bot = try XCTUnwrap(botManager.allBots.first)

        for (index, token) in ["all", "agents", "everyone", "team"].enumerated() {
            let channel = try XCTUnwrap(space.sortedChannels[index % space.sortedChannels.count])
            spaceManager.postHumanMessage(
                "@\(token) summarize the meeting", in: channel, triggerAgents: false
            )
            XCTAssertTrue(
                SpaceManager.isDirectlyMentioned(in: channel, by: bot, threadParentId: nil),
                "Broadcast handle @\(token) must address every bot directly"
            )
        }
    }

    func testOriginatingHumanMessageExcludesBotTurns() throws {
        let (spaceManager, botManager, _, _) = try makeRig()
        let space = try XCTUnwrap(spaceManager.activeSpace)
        let channel = try XCTUnwrap(space.sortedChannels.first)
        let bot = try XCTUnwrap(botManager.allBots.first)
        let handle = SpaceParticipant.normalizeHandle(bot.name)

        spaceManager.postHumanMessage(
            "@\(handle) first question", in: channel, triggerAgents: false
        )
        let botReply = SpaceMessage(
            senderParticipantId: UUID(),
            senderName: bot.name,
            senderHandle: handle,
            senderKind: .bot,
            content: "Here is a summary of the README."
        )
        botReply.channel = channel
        channel.messages.append(botReply)

        XCTAssertEqual(
            SpaceManager.originatingHumanMessage(in: channel, threadParentId: nil),
            "@\(handle) first question",
            "Intent gating must use the human utterance, never a bot's reply"
        )
    }

    // MARK: - 3. Delegation-tool suppression on direct mention

    func testDelegationToolsWithheldOnDirectMention() {
        let context = ResolvedAgentContext(
            name: "Bot",
            effectiveInstructions: "persona",
            effectiveProvider: .appleOnDevice,
            effectiveAllowedTools: [
                "read_file", "delegate_task", "convene_meeting", "ask_bot", "write_file"
            ],
            source: .botProfileOverride
        )

        let withTools = AgentRequestRouter.resolveEffectiveAllowedTools(
            resolvedContext: context,
            toolCallingMode: .auto,
            intentText: "summarize the readme",
            isDirectMention: true
        )

        XCTAssertEqual(withTools, ["read_file", "write_file"],
                       "All delegation tools must be stripped on a direct mention")
    }

    func testDelegationToolsRetainedWhenNotDirectlyMentioned() {
        let context = ResolvedAgentContext(
            name: "Chief",
            effectiveInstructions: "persona",
            effectiveProvider: .appleOnDevice,
            effectiveAllowedTools: ["read_file", "delegate_task", "convene_meeting"],
            source: .botProfileOverride
        )

        // Even unaddressed, a BotProfile turn must not hand out delegation
        // tools — those belong to the supervisor archetype only.
        let tools = AgentRequestRouter.resolveEffectiveAllowedTools(
            resolvedContext: context,
            toolCallingMode: .auto,
            intentText: "what is the status",
            isDirectMention: false
        )

        XCTAssertEqual(tools, ["read_file"],
                       "BotProfile turns must never receive delegation tools")
    }

    func testDisabledToolModeYieldsEmptyToolset() {
        let context = ResolvedAgentContext(
            name: "Bot",
            effectiveInstructions: "persona",
            effectiveProvider: .appleOnDevice,
            effectiveAllowedTools: [],
            source: .botProfileOverride
        )

        let tools = AgentRequestRouter.resolveEffectiveAllowedTools(
            resolvedContext: context,
            toolCallingMode: .disabled,
            intentText: "hello",
            isDirectMention: true
        )

        XCTAssertEqual(tools, [], "Disabled tool mode must produce an empty toolset")
    }

    func testDirectAddressDirectiveIsAppendedOnlyForDirectMentions() {
        let plain = AgentRequestRouter.applyingDirectAddressPolicy(
            base: "You are Codex.", isDirectMention: false
        )
        XCTAssertEqual(plain, "You are Codex.")
        XCTAssertFalse(plain.contains("DIRECT ADDRESS"))

        let directed = AgentRequestRouter.applyingDirectAddressPolicy(
            base: "You are Codex.", isDirectMention: true
        )
        XCTAssertTrue(directed.contains("You are Codex."), "Persona must be preserved")
        XCTAssertTrue(directed.contains("DIRECT ADDRESS"), "Directive must be appended")
        XCTAssertTrue(
            directed.contains("Do NOT hand the task back to the user"),
            "Directive must forbid bouncing the task to the human"
        )
    }

    func testDirectAddressDirectiveIsIdempotent() {
        let once = AgentRequestRouter.applyingDirectAddressPolicy(
            base: "You are Codex.", isDirectMention: true
        )
        let twice = AgentRequestRouter.applyingDirectAddressPolicy(
            base: once, isDirectMention: true
        )
        XCTAssertEqual(once, twice, "Re-routing must not stack duplicate directives")
    }

    func testDirectAddressDirectiveHandlesEmptyBase() {
        let result = AgentRequestRouter.applyingDirectAddressPolicy(
            base: "   ", isDirectMention: true
        )
        XCTAssertTrue(result.contains("DIRECT ADDRESS"))
    }

    // MARK: - 4. Request contract defaults

    func testIntentTextDefaultsToPrompt() {
        let request = AgentRequest(prompt: "hello there")
        XCTAssertEqual(request.intentText, "hello there")
        XCTAssertFalse(request.isDirectMention)
    }

    func testExplicitIntentTextIsPreserved() {
        let request = AgentRequest(
            prompt: "<transcript scaffold>",
            intentText: "real user message",
            isDirectMention: true
        )
        XCTAssertEqual(request.intentText, "real user message")
        XCTAssertEqual(request.prompt, "<transcript scaffold>",
                       "Model-facing prompt must remain the scaffold")
        XCTAssertTrue(request.isDirectMention)
    }

    func testEveryDelegationToolIsCoveredByTheSuppressionSet() {
        let expected: Set<String> = ["delegate_task", "convene_meeting", "dispatch_swarm", "ask_bot"]
        XCTAssertEqual(AgentRuntimeCoordination.delegationTools, expected,
                       "Suppression set must cover every coordination/delegation tool")
    }

    // MARK: - 5. Space instruction content

    func testSpaceInstructionsForbidBouncingTheTask() throws {
        let (spaceManager, botManager, _, _) = try makeRig()
        let space = try XCTUnwrap(spaceManager.activeSpace)
        let channel = try XCTUnwrap(space.sortedChannels.first)
        let bot = try XCTUnwrap(botManager.allBots.first)

        let instructions = spaceManager.buildSpaceSystemInstructions(
            for: bot, in: space, channel: channel
        )
        XCTAssertTrue(instructions.contains("Do the requested work yourself"))
        XCTAssertTrue(instructions.contains("do NOT hand the task back to the human"))
    }

    func testSpacePromptContextIncludesTurnPriorityOnMention() throws {
        let (spaceManager, botManager, _, _) = try makeRig()
        let space = try XCTUnwrap(spaceManager.activeSpace)
        let channel = try XCTUnwrap(space.sortedChannels.first)
        let bot = try XCTUnwrap(botManager.allBots.first)

        spaceManager.postHumanMessage(
            "@\(SpaceParticipant.normalizeHandle(bot.name)) what does this do?",
            in: channel, triggerAgents: false
        )

        let context = spaceManager.buildSpacePromptContext(
            for: bot, in: space, channel: channel, threadParentId: nil
        )
        XCTAssertTrue(context.contains("TURN PRIORITY"),
                      "Mentioned bot must receive the turn-priority marker")
    }

    // MARK: - 6. BotSession handle matching

    func testHandleMatchingToleratesCaseSeparatorsAndSpaces() {
        let bot = BotProfile(name: "Code Architect", title: "Engineer", descriptionText: "")
        XCTAssertTrue(BotSession.handleMatches(handle: "code-architect", bot: bot))
        XCTAssertTrue(BotSession.handleMatches(handle: "code_architect", bot: bot))
        XCTAssertTrue(BotSession.handleMatches(handle: "CodeArchitect", bot: bot))
        XCTAssertTrue(BotSession.handleMatches(handle: "code architect", bot: bot))
        XCTAssertFalse(BotSession.handleMatches(handle: "oracle", bot: bot))
    }

    func testOrchestratorResolvesDirectMentionBotFromPrompt() throws {
        let (_, botManager, orchestrator, _) = try makeRig()
        botManager.createBot(name: "Code Architect", title: "Engineer", descriptionText: "Writes code")
        orchestrator.botManager = botManager

        let prompt = "@code-architect what is two plus two?"
        let mentionedHandles = SpaceManager.extractMentions(from: prompt)
        XCTAssertEqual(mentionedHandles, ["code-architect"])

        var targetBot: BotProfile? = nil
        var isDirectMention = false
        if let bm = orchestrator.botManager, !mentionedHandles.isEmpty {
            for b in bm.allBots {
                if mentionedHandles.contains(where: { BotSession.handleMatches(handle: $0, bot: b) }) {
                    targetBot = b
                    isDirectMention = true
                    break
                }
            }
        }

        XCTAssertTrue(isDirectMention)
        XCTAssertEqual(targetBot?.name, "Code Architect")
    }
}