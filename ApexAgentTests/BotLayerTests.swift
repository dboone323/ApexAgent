import Testing
import Foundation
import FoundationModels
import AppKit
@testable import ApexAgentCore

// MARK: - P-WS1: Bot / GroupChat / Routine / Skill layer tests (Grok Bot parity)
//
// These are the missing unit tests for the multi-bot "teammate" layer that
// BotLayer introduced. They are headless and fast: they exercise only the
// deterministic, non-generation surface (model composition, CRUD, routing,
// session bookkeeping) via a mock orchestrator — never a live
// LanguageModelSession. No network, no WebView, no SwiftData container.

// MARK: BotProfile

@Suite("BotProfileTests")
struct BotProfileTests {

    @Test func systemInstructionsWithTitleDescriptionAndMemory() {
        let bot = BotProfile(
            name: "Support",
            title: "Account Health",
            descriptionText: "Handle refunds within policy.",
            memory: "Dana approves annual contracts only."
        )
        let instructions = bot.systemInstructions
        #expect(instructions.contains("You are Support. Account Health"))
        #expect(instructions.contains("Handle refunds within policy."))
        #expect(instructions.contains("Dana approves annual contracts only."))
    }

    @Test func systemInstructionsOmitsTitleWhenEmpty() {
        let bot = BotProfile(name: "Apex")
        #expect(bot.systemInstructions.contains("You are Apex."))
        #expect(!bot.systemInstructions.contains("You are Apex. "))
    }

    @Test func memorySectionMarkedAsDurableContext() {
        let bot = BotProfile(name: "Bot", memory: "preference: short replies")
        #expect(bot.systemInstructions.contains("--- Durable working context ---"))
    }

    @Test func defaultIdentityDefaults() {
        let bot = BotProfile(name: "Research")
        #expect(bot.isPinned == false)
        #expect(bot.avatarName == "person.fill")
    }
}

// MARK: BotManager

@MainActor
@Suite("BotManagerTests")
struct BotManagerTests {

    private func makeManager() -> (BotManager, AgentOrchestrator) {
        let orchestrator = AgentOrchestrator()
        let manager = BotManager(orchestrator: orchestrator, computer: Computer())
        return (manager, orchestrator)
    }

    @Test func createBotRegistersAndSortsPinnedFirst() {
        let (manager, _) = makeManager()
        let a = manager.createBot(name: "Alpha", title: "T", descriptionText: "d")
        let b = manager.createBot(name: "Beta", title: "T", descriptionText: "d")
        #expect(manager.allBots.count == 2)
        // Pin Alpha and make it older so it sorts first.
        guard let alpha = manager.bot(byId: a.id) else { Issue.record("missing alpha"); return }
        alpha.isPinned = true
        alpha.lastActiveAt = b.lastActiveAt.addingTimeInterval(-1)
        #expect(manager.allBots.first?.id == a.id)
        #expect(manager.visibleBots.count == 2)
    }

    @Test func botByNameIsCaseInsensitive() {
        let (manager, _) = makeManager()
        let bot = manager.createBot(name: "MyBot", title: "", descriptionText: "")
        #expect(manager.botByName("mybot")?.id == bot.id)
        #expect(manager.botByName("nonexistent") == nil)
    }

    @Test func duplicateBotCopiesProfileWithFreshIdentity() {
        let (manager, _) = makeManager()
        let original = manager.createBot(
            name: "Original",
            title: "Ops",
            descriptionText: "rules",
            avatarName: "gearshape.fill"
        )
        let copy = manager.duplicateBot(original)
        #expect(copy.id != original.id)
        #expect(copy.name == "Original copy")
        #expect(copy.title == original.title)
        #expect(copy.descriptionText == original.descriptionText)
        #expect(copy.avatarName == original.avatarName)
        #expect(manager.allBots.count == 2)
        #expect(manager.session(for: copy).messages.isEmpty)
    }

    @Test func hideBotUnpins() {
        let (manager, _) = makeManager()
        let bot = manager.createBot(name: "Pinned", title: "", descriptionText: "")
        bot.isPinned = true
        manager.hideBot(bot)
        #expect(bot.isPinned == false)
    }

    @Test func setActiveBotTracksActiveSession() {
        let (manager, _) = makeManager()
        let a = manager.createBot(name: "A", title: "", descriptionText: "")
        let b = manager.createBot(name: "B", title: "", descriptionText: "")
        manager.setActiveBot(a.id)
        #expect(manager.activeBotId == a.id)
        #expect(manager.activeSession?.bot.id == a.id)
        manager.setActiveBot(b.id)
        #expect(manager.activeSession?.bot.id == b.id)
    }

