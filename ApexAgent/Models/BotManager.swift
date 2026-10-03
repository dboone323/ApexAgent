import Foundation
import SwiftData
import Observation

// MARK: - BotManager: Coordinates the roster of Bots and their sessions

/// `BotManager` is the single source of truth for all `BotProfile` instances.
/// It owns their durable state, maps each Bot to a live `BotSession`, and
/// provides reactive accessors for the sidebar and detail views.
@Observable
@MainActor
final class BotManager {
    // MARK: - Injected Dependencies
    var modelContext: ModelContext?
    weak var orchestrator: AgentOrchestrator?
    weak var computer: Computer?

    // MARK: - Durable State
    private(set) var bots: [BotProfile] = []

    // MARK: - Transient State
    private(set) var sessions: [UUID: BotSession] = [:]
    var activeBotId: UUID?
    var activePlaybookRunner: PlaybookRunner?

    public var activeBot: BotProfile? {
        guard let id = activeBotId else { return nil }
        return bot(byId: id)
    }

    public var activeSession: BotSession? {
        guard let bot = activeBot else { return nil }
        return session(for: bot)
    }

    func isGenerating(botId: UUID) -> Bool {
        sessions[botId]?.isGenerating ?? false
    }

    func setActiveBot(_ id: UUID) {
        activeBotId = id
        if let bot = bot(byId: id) {
            touchBot(bot)
        }
    }

    func openConversation(with bot: BotProfile) {
        activeBotId = bot.id
        touchBot(bot)
    }

    @discardableResult
    func resolvePlaybookApproval(approved: Bool, notes: String? = nil) -> Bool {
        guard let runner = activePlaybookRunner else { return false }
        if approved {
            runner.approvePendingStage(notes: notes)
        } else {
            runner.rejectPendingStage(reason: notes ?? "Rejected by user")
        }
        return true
    }

    // MARK: - Peer-to-Peer Approval State (WS4)
    /// Tracks bounded peer-to-peer approvals (grants, pending requests, audit logs).
    /// Kept in memory; grants can be persisted into bot descriptions/memory when permanent.
    let peerApprovals = PeerApprovalCoordinator()

    // MARK: - Init
    init(modelContext: ModelContext? = nil, orchestrator: AgentOrchestrator? = nil, computer: Computer? = nil) {
        self.modelContext = modelContext
        self.orchestrator = orchestrator
        self.computer = computer
        loadBotsFromDisk()
    }

    // MARK: - Session Mapping

    /// Returns the live `BotSession` for the given Bot, creating one if needed.
    func session(for bot: BotProfile) -> BotSession {
        if let existing = sessions[bot.id] {
            return existing
        }
        let session = makeSession(for: bot)
        sessions[bot.id] = session
        return session
    }

    /// Accessor by UUID (convenience)
    func session(forBotId id: UUID) -> BotSession? {
        guard let bot = bots.first(where: { $0.id == id }) else { return nil }
        return session(for: bot)
    }

    private func makeSession(for bot: BotProfile) -> BotSession {
        let orch = orchestrator ?? AgentOrchestrator()
        let comp = computer ?? Computer()
        let s = BotSession(bot: bot, orchestrator: orch, computer: comp)
        s.modelContext = modelContext
        s.botManager = self
        s.loadConversationFromDisk()
        return s
    }

    // MARK: - Peer Approval Governance (WS4)

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
        _ = peerApprovals.expireStale()
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

    /// Updates a Bot's mutable fields and persists.
    func updateBot(
        _ bot: BotProfile,
        name: String? = nil,
        title: String? = nil,
        descriptionText: String? = nil,
        avatarName: String? = nil,
        modelProvider: ModelProvider? = nil,
        ollamaModelOverride: String? = nil,
        memory: String? = nil,
        allowedTools: [String]? = nil,
        allowedMCPServers: [String]? = nil
    ) {
        if let name { bot.name = name }
        if let title { bot.title = title }
        if let descriptionText { bot.descriptionText = descriptionText }
        if let avatarName { bot.avatarName = avatarName }
        if let modelProvider { bot.modelProvider = modelProvider }
        if let ollamaModelOverride { bot.ollamaModelOverride = ollamaModelOverride }
        if let memory { bot.memory = memory }
        if let allowedTools { bot.allowedToolNames = allowedTools }
        if let allowedMCPServers { bot.allowedMCPServers = allowedMCPServers }
        bot.updatedAt = Date()
        saveBot(bot)
    }

