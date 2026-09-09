import Foundation
import FoundationModels
import SwiftData
import Observation
import AppKit
import SwiftUI

// MARK: - GroupChatManagerEnvironmentValues: SwiftUI environment key for GroupChatManager

struct GroupChatManagerEnvironmentValues {
    var groupChatManager: GroupChatManager
}

extension EnvironmentValues {
    var groupChatManager: GroupChatManager {
        get { self[GroupChatManagerEnvironmentValuesKey.self] }
        set { self[GroupChatManagerEnvironmentValuesKey.self] = newValue }
    }
}

private struct GroupChatManagerEnvironmentValuesKey: EnvironmentKey {
    static var defaultValue: GroupChatManager {
        MainActor.assumeIsolated { GroupChatManager() }
    }
}

// MARK: - GroupChatSession: A chat session involving multiple Bots

/// A group chat lets two or more Bots collaborate on a conversation.
/// Each participant Bot sends messages sequentially (round-robin), and
/// the user can watch, steer, or join mid-flow. The session is ephemeral —
/// it does not persist across app launches (that's Phase 3).
///
/// Group chats reuse the existing BotSession/BotMessageSender machinery:
/// each participant gets a fresh BotSession, and messages from all
/// participants appear in one shared ChatMessage list rendered in a
/// single chat view. The user's own messages are tagged with the
/// "host" role so the group knows the human is present.
// MARK: - GroupToolPermission & allowlist (Grok Bot: group chat takes actions)

/// Outcome of asking whether a group participant may run a given tool.
enum GroupToolPermission: Equatable {
    case allowed
    case needsApproval
    case denied(String)
}

/// Safe tools group participants may run without extra scoping. Filesystem-
/// mutating, shell, and AppleScript tools are intentionally excluded by default.
enum DefaultGroupToolAllowlist {
    static let set: Set<String> = [
        "web_search", "read_file", "list_directory", "file_search",
        "search_memory", "store_memory", "get_system_info", "send_notification",
    ]
}

@Observable
@MainActor
final class GroupChatSession {
    // MARK: - Identity
    let id: UUID = UUID()
    var name: String
    var participants: [BotProfile]
    var hostBot: BotProfile?  // optional: the Bot that leads/moderates the group

    // MARK: - Conversation State (shared across all participants)
    var messages: [ChatMessage] = []
    var isGenerating: Bool = false
    var activeGeneratorId: UUID?  // which participant is currently talking
    var pendingConfirmation: ConfirmationRequest?
    var pendingAttachments: [NSImage] = []

    // MARK: - Generation control
    var participantsGenerating: [UUID: Bool] = [:]  // botId → currently generating
    var generationOrder: [UUID]  // round-robin order (participant bot ids)
    var currentTurnIndex: Int = 0
    var maxTurnsPerParticipant: Int = 3  // stop after N turns each, or let user interrupt

    // MARK: - Group tool actions (WS6: bots can take real work, not just talk)
    var toolCallsEnabled = true
    var allowedGroupTools: Set<String> = DefaultGroupToolAllowlist.set
    private(set) var toolExecutionLog: [String] = []  // "tool: <result>"

    /// Tools that always require human approval, even when weblisted.
    private static let riskyGroupTools: Set<String> =
        ["run_shell_command", "write_file", "delete_file", "move_file", "run_applescript"]

    // MARK: - Shared references (not owned)
    weak var orchestrator: AgentOrchestrator?
    weak var computer: Computer?
    weak var botManager: BotManager?

    // MARK: - Init
    init(name: String, participants: [BotProfile], hostBot: BotProfile? = nil) {
        self.name = name
        self.participants = participants
        self.hostBot = hostBot
        self.generationOrder = participants.map { $0.id }
    }

    // MARK: - Computed
    var participantSessions: [UUID: BotSession] {
        var map: [UUID: BotSession] = [:]
        for bot in participants {
            if let bm = botManager {
                map[bot.id] = bm.session(for: bot)
            }
        }
        return map
    }

    var activeParticipant: BotProfile? {
        guard currentTurnIndex < generationOrder.count else { return nil }
        let botId = generationOrder[currentTurnIndex]
        return participants.first { $0.id == botId }
    }

    var allBotParticipants: [BotProfile] {
        participants
    }

    // MARK: - Start / Stop
    func start() {
        guard !generationOrder.isEmpty else { return }
        isGenerating = true
        currentTurnIndex = 0
        // Reset each participant's session to give them a clean slate for the group
        for bot in participants {
            if let s = participantSessions[bot.id] {
                s.reset()
            }
        }
        // Seed the group with a system message describing who's present
        let systemMsg = ChatMessage(
            role: .system,
            content: groupSystemMessage,
            timestamp: Date(),
            attachments: []
        )
        messages.append(systemMsg)
        // Start the first participant's turn
        beginNextTurn()
    }

    func stop() {
        isGenerating = false
        for botId in participantsGenerating.keys {
            participantsGenerating[botId] = false
        }
        activeGeneratorId = nil
    }

