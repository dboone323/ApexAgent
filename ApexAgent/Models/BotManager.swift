import Foundation
import FoundationModels
import SwiftData
import Observation
import AppKit
import SharedKit

// MARK: - BotManager: Central registry of Bots + their sessions

/// BotManager owns all BotProfile instances (persisted in SwiftData) and their
/// active BotSession instances (in-memory, one per open conversation). It is the
/// entry point for creating Bots, switching between them, and routing messages.
///
/// It replaces the "one global AgentOrchestrator" model with a multi-Bot model
/// where:
///   - Each Bot has its own instructions, memory, avatar, and conversation
///   - All Bots share the local Computer (filesystem, browser, terminal)
///   - All Bots share the underlying model + tool registry via the shared
///     AgentOrchestrator
///   - The active Bot is what receives messages in the chat view
///
/// BotManager is @Observable so SwiftUI can react to Bot creation, switching,
/// and attention states.
@Observable
@MainActor
final class BotManager {
    // MARK: - Shared Infrastructure (references, not owned)
    weak var orchestrator: AgentOrchestrator?
    let computer: Computer

    // MARK: - SwiftData
    var modelContext: ModelContext?

    // MARK: - Bot Registry
    private var bots: [BotProfile] = []
    private var sessions: [UUID: BotSession] = [:]  // botId → active session

    // MARK: - Active Bot
    var activeBotId: UUID?
    var activeSession: BotSession? {
        guard let botId = activeBotId else { return nil }
        return sessions[botId]
    }

    // MARK: - Attention Tracking
    /// Bots that need user attention (waiting for approval, have unread results).
    var botsNeedingAttention: [BotProfile] {
        bots.filter { bot in
            guard let s = sessions[bot.id] else { return false }
            return s.needsAttention || s.unreadActivity
        }
    }

    // MARK: - Init

    init(orchestrator: AgentOrchestrator, computer: Computer) {
        self.orchestrator = orchestrator
        self.computer = computer
    }

    /// Single session factory so every session carries the manager
    /// back-reference (chief-of-staff roster composition needs it).
    private func makeSession(for bot: BotProfile) -> BotSession {
        let session = BotSession(bot: bot, orchestrator: orchestrator!, computer: computer)
        session.botManager = self
        return session
    }

    /// Non-creating peek at whether a bot's session is mid-generation.
    func isGenerating(botId: UUID) -> Bool {
        sessions[botId]?.isGenerating ?? false
    }

    // MARK: - Peer approvals (O9 wiring)

    /// Gate for BOT-initiated contact with another bot (a chief delegating,
    /// an ask-bot hand-off). User-typed messages never pass through here.
    let peerApprovals = PeerApprovalCoordinator()

    enum PeerDeliveryDecision: Equatable {
        /// A grant covered this pair — deliver immediately.
        case deliver
        /// A card was raised on the sender's session; hold the message until
        /// `resolvePeerRequest` settles it.
        case blockedPendingCard(requestId: String)
    }

    /// Decide whether `from` may send `message` to `to`. Without a grant this
    /// raises a pending approval and flags the sender's session for attention;
    /// the caller must not deliver until it resolves to allow.
    func peerDeliveryDecision(from: BotProfile, to: BotProfile, message: String) -> PeerDeliveryDecision {
        let outcome = peerApprovals.requestApproval(
            fromBotId: from.id.uuidString,
            toBotId: to.id.uuidString,
            action: .askBot,
            message: message)
        switch outcome {
        case .allowedByExistingGrant:
            return .deliver
        case .pendingCard(let requestId):
            if let senderSession = sessions[from.id] {
                senderSession.needsAttention = true
            }
            return .blockedPendingCard(requestId: requestId)
        }
    }

    /// Settle a peer-approval card. With `remember`, a grant is written so the
    /// same (action, target) pair passes silently next time.
    @discardableResult
    func resolvePeerRequest(requestId: String, allow: Bool, remember: Bool = false) -> Bool {
        let request = peerApprovals.pendingRequest(id: requestId)
        guard case .resolved(let allowed) =
            peerApprovals.resolve(requestId: requestId, allow: allow, rememberGrant: remember) else {
            return false
        }
        // The card settled: clear the attention flag it raised.
        if let request, let uuid = UUID(uuidString: request.fromBotId),
           let senderSession = sessions[uuid] {
            senderSession.needsAttention = false
        }
        return allowed
    }

    // MARK: - Bot CRUD

    /// Creates a new Bot with the given parameters and persists it.
    func createBot(
        name: String,
        title: String,
        descriptionText: String,
        avatarName: String = "person.fill"
    ) -> BotProfile {
        let bot = BotProfile(
            name: name,
            title: title,
            descriptionText: descriptionText,
            avatarName: avatarName,
            isPinned: false
        )
        saveBot(bot)
        let session = makeSession(for: bot)
        sessions[bot.id] = session
        return bot
    }

