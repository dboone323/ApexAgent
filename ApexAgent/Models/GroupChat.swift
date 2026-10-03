import Foundation
import AppKit

// MARK: - Default Tool Allowlist for Group Chat Sessions (WS6)
//
// These tools are safe to run automatically in group chats without prompting
// for approval. Dangerous tools (run_shell_command, write_file, delete_file, etc.)
// still require confirmation unless explicitly overridden.
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
    private var isolatedSessions: [UUID: BotSession] = [:]
    private var activeTurnTask: Task<Void, Never>?

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

    // MARK: - Session Management (Isolated from 1:1 sessions)
    func session(for bot: BotProfile) -> BotSession {
        if let existing = isolatedSessions[bot.id] {
            return existing
        }
        let orch = self.orchestrator ?? AgentOrchestrator()
        let comp = self.computer ?? Computer()
        let s = BotSession(bot: bot, orchestrator: orch, computer: comp)
        isolatedSessions[bot.id] = s
        return s
    }

    var participantSessions: [UUID: BotSession] {
        var map: [UUID: BotSession] = [:]
        for bot in participants {
            map[bot.id] = session(for: bot)
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
        // Clean isolated sessions for this group round without touching user 1:1 sessions
        for bot in participants {
            isolatedSessions[bot.id]?.reset()
        }
        beginNextTurn()
    }

    func stop() {
        activeTurnTask?.cancel()
        activeTurnTask = nil
        isGenerating = false
        activeGeneratorId = nil
        for bot in participants {
            participantsGenerating[bot.id] = false
        }
    }

    // MARK: - Turn Execution (WS6)
    private func beginNextTurn() {
        guard currentTurnIndex < generationOrder.count else {
            // All participants have had their turns — end the group round
            isGenerating = false
            activeTurnTask = nil
            return
        }
        let botId = generationOrder[currentTurnIndex]
        guard let bot = participants.first(where: { $0.id == botId }) else {
            advanceTurn()
            return
        }
        runParticipantTurn(for: bot)
    }

    func runParticipantTurn(for bot: BotProfile) {
        guard let orchestrator = orchestrator else { return }
        participantsGenerating[bot.id] = true
        activeGeneratorId = bot.id

        let session = session(for: bot)
        session.resetSession()

        // Build context: all prior messages in the group chat
        let context = buildGroupContext(for: bot)

        // Add a "thinking" marker so the UI shows who's talking
        let thinkingMsg = ChatMessage(
            role: .assistant,
            content: "[\(bot.name) is thinking...]",
            timestamp: Date(),
            isStreaming: true,
            attachments: [],
            botName: bot.name
        )
        messages.append(thinkingMsg)
        let thinkingId = thinkingMsg.id

        let toolMode: AgentToolCallingMode = switch session.toolCallingMode {
        case .auto: .auto
        case .required: .required
        case .disabled: .disabled
        }

        // Mandatory canonical runtime: GroupChat participant turns route through
        // AgentRequestRouter → buildCandidateChain → ProviderFallbackExecutor so
        // every participant gets candidate planning, bounded fallback, tool
        // governance, and terminal-state normalization.
        let request = AgentRequest(
            conversationId: self.id,
            senderIdentity: .bot(id: bot.id, name: bot.name),
            prompt: context,
            toolCallingMode: toolMode
        )
        let instructions = bot.systemInstructions + "\n\n" + groupBotInstructions(botName: bot.name)
        activeTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let terminalState = await AgentRequestRouter.shared.route(
                request,
                bot: bot,
                session: session.session,
                history: [],
                instructions: instructions,
                orchestrator: orchestrator,
                onUpdate: { [weak self] partialContent in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let idx = self.messages.firstIndex(where: { $0.id == thinkingId }) {
                            var copy = self.messages
                            copy[idx].content = SecretRedactor.redact(text: partialContent)
                            self.messages = copy
                        }
                    }
                }
            )
            if !terminalState.isSuccess {
                if let idx = self.messages.firstIndex(where: { $0.id == thinkingId }) {
                    var copy = self.messages
                    copy[idx].content = terminalState.userFacingMessage
                    self.messages = copy
                }
            }

            // Mark the thought bubble as done (no longer streaming)
            if let idx = self.messages.firstIndex(where: { $0.id == thinkingId }) {
                var copy = self.messages
                copy[idx].isStreaming = false
                self.messages = copy

                // Check for dynamic @mentions in the bot's generated response!
                let finalContent = self.messages[idx].content
                let mentions = SpaceManager.extractMentions(from: finalContent)
                if !mentions.isEmpty {
                    self.handleTurnMentions(mentions: mentions, speakingBot: bot)
                }
            }

            self.participantsGenerating[bot.id] = false
            self.activeGeneratorId = nil
            self.advanceTurn()
        }
    }

    private func handleTurnMentions(mentions: [String], speakingBot: BotProfile) {
        guard let bm = botManager else { return }
        let matchedBots = SpaceManager.matchBots(for: mentions, in: nil, botManager: bm)
            .filter { $0.id != speakingBot.id }

        for mentionedBot in matchedBots {
            if !participants.contains(where: { $0.id == mentionedBot.id }) {
                participants.append(mentionedBot)
                let joinNotice = ChatMessage(
                    role: .system,
                    content: "[\(mentionedBot.name) was tagged by \(speakingBot.name) and joined the group chat]",
                    timestamp: Date(),
                    attachments: []
                )
                messages.append(joinNotice)
            }

            // Insert mentioned bot right next in turn queue
            let nextIndex = min(currentTurnIndex + 1, generationOrder.count)
            if let existingFutureIdx = generationOrder.dropFirst(currentTurnIndex + 1).firstIndex(of: mentionedBot.id) {
                generationOrder.remove(at: existingFutureIdx)
            }
            generationOrder.insert(mentionedBot.id, at: nextIndex)
            isGenerating = true
        }
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
        var lastSpeakerName = ""
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
            lastSpeakerName = roleLabel
            context += "[\(roleLabel)] \(msg.content)\n\n"
        }

        // Memory & Turn Priority injection
        let cleanBotName = SpaceParticipant.normalizeHandle(bot.name).replacingOccurrences(of: "-", with: "")
        if let lastMsg = messages.last(where: { $0.role != .system && !($0.content.hasPrefix("[") && $0.content.hasSuffix("]")) }) {
            let mentions = SpaceManager.extractMentions(from: lastMsg.content)
            let isMentioned = mentions.contains(where: {
                let mClean = $0.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
                return mClean == cleanBotName || mClean == "all" || mClean == "agents" || mClean == "team"
            })
            if isMentioned {
                context += "⚡️ Note: The previous speaker (\(lastSpeakerName)) directly mentioned you. Address their question or task directly.\n"
            }
        }

        context += "\nYour turn. Respond concisely (2-4 sentences)."
        return context
    }

    private func groupBotInstructions(botName: String) -> String {
        """
        You are in a collaborative group conversation.
        - You are speaking on behalf of yourself (\(botName)).
        - Respond concisely (2-4 sentences unless doing real work or asked for depth).
        - If another bot asked you a question or mentioned you (@\(botName)), answer them directly.
        - If you need input from a teammate, tag them using @BotName (e.g. @CodeArchitect, @Researcher).
        """
    }
}