    func cancel() {
        stop()
    }

    // MARK: - Turn orchestration
    func beginNextTurn() {
        guard currentTurnIndex < generationOrder.count else {
            // All participants have had their turns — end the group round
            isGenerating = false
            return
        }
        let botId = generationOrder[currentTurnIndex]
        participantsGenerating[botId] = true
        activeGeneratorId = botId
        let bot = participants.first { $0.id == botId }!
        Task { @MainActor in
            await runParticipantTurn(bot)
        }
    }

    private func runParticipantTurn(_ bot: BotProfile) async {
        guard let session = participantSessions[bot.id],
              let orchestrator = orchestrator else {
            participantsGenerating[bot.id] = false
            advanceTurn()
            return
        }

        // Build the group context: all messages so far + a prompt telling this Bot
        // it's in a group chat and should respond to the conversation/other Bots.
        let context = buildGroupContext(for: bot)

        // Add a "thinking" marker so the UI shows who's talking
        let thinkingMsg = ChatMessage(
            role: .assistant,
            content: "[\(bot.name) is thinking...]",
            timestamp: Date(),
            isStreaming: true,
            attachments: []
        )
        messages.append(thinkingMsg)
        let thinkingId = thinkingMsg.id

        let toolMode: AgentToolCallingMode = switch session.toolCallingMode {
        case .auto: .auto
        case .required: .required
        case .disabled: .disabled
        }

        do {
            let engine = resolveEngine(for: bot, prompt: context, orchestrator: orchestrator)
            try await engine.streamResponse(
                prompt: context,
                attachments: [],
                history: [],
                instructions: bot.systemInstructions + "\n\n" + groupBotInstructions(botName: bot.name),
                toolCallingMode: toolMode,
                onUpdate: { [weak self] partialContent in
                    guard let self else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == thinkingId }) {
                        var copy = self.messages
                        copy[idx].content = SecretRedactor.redact(text: partialContent)
                        self.messages = copy
                    }
                }
            )
        } catch {
            if let idx = self.messages.firstIndex(where: { $0.id == thinkingId }) {
                var copy = self.messages
                copy[idx].content = "⚠️ \(bot.name) Error: \(error.localizedDescription)"
                self.messages = copy
            }
        }

        // Mark the thought bubble as done (no longer streaming)
        if let idx = self.messages.firstIndex(where: { $0.id == thinkingId }) {
            var copy = self.messages
            copy[idx].isStreaming = false
            self.messages = copy
        }

        participantsGenerating[bot.id] = false
        activeGeneratorId = nil
        advanceTurn()
    }

    func advanceTurn() {
        currentTurnIndex += 1
        if currentTurnIndex < generationOrder.count && isGenerating {
            beginNextTurn()
        } else {
            isGenerating = false
            activeGeneratorId = nil
        }
    }

    private func resolveEngine(for bot: BotProfile, prompt: String, orchestrator: AgentOrchestrator) -> any AgentEngine {
        ModelRegistry.resolveEngine(
            for: bot,
            prompt: prompt,
            instructions: bot.systemInstructions,
            orchestrator: orchestrator
        )
    }

    // MARK: - User messages
    func sendUserMessage(_ text: String, attachments: [NSImage] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let userMsg = ChatMessage(
            role: .user,
            content: trimmed,
            timestamp: Date(),
            attachments: attachments
        )
        messages.append(userMsg)
    }

    func sendUserMessageToParticipant(_ text: String, addressedTo bot: BotProfile) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let userMsg = ChatMessage(
            role: .user,
            content: "[\(bot.name)] \(trimmed)",
            timestamp: Date(),
            attachments: []
        )
        messages.append(userMsg)
    }

    // MARK: - Context building
    private var groupSystemMessage: String {
        let names = participants.map { $0.name }.joined(separator: ", ")
        var msg = "GROUP CHAT: \(name)\n"
        msg += "Participants: \(names)"
        if let host = hostBot {
            msg += "\nModerator: \(host.name)"
        }
        msg += "\n\nThis is a collaborative group chat. Each Bot takes turns responding to the conversation. Bots should listen to what others say, build on it, ask clarifying questions, and avoid repeating what was already said."
        return msg
    }

    func buildGroupContext(for bot: BotProfile) -> String {
        var context = "You are \(bot.name), participating in a group chat called '\(name)'.\n\n"
        context += "Here is the conversation so far:\n\n"
        for msg in messages {
            let roleLabel: String
            switch msg.role {
            case .user: roleLabel = "User"
            case .assistant:
                if msg.content.hasPrefix("[") && msg.content.hasSuffix("]") {
                    continue
                }
                roleLabel = msg.botName ?? "Assistant"
            case .system: roleLabel = "System"
            }
            context += "[\(roleLabel)] \(msg.content)\n\n"
        }
        context += "\nYour turn. Respond concisely (2-4 sentences)."
        return context
    }

    private func groupBotInstructions(botName: String) -> String {
        """
        You are in a multi-Bot group chat. Follow these rules:
        1. Be concise — 2-4 sentences per turn.
        2. Address what the previous speaker said; don't repeat it.
        3. If you disagree or have a different approach, say so respectfully.
        4. Ask clarifying questions when the group is ambiguous.
        5. You may call approved tools to get real work done when it helps the group.
           Never modify files, run shell commands, or use AppleScript without approval.
        6. Stay in character as \(botName).
        """
    }

    // MARK: - Group tool actions (permission + execution)

    /// Pure preflight decision for whether a group participant may run `tool`.
    /// Deterministic and side-effect free, so it is unit-testable without an
    /// orchestrator or model.
    func groupToolPermission(tool: String) -> GroupToolPermission {
        guard toolCallsEnabled else {
            return .denied("Group tool calls are disabled for this chat.")
        }
        guard allowedGroupTools.contains(tool) else {
            return .denied("'\(tool)' is not an allowed group tool.")
        }
        return Self.riskyGroupTools.contains(tool) ? .needsApproval : .allowed
    }

    /// Runs a tool on behalf of a group participant, applying the allowlist and
    /// the human confirmation gate. Never reaches the filesystem/network while
    /// the permission is denied or the approval is refused.
    func executeGroupTool(tool: String, arguments: String) async throws -> String {
        switch groupToolPermission(tool: tool) {
        case .allowed:
            break
        case .needsApproval:
            let approved = await orchestrator?.requestConfirmation(
                toolName: tool,
                arguments: arguments,
                riskDescription: "A Bot in the group '\(name)' wants to run '\(tool)'."
            ) ?? false
            guard approved else {
                return "DECLINED: A Bot requested '\(tool)' but the approval was not granted."
            }
        case .denied(let reason):
            return "DENIED: \(reason)"
        }

        guard let orchestrator else {
            return "ERROR: No orchestrator available to execute '\(tool)'."
        }
        let result = try await orchestrator.executeToolByName(name: tool, jsonArguments: arguments)
        toolExecutionLog.append("\(tool): \(result.prefix(200))")
        return result
    }

    // MARK: - Reset
    func reset() {
        messages = []
        isGenerating = false
        activeGeneratorId = nil
        participantsGenerating.removeAll()
        currentTurnIndex = 0
        pendingAttachments = []
        toolExecutionLog = []
    }
}