    @Test func attentionListsBotsWaitingForUser() {
        let (manager, _) = makeManager()
        let bot = manager.createBot(name: "Waiter", title: "", descriptionText: "")
        #expect(manager.botsNeedingAttention.isEmpty)
        manager.session(for: bot).needsAttention = true
        #expect(manager.botsNeedingAttention.contains(where: { $0.id == bot.id }))
    }
}

// MARK: BotSession

@MainActor
@Suite("BotSessionTests")
struct BotSessionTests {

    private func makeSession() -> (BotSession, AgentOrchestrator) {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let bot = BotProfile(name: "Support", title: "Account Health", descriptionText: "d", memory: "mem")
        let session = BotSession(bot: bot, orchestrator: orchestrator, computer: computer)
        return (session, orchestrator)
    }

    @Test func systemInstructionsFollowsProfile() {
        let (session, _) = makeSession()
        #expect(session.systemInstructions.contains(session.bot.systemInstructions))
        #expect(session.systemInstructions.contains("Account Health"))
    }

    @Test func appendAndUpdateMessageRoundTrip() {
        let (session, _) = makeSession()
        let msg = ChatMessage(role: .user, content: "hello")
        session.appendMessage(msg)
        #expect(session.messages.count == 1)
        session.updateMessage(id: msg.id, content: "hello world")
        #expect(session.messages[0].content == "hello world")
    }

    @Test func resetClearsConversationState() {
        let (session, _) = makeSession()
        session.appendMessage(ChatMessage(role: .user, content: "x"))
        session.needsAttention = true
        session.unreadActivity = true
        session.reset()
        #expect(session.messages.isEmpty)
        #expect(session.needsAttention == false)
        #expect(session.unreadActivity == false)
        #expect(session.activePlan.isEmpty)
    }

    @Test func executeToolWithoutOrchestratorReturnsError() async {
        // A session holding a nil orchestrator must degrade to a clear error.
        let computer = Computer()
        let bot = BotProfile(name: "orphan")
        let session = BotSession(bot: bot, orchestrator: AgentOrchestrator(), computer: computer)
        session.orchestrator = nil
        let out = try? await session.executeTool(name: "read_file", arguments: "{}")
        #expect(out?.hasPrefix("ERROR:") == true)
    }
}

// MARK: GroupChatSession (deterministic surface only)

@MainActor
@Suite("GroupChatModelTests")
struct GroupChatModelTests {

    private func makeGroup() -> GroupChatSession {
        let a = BotProfile(name: "Research")
        let b = BotProfile(name: "Comms")
        return GroupChatSession(name: "Launch", participants: [a, b])
    }

    @Test func generationOrderMatchesParticipantOrder() {
        let group = makeGroup()
        let ids = group.participants.map(\.id)
        #expect(group.generationOrder == ids)
        #expect(group.activeParticipant?.id == ids.first)
        #expect(group.allBotParticipants.count == 2)
    }

    @Test func constructorDefaultsAreSafe() {
        let group = makeGroup()
        #expect(group.isGenerating == false)
        #expect(group.currentTurnIndex == 0)
        #expect(group.maxTurnsPerParticipant == 3)
    }
}

// MARK: Routine / Skill models + RoutineManager nil-guard

@Suite("RoutineAndSkillModelTests")
struct RoutineAndSkillModelTests {

    @Test func routineDefaults() {
        let r = Routine(name: "standup", descriptionText: "standup")
        #expect(r.trigger == .manual)
        #expect(r.enabled == true)
        #expect(r.scheduledMinutes == 0)
    }

    @Test func routineTriggerRawValues() {
        #expect(RoutineTrigger.manual.rawValue == "Manual")
        #expect(RoutineTrigger.timeInterval.rawValue == "Every N minutes")
        #expect(RoutineTrigger.onError.rawValue == "When build/tool fails")
        #expect(RoutineTrigger.onSuccess.rawValue == "When build/tool succeeds")
        #expect(RoutineTrigger.onMessage.rawValue == "On specific message")
    }

    @Test func skillDefaults() {
        let s = Skill(name: "gs", descriptionText: "d", scriptPath: "/tmp/x.sh", parameterSchemaJSON: "{}")
        #expect(s.category == "custom")
        #expect(s.enabled == true)
    }
}

@MainActor
@Suite("RoutineManagerSmokeTests")
struct RoutineManagerSmokeTests {
    @Test func executeWithoutBotManagerReturnsNil() async {
        // With no BotManager wired up, execute must degrade gracefully (nil)
        // instead of trapping or starting a generation.
        let r = Routine(name: "orphan", descriptionText: "orphan")
        let result = await RoutineManager.shared.execute(r)
        #expect(result == nil)
    }
}