    /// Duplicates a Bot — same profile, settings, memory, but fresh conversation.
    func duplicateBot(_ bot: BotProfile) -> BotProfile {
        let copy = BotProfile(
            name: "\(bot.name) copy",
            title: bot.title,
            descriptionText: bot.descriptionText,
            avatarName: bot.avatarName,
            memory: bot.memory,
            isPinned: bot.isPinned
        )
        copy.isChiefOfStaff = bot.isChiefOfStaff
        copy.modelProviderRaw = bot.modelProviderRaw
        copy.ollamaModelOverride = bot.ollamaModelOverride
        saveBot(copy)
        let session = makeSession(for: copy)
        sessions[copy.id] = session
        return copy
    }

    /// Hides a Bot from the main list without deleting it.
    func hideBot(_ bot: BotProfile) {
        bot.isPinned = false
    }

    /// Deletes a Bot's profile and session. Shared computer files remain.
    func deleteBot(_ bot: BotProfile) {
        sessions.removeValue(forKey: bot.id)
        if activeBotId == bot.id {
            activeBotId = bots.first { $0.id != bot.id }?.id
        }
        if let context = modelContext {
            context.delete(bot)
            try? context.save()
        }
        bots.removeAll { $0.id == bot.id }
    }

    /// Pins/unpins a Bot to keep it at the top of the sidebar.
    func togglePin(_ bot: BotProfile) {
        bot.isPinned.toggle()
        if bot.isPinned { bot.updatedAt = Date() }
        try? modelContext?.save()
    }

    /// Edits a Bot's profile.
    func editBot(_ bot: BotProfile, name: String? = nil, title: String? = nil, descriptionText: String? = nil, avatarName: String? = nil, memory: String? = nil) {
        if let name = name { bot.name = name }
        if let title = title { bot.title = title }
        if let descriptionText = descriptionText { bot.descriptionText = descriptionText }
        if let avatarName = avatarName { bot.avatarName = avatarName }
        if let memory = memory { bot.memory = memory }
        bot.updatedAt = Date()
        try? modelContext?.save()
    }

    /// Updates a Bot's durable memory from the conversation.
    func updateBotMemory(_ bot: BotProfile, newMemory: String) {
        bot.memory = newMemory
        bot.updatedAt = Date()
        try? modelContext?.save()
        if let session = sessions[bot.id] {
            session.resetSession()
        }
    }

    // MARK: - Session Management

    /// Opens a conversation with a Bot — creates a new session if one doesn't exist.
    func openConversation(with bot: BotProfile) {
        if sessions[bot.id] == nil {
            let session = makeSession(for: bot)
            sessions[bot.id] = session
        }
        activeBotId = bot.id
        bot.lastActiveAt = Date()
        if let s = sessions[bot.id] {
            s.unreadActivity = false
            s.needsAttention = false
        }
        try? modelContext?.save()
    }

    /// Returns the active session for a Bot, creating one if needed.
    func session(for bot: BotProfile) -> BotSession {
        if let existing = sessions[bot.id] {
            return existing
        }
        let session = makeSession(for: bot)
        sessions[bot.id] = session
        return session
    }

    // MARK: - Message Routing

    /// Sends a message to the active Bot. If no Bot is active, creates a default
    /// "Apex" Bot if one doesn't exist.
    func sendMessage(_ text: String) {
        guard let session = activeSession else {
            if bots.isEmpty {
                let defaultBot = createBot(
                    name: "Apex",
                    title: "General Assistant",
                    descriptionText: "You are Apex, a helpful AI assistant running on this Mac. You can read files, run commands, search the web, and automate tasks. Be concise and helpful."
                )
                openConversation(with: defaultBot)
            }
            guard let s2 = activeSession else { return }
            s2.sendMessage(text, attachments: [])
            return
        }
        session.sendMessage(text)
    }

    /// Sends a message to a specific Bot (for inter-Bot messaging).
    func sendMessageTo(_ bot: BotProfile, text: String, attachments: [NSImage] = []) {
        let session = self.session(for: bot)
        session.sendMessage(text, attachments: attachments)
    }

    /// Sets the active Bot.
    func setActiveBot(_ botId: UUID) {
        activeBotId = botId
        if let bot = bots.first(where: { $0.id == botId }) {
            bot.lastActiveAt = Date()
            if let s = sessions[botId] {
                s.unreadActivity = false
            }
        }
        try? modelContext?.save()
    }

    // MARK: - Persistence

    private func saveBot(_ bot: BotProfile) {
        bots.append(bot)
        if let context = modelContext {
            context.insert(bot)
            try? context.save()
        }
    }