// MARK: - GroupChatManager: owns active group chats

/// Lightweight manager for in-progress group chats.
@Observable
@MainActor
final class GroupChatManager {
    private var sessions: [UUID: GroupChatSession] = [:]
    
    var allGroups: [GroupChatSession] { Array(sessions.values) }
    var activeGroupId: UUID?
    
    var activeGroup: GroupChatSession? { 
        guard let id = activeGroupId else { return nil }
        return sessions[id] 
    }
    
    var runningGroupsCount: Int { 
        sessions.values.filter { $0.isGenerating }.count 
    }

    weak var botManager: BotManager?
    weak var orchestrator: AgentOrchestrator?

    func startGroup(name: String, participantIds: [UUID], hostBotId: UUID? = nil) -> GroupChatSession {
        let participants = participantIds.compactMap { botManager?.bot(byId: $0) }
        let host = hostBotId.flatMap { botManager?.bot(byId: $0) }
        let group = GroupChatSession(name: name, participants: participants, hostBot: host)
        
        group.botManager = botManager
        group.orchestrator = orchestrator ?? botManager?.orchestrator
        group.computer = botManager?.computer
        
        sessions[group.id] = group
        activeGroupId = group.id
        group.start()
        
        return group
    }

    func selectGroup(id: UUID) {
        activeGroupId = id
    }

    func closeGroup(id: UUID) {
        sessions[id]?.stop()
        sessions.removeValue(forKey: id)
        if activeGroupId == id {
            activeGroupId = sessions.keys.first
        }
    }

    func cancelAllGroups() {
        for group in sessions.values {
            group.cancel()
        }
        sessions.removeAll()
        activeGroupId = nil
    }

    public func stopGroup() {
        activeGroup?.stop()
        if let id = activeGroupId {
            sessions.removeValue(forKey: id)
            activeGroupId = sessions.keys.first
        }
    }

    public func cancelGroup() {
        activeGroup?.cancel()
        if let id = activeGroupId {
            sessions.removeValue(forKey: id)
            activeGroupId = sessions.keys.first
        }
    }

    public func sendToGroup(_ text: String) {
        activeGroup?.sendUserMessage(text)
    }

    public func sendToParticipant(_ text: String, botId: UUID) {
        guard let group = activeGroup,
              let bot = group.participants.first(where: { $0.id == botId }) else { return }
        group.sendUserMessageToParticipant(text, addressedTo: bot)
    }

    public func endTurnEarly() {
        guard let group = activeGroup else { return }
        group.currentTurnIndex += 1
        if group.currentTurnIndex < group.generationOrder.count {
            group.beginNextTurn()
        } else {
            group.isGenerating = false
            group.activeGeneratorId = nil
        }
    }
}