    func editBot(
        _ bot: BotProfile,
        name: String? = nil,
        title: String? = nil,
        descriptionText: String? = nil,
        avatarName: String? = nil,
        modelProvider: ModelProvider? = nil,
        ollamaModelOverride: String? = nil,
        memory: String? = nil,
        allowedTools: [String]? = nil,
        allowedMCPServers: [String]? = nil
    ) {
        updateBot(
            bot,
            name: name,
            title: title,
            descriptionText: descriptionText,
            avatarName: avatarName,
            modelProvider: modelProvider,
            ollamaModelOverride: ollamaModelOverride,
            memory: memory,
            allowedTools: allowedTools,
            allowedMCPServers: allowedMCPServers
        )
    }

    /// Deletes a Bot and cleans up its session and saved conversation.
    func deleteBot(_ bot: BotProfile) {
        let id = bot.id
        bots.removeAll { $0.id == id }
        sessions[id]?.reset()
        sessions.removeValue(forKey: id)
        if activeBotId == id {
            activeBotId = bots.first?.id
        }
        if let context = modelContext {
            context.delete(bot)
            try? context.save()
        }
    }

    /// Pins or unpins a Bot.
    func togglePin(_ bot: BotProfile) {
        bot.isPinned.toggle()
        saveBot(bot)
    }

    /// Touches a Bot's `lastActiveAt` to sort it higher in the list.
    func touchBot(_ bot: BotProfile) {
        bot.lastActiveAt = Date()
        saveBot(bot)
    }

    // MARK: - Persistence (SwiftData)

    func saveBot(_ bot: BotProfile) {
        if !bots.contains(where: { $0.id == bot.id }) {
            bots.append(bot)
        }
        if let context = modelContext {
            context.insert(bot)
            try? context.save()
        }
    }

    func loadBotsFromDisk() {
        guard let context = modelContext else {
            bots = []
            return
        }

        let descriptor = FetchDescriptor<BotProfile>(
            sortBy: [SortDescriptor(\.lastActiveAt, order: .reverse)]
        )

        do {
            bots = try context.fetch(descriptor)
            for bot in bots {
                if sessions[bot.id] == nil {
                    let session = makeSession(for: bot)
                    sessions[bot.id] = session
                } else {
                    sessions[bot.id]?.modelContext = context
                    sessions[bot.id]?.loadConversationFromDisk()
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
            apex.ollamaModelOverride = ModelRegistry.defaultFastOllamaModel

            let cos = createBot(
                name: "Chief of Staff",
                title: "Executive Coordinator",
                descriptionText: "You coordinate complex multi-bot workflows, delegate tasks to specialist bots, and synthesize outcomes for the user.",
                avatarName: "person.crop.square.fill"
            )
            cos.isChiefOfStaff = true
            cos.ollamaModelOverride = ModelRegistry.defaultFastOllamaModel
            
            let arch = createBot(
                name: "Code Architect",
                title: "Senior Engineer",
                descriptionText: "You specialize in code review, architecture planning, debugging, and Swift/macOS development.",
                avatarName: "chevron.left.forwardslash.chevron.right"
            )
            arch.ollamaModelOverride = ModelRegistry.defaultCodingOllamaModel

            let res = createBot(
                name: "Researcher",
                title: "Deep Research Specialist",
                descriptionText: "You perform web search, technical analysis, documentation lookups, and structured reporting.",
                avatarName: "magnifyingglass"
            )
            res.ollamaModelOverride = ModelRegistry.defaultResearchOllamaModel

            let auto = createBot(
                name: "Automator",
                title: "macOS System Automator",
                descriptionText: "You run terminal commands, execute AppleScript/Shortcuts, manage files, and automate desktop tasks.",
                avatarName: "terminal.fill"
            )
            auto.ollamaModelOverride = ModelRegistry.defaultAutomationOllamaModel

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
            saveBot(bot)
            created.append(bot)
        }
        return created
    }

    /// Fetches a TeamPlaybook from a remote URL (JSON or Markdown) and imports its bots.
    @discardableResult
    func importPlaybookFromURL(_ url: URL) async throws -> [BotProfile] {
        let (data, _) = try await URLSession.shared.data(from: url)
        if let playbook = try? TeamPlaybook.decode(from: data) {
            return importPlaybook(playbook)
        } else if let str = String(data: data, encoding: .utf8),
                  let playbook = try? TeamPlaybook.decodeFromMarkdown(str) {
            return importPlaybook(playbook)
        } else {
            throw NSError(
                domain: "BotManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unrecognized playbook format at \(url.absoluteString)"]
            )
        }
    }
}