    func loadBotsFromDisk() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<BotProfile>()
        do {
            bots = try context.fetch(descriptor)
            for bot in bots {
                if sessions[bot.id] == nil {
                    let session = makeSession(for: bot)
                    session.modelContext = context
                    sessions[bot.id] = session
                } else {
                    sessions[bot.id]?.modelContext = context
                }
            }
        } catch {
            print("⚠️ Failed to load Bots from SwiftData: \(error)")
            bots = []
        }

        if bots.isEmpty {
            let apex = createBot(
                name: "Apex",
                title: "General Assistant",
                descriptionText: "You are Apex, a helpful AI assistant running on this Mac. You can read files, run commands, search the web, and automate tasks. Be concise and helpful.",
                avatarName: "bolt.fill"
            )
            let cos = createBot(
                name: "Chief of Staff",
                title: "Executive Coordinator",
                descriptionText: "You coordinate complex multi-bot workflows, delegate tasks to specialist bots, and synthesize outcomes for the user.",
                avatarName: "person.crop.square.fill"
            )
            cos.isChiefOfStaff = true
            
            _ = createBot(
                name: "Code Architect",
                title: "Senior Engineer",
                descriptionText: "You specialize in code review, architecture planning, debugging, and Swift/macOS development.",
                avatarName: "chevron.left.forwardslash.chevron.right"
            )
            _ = createBot(
                name: "Researcher",
                title: "Deep Research Specialist",
                descriptionText: "You perform web search, technical analysis, documentation lookups, and structured reporting.",
                avatarName: "magnifyingglass"
            )
            _ = createBot(
                name: "Automator",
                title: "macOS System Automator",
                descriptionText: "You run terminal commands, execute AppleScript/Shortcuts, manage files, and automate desktop tasks.",
                avatarName: "terminal.fill"
            )
            try? modelContext?.save()
            activeBotId = apex.id
        }
    }

    func reloadBots() {
        bots.removeAll()
        sessions.removeAll()
        loadBotsFromDisk()
    }

    // MARK: - Computed Accessors

    var allBots: [BotProfile] {
        bots.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            return lhs.lastActiveAt > rhs.lastActiveAt
        }
    }

    var visibleBots: [BotProfile] {
        allBots
    }

    func bot(byId id: UUID) -> BotProfile? {
        bots.first { $0.id == id }
    }

    func botByName(_ name: String) -> BotProfile? {
        bots.first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: - Team Playbook Import / Export

    /// Exports the given bots (or all bots) as a portable TeamPlaybook.
    func exportPlaybook(name: String = "ApexAgent Team", description: String = "", bots subset: [BotProfile]? = nil) -> TeamPlaybook {
        let targets = subset ?? allBots
        let playbookBots = targets.map { bot in
            PlaybookBot(
                name: bot.name,
                title: bot.title,
                description: bot.descriptionText,
                avatarName: bot.avatarName,
                isChiefOfStaff: bot.isChiefOfStaff,
                modelProvider: bot.modelProviderRaw,
                ollamaModel: bot.ollamaModelOverride,
                memory: bot.memory.isEmpty ? nil : bot.memory
            )
        }
        return TeamPlaybook(
            name: name,
            description: description.isEmpty ? "Exported from ApexAgent" : description,
            bots: playbookBots
        )
    }

    /// Imports a TeamPlaybook, creating BotProfiles for each bot definition.
    /// Returns the created profiles. Skips bots whose names already exist.
    @discardableResult
    func importPlaybook(_ playbook: TeamPlaybook) -> [BotProfile] {
        var created: [BotProfile] = []
        for pb in playbook.bots {
            // Skip if a bot with this name already exists
            if botByName(pb.name) != nil { continue }

            let bot = createBot(
                name: pb.name,
                title: pb.title,
                descriptionText: pb.description,
                avatarName: pb.avatarName.isEmpty ? "person.fill" : pb.avatarName
            )
            bot.isChiefOfStaff = pb.isChiefOfStaff
            bot.modelProviderRaw = pb.modelProvider
            bot.ollamaModelOverride = pb.ollamaModel
            if let memory = pb.memory, !memory.isEmpty {
                bot.memory = memory
            }
            try? modelContext?.save()
            created.append(bot)
        }
        return created
    }

    /// Imports a TeamPlaybook from a remote URL (e.g. a GitHub raw URL).
    func importPlaybookFromURL(_ url: URL) async throws -> [BotProfile] {
        let (data, _) = try await URLSession.shared.data(from: url)

        // Try JSON first, then Markdown
        let playbook: TeamPlaybook
        if let jsonPlaybook = try? TeamPlaybook.decode(from: data) {
            playbook = jsonPlaybook
        } else if let markdown = String(data: data, encoding: .utf8) {
            playbook = try TeamPlaybook.decodeFromMarkdown(markdown)
        } else {
            throw NSError(domain: "BotManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not parse playbook from URL."])
        }
        return importPlaybook(playbook)
    }
}
