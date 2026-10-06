import Foundation
import FoundationModels
import SwiftData
import Observation
import AppKit

// MARK: - Space Sync Payloads (Codable / Sendable for LAN & Peer Sync)

public struct SpaceMessagePostPayload: Codable, Sendable {
    public let spaceId: UUID?
    public let channelId: UUID?
    public let senderName: String
    public let senderHandle: String?
    public let content: String
    public let threadParentId: UUID?

    public init(
        spaceId: UUID? = nil,
        channelId: UUID? = nil,
        senderName: String,
        senderHandle: String? = nil,
        content: String,
        threadParentId: UUID? = nil
    ) {
        self.spaceId = spaceId
        self.channelId = channelId
        self.senderName = senderName
        self.senderHandle = senderHandle
        self.content = content
        self.threadParentId = threadParentId
    }
}

public struct SpaceSnapshotDTO: Codable, Sendable {
    public struct ParticipantDTO: Codable, Sendable {
        public let id: String
        public let displayName: String
        public let handle: String
        public let roleTitle: String
        public let kind: String
        public let role: String
        public let presenceState: String
    }

    public struct MessageDTO: Codable, Sendable {
        public let id: String
        public let senderName: String
        public let senderHandle: String
        public let senderKind: String
        public let content: String
        public let timestamp: String
        public let threadParentId: String?
        public let mentionedHandles: [String]
        public let isStreaming: Bool
    }

    public struct ChannelDTO: Codable, Sendable {
        public let id: String
        public let name: String
        public let topic: String
        public let messages: [MessageDTO]
    }

    public struct PageDTO: Codable, Sendable {
        public let id: String
        public let title: String
        public let markdownBody: String
        public let lastEditedByName: String
        public let updatedAt: String
    }

    public let id: String
    public let name: String
    public let summary: String
    public let orchestrationMode: String
    public let inviteURL: String
    public let participants: [ParticipantDTO]
    public let channels: [ChannelDTO]
    public let pages: [PageDTO]
}

// MARK: - SpaceManager

@Observable
@MainActor
public final class SpaceManager {
    public static let shared = SpaceManager()

    // MARK: - Dependencies
    weak var orchestrator: AgentOrchestrator?
    weak var botManager: BotManager?
    public var modelContext: ModelContext?

    // MARK: - State
    public var spaces: [SpaceModel] = []
    public var activeSpaceId: UUID?
    public var activeChannelId: UUID?
    public var activePageId: UUID?
    public var activeThreadParentId: UUID?

    /// Tracks which human identity the local composer is currently posting as (defaults to local owner).
    public var activeLocalHumanParticipantId: UUID?

    /// Per-channel generation state (`channelId -> Bool`).
    public var channelGenerating: [UUID: Bool] = [:]
    /// Per-channel currently speaking bot (`channelId -> BotName`).
    public var activeSpeakerByChannel: [UUID: String] = [:]

    init(orchestrator: AgentOrchestrator? = nil, botManager: BotManager? = nil) {
        self.orchestrator = orchestrator
        self.botManager = botManager
    }

    // MARK: - Computed Properties

    public var activeSpace: SpaceModel? {
        guard let id = activeSpaceId else { return spaces.first }
        return spaces.first { $0.id == id } ?? spaces.first
    }

    public var activeChannel: SpaceChannel? {
        guard let space = activeSpace else { return nil }
        if let chId = activeChannelId,
           let match = space.channels.first(where: { $0.id == chId }) {
            return match
        }
        return space.sortedChannels.first
    }

    public var activePage: SpacePage? {
        guard let space = activeSpace else { return nil }
        if let pId = activePageId,
           let match = space.pages.first(where: { $0.id == pId }) {
            return match
        }
        return space.sortedPages.first
    }

    public var activeHumanSender: SpaceParticipant? {
        guard let space = activeSpace else { return nil }
        if let id = activeLocalHumanParticipantId,
           let found = space.humanParticipants.first(where: { $0.id == id }) {
            return found
        }
        return space.humanParticipants.first(where: { $0.kind == .humanLocal }) ?? space.humanParticipants.first
    }

    // MARK: - Persistence & Seeding

    public func loadSpacesFromDisk() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<SpaceModel>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        do {
            spaces = try context.fetch(descriptor)
        } catch {
            print("⚠️ Failed to fetch Spaces from SwiftData: \(error)")
            spaces = []
        }

        if spaces.isEmpty {
            seedDefaultSpace()
        } else {
            // Ensure any newly created bots in BotManager are synced into the primary Space if desired
            if let first = spaces.first {
                syncBotParticipants(in: first)
                if activeSpaceId == nil {
                    selectSpace(first)
                }
            }
        }
    }

    private func seedDefaultSpace() {
        let hq = createSpace(
            name: "Apex HQ",
            iconName: "sparkles.rectangle.stack.fill",
            summary: "Shared multi-human and multi-agent engineering workspace for collaborating with all Apex bots and teammates.",
            orchestrationMode: .mentionDriven,
            seedDefaults: true
        )
        selectSpace(hq)
    }

    // MARK: - Space CRUD

    @discardableResult
    public func createSpace(
        name: String,
        iconName: String = "person.3.sequence.fill",
        summary: String = "",
        orchestrationMode: SpaceOrchestrationMode = .mentionDriven,
        seedDefaults: Bool = true
    ) -> SpaceModel {
        let space = SpaceModel(
            name: name,
            iconName: iconName,
            summary: summary,
            defaultOrchestrationMode: orchestrationMode
        )

        // Ensure shared workspace directory exists on disk
        try? FileManager.default.createDirectory(
            atPath: space.workspacePath,
            withIntermediateDirectories: true
        )

        if let context = modelContext {
            context.insert(space)
        }
        spaces.append(space)

        if seedDefaults {
            // 1. Add Local Human Owner
            let fullUserName = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
            let humanDisplay = fullUserName.isEmpty ? "Admin" : fullUserName
            let owner = SpaceParticipant(
                displayName: humanDisplay,
                handle: SpaceParticipant.normalizeHandle(NSUserName().isEmpty ? humanDisplay : NSUserName()),
                roleTitle: "Workspace Owner",
                avatarSymbol: "person.crop.circle.fill",
                colorHex: "#4A77E5",
                kind: .humanLocal,
                role: .owner,
                presenceState: .online
            )
            owner.space = space
            space.participants.append(owner)
            if let context = modelContext { context.insert(owner) }
            activeLocalHumanParticipantId = owner.id

            // 2. Sync all Bots from BotManager into Space
            syncBotParticipants(in: space)

            // 3. Create Default Channels
            let general = addChannel(to: space, name: "general", topic: "Team-wide human + agent coordination. Tag @bot or @human, or @all.")
            _ = addChannel(to: space, name: "architecture", topic: "System design, Swift 6.4 concurrency, and code review specs.")
            _ = addChannel(to: space, name: "ship-room", topic: "Release readiness, CI/CD verification, and multi-agent swarms.")

            // 4. Seed Welcome System Message in #general
            let botHandles = space.agentParticipants.map { "@\($0.handle)" }.joined(separator: ", ")
            let welcomeText = """
            Welcome to **\(space.name)** (`#general`)!
            - **Humans & Agents in one room:** Tag any bot (\(botHandles.isEmpty ? "@apex" : botHandles)) or use `@all` / `@agents` to summon the whole squad.
            - **Human-to-Human Awareness:** Tagging another human (e.g. `@teammate`) notifies them without bots interrupting your conversation.
            - **Shared Pages:** Co-edit persistent Markdown specs in the **Pages** drawer on the right.
            """
            let sysMsg = SpaceMessage(
                senderParticipantId: owner.id,
                senderName: "Apex Spaces",
                senderHandle: "system",
                senderKind: .system,
                senderAvatarSymbol: "sparkles",
                content: welcomeText,
                mentionedHandles: []
            )
            sysMsg.channel = general
            general.messages.append(sysMsg)
            if let context = modelContext { context.insert(sysMsg) }

            // 5. Seed Default Shared SpacePage
            _ = createPage(
                in: space,
                title: "Workspace Charter & Shared Context",
                markdownBody: """
                # \(space.name) — Shared Context Page
                
                All humans and AI agents in **\(space.name)** have live read/write access to this page.
                
                ## Active Objectives
                - Coordinate multi-agent tasks alongside human teammates.
                - Keep architectural decisions and sprint notes synchronized here.
                
                ## Working Agreements
                - Mention `@chief-of-staff` for multi-stage delegation.
                - Mention `@code-architect` for Swift 6.4 / macOS 27 implementation reviews.
                - Mention `@researcher` for web & codebase synthesis.
                """,
                authorName: humanDisplay
            )
        }

        saveContext()
        return space
    }

    public func deleteSpace(_ space: SpaceModel) {
        spaces.removeAll { $0.id == space.id }
        if let context = modelContext {
            context.delete(space)
            saveContext()
        }
        if activeSpaceId == space.id {
            if let next = spaces.first {
                selectSpace(next)
            } else {
                activeSpaceId = nil
                activeChannelId = nil
                activePageId = nil
            }
        }
    }

    public func selectSpace(_ space: SpaceModel) {
        activeSpaceId = space.id
        activeChannelId = space.sortedChannels.first?.id
        activePageId = space.sortedPages.first?.id
        activeThreadParentId = nil
        if let localHuman = space.humanParticipants.first {
            activeLocalHumanParticipantId = localHuman.id
        }
        // Deselect 1:1 bot selection so ContentView displays the Space detail view
        botManager?.activeBotId = nil
    }

    public func selectChannel(_ channel: SpaceChannel) {
        if let space = channel.space {
            activeSpaceId = space.id
        }
        activeChannelId = channel.id
        activeThreadParentId = nil
        botManager?.activeBotId = nil
    }

    // MARK: - Channel CRUD

    @discardableResult
    public func addChannel(
        to space: SpaceModel,
        name: String,
        topic: String = "",
        channelType: SpaceChannelType = .chat
    ) -> SpaceChannel {
        let normalized = SpaceChannel.normalizeChannelName(name)
        if let existing = space.channels.first(where: { $0.name == normalized }) {
            return existing
        }
        let channel = SpaceChannel(name: normalized, topic: topic, channelType: channelType)
        channel.space = space
        space.channels.append(channel)
        space.updatedAt = Date()
        if let context = modelContext {
            context.insert(channel)
        }
        saveContext()
        return channel
    }

    public func deleteChannel(_ channel: SpaceChannel) {
        guard let space = channel.space, space.channels.count > 1 else { return }
        space.channels.removeAll { $0.id == channel.id }
        if let context = modelContext {
            context.delete(channel)
            saveContext()
        }
        if activeChannelId == channel.id {
            activeChannelId = space.sortedChannels.first?.id
        }
    }

    // MARK: - Participant CRUD (Humans & Agents)

    public func syncBotParticipants(in space: SpaceModel) {
        guard let bm = botManager else { return }
        let existingBotIds = Set(space.participants.compactMap { $0.botProfileId })
        let palette = ["#9D7DF9", "#3CDC84", "#F1A93C", "#4A77E5", "#EB5757", "#00C7BE"]

        for (index, bot) in bm.allBots.enumerated() where !existingBotIds.contains(bot.id) {
            let p = SpaceParticipant(
                displayName: bot.name,
                handle: SpaceParticipant.normalizeHandle(bot.name),
                roleTitle: bot.title,
                avatarSymbol: bot.avatarName,
                colorHex: palette[index % palette.count],
                kind: .botProfile,
                role: .agentTeammate,
                presenceState: .online,
                botProfileId: bot.id
            )
            p.space = space
            space.participants.append(p)
            if let context = modelContext {
                context.insert(p)
            }
        }
        saveContext()
    }

    @discardableResult
    public func addHumanParticipant(
        to space: SpaceModel,
        displayName: String,
        handle: String? = nil,
        roleTitle: String = "Teammate",
        role: SpaceParticipantRole = .member,
        isRemote: Bool = true
    ) -> SpaceParticipant {
        let cleanHandle = SpaceParticipant.normalizeHandle(handle ?? displayName)
        if let existing = space.humanParticipants.first(where: { $0.handle == cleanHandle }) {
            existing.presenceState = .online
            saveContext()
            return existing
        }
        let participant = SpaceParticipant(
            displayName: displayName,
            handle: cleanHandle,
            roleTitle: roleTitle,
            avatarSymbol: isRemote ? "person.wave.2.fill" : "person.crop.circle.fill",
            colorHex: isRemote ? "#00C7BE" : "#4A77E5",
            kind: isRemote ? .humanRemote : .humanLocal,
            role: role,
            presenceState: .online
        )
        participant.space = space
        space.participants.append(participant)
        space.updatedAt = Date()
        if let context = modelContext {
            context.insert(participant)
        }

        // Post a join notice in #general
        if let general = space.sortedChannels.first {
            let joinMsg = SpaceMessage(
                senderParticipantId: participant.id,
                senderName: "Apex Spaces",
                senderHandle: "system",
                senderKind: .system,
                senderAvatarSymbol: "person.badge.plus",
                content: "**\(participant.displayName)** (`@\(participant.handle)`) joined **\(space.name)** as \(role.badgeLabel)."
            )
            joinMsg.channel = general
            general.messages.append(joinMsg)
            if let context = modelContext { context.insert(joinMsg) }
        }

        saveContext()
        return participant
    }

    @discardableResult
    func addBotParticipant(to space: SpaceModel, bot: BotProfile) -> SpaceParticipant {
        if let existing = space.agentParticipants.first(where: { $0.botProfileId == bot.id }) {
            return existing
        }
        let participant = SpaceParticipant(
            displayName: bot.name,
            handle: SpaceParticipant.normalizeHandle(bot.name),
            roleTitle: bot.title,
            avatarSymbol: bot.avatarName,
            colorHex: "#9D7DF9",
            kind: .botProfile,
            role: .agentTeammate,
            presenceState: .online,
            botProfileId: bot.id
        )
        participant.space = space
        space.participants.append(participant)
        if let context = modelContext {
            context.insert(participant)
        }
        saveContext()
        return participant
    }

    public func removeParticipant(_ participant: SpaceParticipant, from space: SpaceModel) {
        // Prevent removing the last human owner
        if participant.role == .owner && space.humanParticipants.count <= 1 {
            return
        }
        space.participants.removeAll { $0.id == participant.id }
        if let context = modelContext {
            context.delete(participant)
            saveContext()
        }
    }

    public func inviteURL(for space: SpaceModel) -> String {
        CollaborativeServer.ensureCollabToken()
        let token = CollaborativeServer.collabToken()
        let port = CollaborativeServer.shared.port
        let host = Host.current().localizedName ?? "localhost"
        return "http://\(host):\(port)/?spaceId=\(space.id.uuidString)&token=\(token)"
    }

    // MARK: - Shared Pages CRUD

    @discardableResult
    public func createPage(
        in space: SpaceModel,
        title: String,
        markdownBody: String,
        authorName: String = "User"
    ) -> SpacePage {
        let page = SpacePage(
            title: title,
            markdownBody: markdownBody,
            lastEditedByName: authorName
        )
        page.space = space
        space.pages.append(page)
        space.updatedAt = Date()
        if let context = modelContext {
            context.insert(page)
        }
        activePageId = page.id
        saveContext()
        return page
    }

    public func updatePage(_ page: SpacePage, title: String? = nil, markdownBody: String? = nil, editorName: String = "User") {
        if let title { page.title = title }
        if let markdownBody { page.markdownBody = markdownBody }
        page.lastEditedByName = editorName
        page.updatedAt = Date()
        page.space?.updatedAt = Date()
        saveContext()
    }

    public func deletePage(_ page: SpacePage, from space: SpaceModel) {
        space.pages.removeAll { $0.id == page.id }
        if let context = modelContext {
            context.delete(page)
            saveContext()
        }
        if activePageId == page.id {
            activePageId = space.sortedPages.first?.id
        }
    }

    // MARK: - @Mention Parsing & Smart Multi-Human / Multi-Agent Routing

    /// Extracts normalized `@handle` tokens from a message string.
    public nonisolated static func extractMentions(from text: String) -> [String] {
        let pattern = #"(?:^|\s)@([A-Za-z0-9_\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        var results: [String] = []
        for match in matches {
            if match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                let handle = String(text[range]).lowercased()
                if !results.contains(handle) {
                    results.append(handle)
                }
            }
        }
        return results
    }

    /// Matches a list of raw mention handles against available bot profiles in the Space and global BotManager.
    static func matchBots(
        for mentions: [String],
        in space: SpaceModel?,
        botManager: BotManager
    ) -> [BotProfile] {
        var matchedBots: [BotProfile] = []
        for rawHandle in mentions {
            let clean = rawHandle.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")

            // 1. Check Space Agent participants if space is available
            if let space = space {
                for agentParticipant in space.agentParticipants {
                    let pHandle = agentParticipant.handle.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
                    let pDisplay = SpaceParticipant.normalizeHandle(agentParticipant.displayName).replacingOccurrences(of: "-", with: "")
                    if pHandle == clean || pDisplay == clean {
                        if let botId = agentParticipant.botProfileId, let bot = botManager.bot(byId: botId) {
                            if !matchedBots.contains(where: { $0.id == bot.id }) {
                                matchedBots.append(bot)
                            }
                        } else if let bot = botManager.botByName(agentParticipant.displayName) {
                            if !matchedBots.contains(where: { $0.id == bot.id }) {
                                matchedBots.append(bot)
                            }
                        }
                    }
                }
            }

            // 2. Check all bots in BotManager
            for bot in botManager.allBots {
                let bHandle = SpaceParticipant.normalizeHandle(bot.name).replacingOccurrences(of: "-", with: "")
                let bName = bot.name.lowercased().replacingOccurrences(of: " ", with: "")
                if bHandle == clean || bName == clean || bot.name.lowercased() == rawHandle.lowercased() {
                    if !matchedBots.contains(where: { $0.id == bot.id }) {
                        matchedBots.append(bot)
                    }
                }
            }
        }
        return matchedBots
    }

    /// Determines which `BotProfile`s in the Space should respond to a newly posted message.
    /// Crucial multi-human rule: if a human explicitly tags another human (`@humanHandle`) and does NOT tag any bot,
    /// bots remain silent so humans can converse directly without unsolicited AI interruption.
    func resolveTargetBots(
        for text: String,
        in space: SpaceModel,
        channel: SpaceChannel,
        senderKind: SpaceSenderKind
    ) -> [BotProfile] {
        guard let bm = botManager else { return [] }

        let spaceBots: [BotProfile] = space.agentParticipants.compactMap { participant in
            if let botId = participant.botProfileId, let bot = bm.bot(byId: botId) {
                return bot
            }
            return bm.botByName(participant.displayName)
        }
        guard !spaceBots.isEmpty || !bm.allBots.isEmpty else { return [] }

        let mentions = Self.extractMentions(from: text)

        // If the sender is a bot, only trigger target bots if explicit bot mentions or broadcast tokens are present
        if senderKind == .bot {
            guard !mentions.isEmpty else { return [] }
            let broadcastTokens: Set<String> = ["all", "agents", "bots", "channel", "everyone", "team"]
            if !mentions.filter({ broadcastTokens.contains($0) }).isEmpty {
                return spaceBots
            }
            return Self.matchBots(for: mentions, in: space, botManager: bm)
        }

        // 1. Check broadcast mentions (@all, @agents, @channel, @everyone)
        let broadcastTokens: Set<String> = ["all", "agents", "bots", "channel", "everyone", "team"]
        if !mentions.filter({ broadcastTokens.contains($0) }).isEmpty {
            return !spaceBots.isEmpty ? spaceBots : bm.allBots
        }

        // 2. Match explicit @bot handles or bot names
        let matchedBots = Self.matchBots(for: mentions, in: space, botManager: bm)
        if !matchedBots.isEmpty {
            return matchedBots
        }

        // 3. Check if the message explicitly mentioned a Human participant (and no bots)
        let mentionedHumans = mentions.filter { handle in
            space.humanParticipants.contains { $0.handle.lowercased() == handle }
        }
        if !mentionedHumans.isEmpty {
            // Human-to-human message: bots stay passive listeners!
            return []
        }

        // 4. Fallback to the Space's configured Orchestration Mode when no @mentions are present
        switch space.orchestrationMode {
        case .mentionDriven:
            // In @Mention Driven mode: if there are multiple humans in the Space and no @mention was used,
            // only respond if the message is a direct question or command; if solo human, route to Chief of Staff / Lead Bot.
            if space.humanParticipants.count > 1 && !text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
                return []
            }
            if let cos = spaceBots.first(where: { $0.isChiefOfStaff }) {
                return [cos]
            }
            return spaceBots.isEmpty ? [] : [spaceBots[0]]

        case .chiefOfStaffModerated:
            if let cos = spaceBots.first(where: { $0.isChiefOfStaff }) {
                return [cos]
            }
            return spaceBots.isEmpty ? [] : [spaceBots[0]]

        case .roundRobin:
            return spaceBots

        case .parallelSwarm:
            return spaceBots
        }
    }

    // MARK: - Posting Messages & Running Multi-Agent Turns

    @discardableResult
    public func postHumanMessage(
        _ content: String,
        in channel: SpaceChannel? = nil,
        sender: SpaceParticipant? = nil,
        threadParentId: UUID? = nil,
        triggerAgents: Bool = true
    ) -> SpaceMessage? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let targetChannel = channel ?? activeChannel,
              let space = targetChannel.space ?? activeSpace else { return nil }

        let resolvedSender = sender ?? activeHumanSender ?? addHumanParticipant(
            to: space,
            displayName: NSFullUserName().isEmpty ? "User" : NSFullUserName(),
            isRemote: false
        )

        let mentions = Self.extractMentions(from: trimmed)
        let msg = SpaceMessage(
            senderParticipantId: resolvedSender.id,
            senderName: resolvedSender.displayName,
            senderHandle: resolvedSender.handle,
            senderKind: .human,
            senderAvatarSymbol: resolvedSender.avatarSymbol,
            content: trimmed,
            threadParentId: threadParentId ?? activeThreadParentId,
            mentionedHandles: mentions
        )
        msg.channel = targetChannel
        targetChannel.messages.append(msg)
        targetChannel.updatedAt = Date()
        space.updatedAt = Date()

        if let context = modelContext {
            context.insert(msg)
        }
        saveContext()

        if BuiltinSlashCommandEngine.isSlashCommand(trimmed) {
            Task { @MainActor in
                if let orch = self.orchestrator {
                    if let res = await BuiltinSlashCommandEngine.shared.execute(
                        input: trimmed,
                        orchestrator: orch,
                        botManager: self.botManager,
                        spaceManager: self
                    ) {
                        let sysMsg = SpaceMessage(
                            senderParticipantId: resolvedSender.id,
                            senderName: "System",
                            senderHandle: "system",
                            senderKind: .system,
                            senderAvatarSymbol: "bolt.shield.fill",
                            content: res.outputMarkdown,
                            threadParentId: threadParentId ?? self.activeThreadParentId
                        )
                        sysMsg.channel = targetChannel
                        targetChannel.messages.append(sysMsg)
                        targetChannel.updatedAt = Date()
                        space.updatedAt = Date()
                        if let context = self.modelContext {
                            context.insert(sysMsg)
                        }
                        self.saveContext()
                    }
                }
            }
            return msg
        }

        if triggerAgents {
            let targetBots = resolveTargetBots(
                for: trimmed,
                in: space,
                channel: targetChannel,
                senderKind: .human
            )
            if !targetBots.isEmpty {
                Task { @MainActor in
                    await dispatchBotTurns(
                        bots: targetBots,
                        in: space,
                        channel: targetChannel,
                        triggerMessage: msg,
                        parallel: space.orchestrationMode == .parallelSwarm && targetBots.count > 1
                    )
                }
            }
        }

        return msg
    }

    /// Handles an incoming message from a remote human peer (via `CollaborativeServer` or `ApexGatewayServer`).
    @discardableResult
    public func receiveRemoteHumanMessage(_ payload: SpaceMessagePostPayload) -> SpaceMessage? {
        let targetSpace: SpaceModel?
        if let sId = payload.spaceId {
            targetSpace = spaces.first(where: { $0.id == sId }) ?? activeSpace
        } else {
            targetSpace = activeSpace
        }
        guard let space = targetSpace else { return nil }

        let targetChannel: SpaceChannel?
        if let cId = payload.channelId {
            targetChannel = space.channels.first(where: { $0.id == cId }) ?? space.sortedChannels.first
        } else {
            targetChannel = space.sortedChannels.first
        }
        guard let channel = targetChannel else { return nil }

        let participant = addHumanParticipant(
            to: space,
            displayName: payload.senderName,
            handle: payload.senderHandle,
            roleTitle: "Remote Collaborator",
            role: .member,
            isRemote: true
        )

        return postHumanMessage(
            payload.content,
            in: channel,
            sender: participant,
            threadParentId: payload.threadParentId,
            triggerAgents: true
        )
    }

    public func cancelChannelGeneration(channelId: UUID) {
        channelGenerating[channelId] = false
        activeSpeakerByChannel[channelId] = nil
        if let bm = botManager {
            for bot in bm.bots {
                bm.session(for: bot).cancelGeneration()
            }
        }
        orchestrator?.cancelGeneration()
    }

    func dispatchBotTurns(
        bots: [BotProfile],
        in space: SpaceModel,
        channel: SpaceChannel,
        triggerMessage: SpaceMessage,
        parallel: Bool
    ) async {
        let channelId = channel.id
        let threadParentId = triggerMessage.threadParentId

        guard channelGenerating[channelId] != true else { return }

        channelGenerating[channelId] = true
        defer {
            channelGenerating[channelId] = false
            activeSpeakerByChannel[channelId] = nil
        }

        var queue: [BotProfile] = bots
        var visitedInTurnChain: Set<UUID> = []
        var chainDepth = 0
        let maxChainDepth = 5

        while !queue.isEmpty && chainDepth < maxChainDepth {
            guard channelGenerating[channelId] == true else { break }
            chainDepth += 1

            if parallel && chainDepth == 1 {
                let currentBatch = queue
                queue.removeAll()
                for bot in currentBatch {
                    visitedInTurnChain.insert(bot.id)
                }
                for bot in currentBatch {
                    let generatedMessage = await runSingleBotTurn(
                        bot: bot,
                        in: space,
                        channel: channel,
                        threadParentId: threadParentId
                    )
                    if let msg = generatedMessage, !msg.content.isEmpty {
                        let newlyMentioned = resolveTargetBots(
                            for: msg.content,
                            in: space,
                            channel: channel,
                            senderKind: .bot
                        )
                        for newlyBot in newlyMentioned {
                            if newlyBot.id != bot.id && !queue.contains(where: { $0.id == newlyBot.id }) && visitedInTurnChain.count < 6 {
                                if !space.agentParticipants.contains(where: { $0.botProfileId == newlyBot.id }) {
                                    _ = addBotParticipant(to: space, bot: newlyBot)
                                }
                                queue.append(newlyBot)
                            }
                        }
                    }
                }
            } else {
                let bot = queue.removeFirst()
                visitedInTurnChain.insert(bot.id)

                let generatedMessage = await runSingleBotTurn(
                    bot: bot,
                    in: space,
                    channel: channel,
                    threadParentId: threadParentId
                )

                // Detect recursive @mentions in the bot's generated response and pull them in dynamically!
                if let msg = generatedMessage, !msg.content.isEmpty {
                    let newlyMentioned = resolveTargetBots(
                        for: msg.content,
                        in: space,
                        channel: channel,
                        senderKind: .bot
                    )
                    for newlyBot in newlyMentioned {
                        // Avoid immediate self-mention cycle and bound turn depth
                        if newlyBot.id != bot.id && !queue.contains(where: { $0.id == newlyBot.id }) && visitedInTurnChain.count < 6 {
                            if !space.agentParticipants.contains(where: { $0.botProfileId == newlyBot.id }) {
                                _ = addBotParticipant(to: space, bot: newlyBot)
                            }
                            queue.append(newlyBot)
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    private func runSingleBotTurn(
        bot: BotProfile,
        in space: SpaceModel,
        channel: SpaceChannel,
        threadParentId: UUID?
    ) async -> SpaceMessage? {
        guard let bm = botManager,
              let orchestrator = orchestrator ?? bm.orchestrator else { return nil }

        let botSession = bm.session(for: bot)
        botSession.isGenerating = true
        defer { botSession.isGenerating = false }
        botSession.resetSession()
        let botParticipant = space.agentParticipants.first(where: { $0.botProfileId == bot.id })
            ?? addBotParticipant(to: space, bot: bot)

        botParticipant.presenceState = .generating
        activeSpeakerByChannel[channel.id] = bot.name

        let promptContext = buildSpacePromptContext(for: bot, in: space, channel: channel, threadParentId: threadParentId)

        let placeholder = SpaceMessage(
            senderParticipantId: botParticipant.id,
            senderName: bot.name,
            senderHandle: botParticipant.handle,
            senderKind: .bot,
            senderAvatarSymbol: bot.avatarName,
            content: "Thinking...",
            threadParentId: threadParentId,
            isStreaming: true
        )
        placeholder.channel = channel
        channel.messages.append(placeholder)
        if let context = modelContext {
            context.insert(placeholder)
        }
        let placeholderId = placeholder.id
        let spaceId = space.id
        let channelId = channel.id

        let toolMode: AgentToolCallingMode = switch botSession.toolCallingMode {
        case .auto: .auto
        case .required: .required
        case .disabled: .disabled
        }

        let isDirectMention = Self.isDirectlyMentioned(in: channel, by: bot, threadParentId: threadParentId)

        let request = AgentRequest(
            conversationId: channel.id,
            senderIdentity: .bot(id: bot.id, name: bot.name),
            prompt: promptContext,
            // Gate tools on the human's actual message, not the transcript
            // scaffold — the scaffold always contains delegation vocabulary.
            intentText: Self.originatingHumanMessage(in: channel, threadParentId: threadParentId)
                ?? promptContext,
            isDirectMention: isDirectMention,
            toolCallingMode: toolMode
        )

        var instructions = bot.systemInstructions + "\n\n" + buildSpaceSystemInstructions(for: bot, in: space, channel: channel)
        instructions = AgentRequestRouter.applyingDirectAddressPolicy(
            base: instructions,
            isDirectMention: isDirectMention
        )

        let terminalState = await AgentRequestRouter.shared.route(
            request,
            bot: bot,
            session: botSession.session,
            history: [],
            instructions: instructions,
            orchestrator: orchestrator,
            onUpdate: { [weak self] partial in
                let redacted = SecretRedactor.redact(text: partial)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let sp = self.spaces.first(where: { $0.id == spaceId }),
                       let ch = sp.channels.first(where: { $0.id == channelId }),
                       let msg = ch.messages.first(where: { $0.id == placeholderId }) {
                        msg.content = redacted
                    }
                }
            }
        )

        // Allow queued MainActor streaming updates to flush
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        if !terminalState.isSuccess || placeholder.content == "Thinking..." || placeholder.content.isEmpty {
            let fallbackMsg = terminalState.userFacingMessage
            if !fallbackMsg.isEmpty {
                placeholder.content = fallbackMsg
            }
        }
        placeholder.isStreaming = false
        placeholder.mentionedHandles = Self.extractMentions(from: placeholder.content)
        botParticipant.presenceState = .online
        channel.updatedAt = Date()
        space.updatedAt = Date()
        saveContext()
        return placeholder
    }

    /// Broadcast handles that address every agent in the Space.
    public static let broadcastHandles: Set<String> = [
        "all", "agents", "bots", "channel", "everyone", "team"
    ]

    /// The messages that form this turn's context, in display order.
    private static func relevantMessages(
        in channel: SpaceChannel,
        threadParentId: UUID?
    ) -> [SpaceMessage] {
        if let parentId = threadParentId,
           let parent = channel.messages.first(where: { $0.id == parentId }) {
            return ([parent] + channel.threadReplies(for: parentId)).suffix(20).map { $0 }
        }
        return Array(channel.rootMessages.suffix(20))
    }

    /// The most recent human message in this turn's context — the utterance that
    /// actually drove the turn. Used for tool-intent gating so transcript
    /// boilerplate cannot fabricate tool intent.
    static func originatingHumanMessage(in channel: SpaceChannel, threadParentId: UUID?) -> String? {
        relevantMessages(in: channel, threadParentId: threadParentId)
            .last(where: { $0.senderKind == .human && !$0.isStreaming })?
            .content
    }

    /// True when a human explicitly @mentioned this bot (or broadcast to
    /// everyone) in the message that triggered this turn. Broadcast counts: the
    /// human is still directly addressing the agents.
    static func isDirectlyMentioned(
        in channel: SpaceChannel,
        by bot: BotProfile,
        threadParentId: UUID?
    ) -> Bool {
        let messages = relevantMessages(in: channel, threadParentId: threadParentId)
        guard let trigger = messages.last(where: { $0.senderKind == .human && !$0.isStreaming }) else {
            return false
        }
        let mentions = trigger.mentionedHandles.isEmpty
            ? extractMentions(from: trigger.content)
            : trigger.mentionedHandles
        guard !mentions.isEmpty else { return false }

        let botHandle = SpaceParticipant.normalizeHandle(bot.name)
            .replacingOccurrences(of: "-", with: "")
        let botName = bot.name.lowercased().replacingOccurrences(of: " ", with: "")

        return mentions.contains { raw in
            let handle = raw.lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
            return handle == botHandle
                || handle == botName
                || broadcastHandles.contains(handle)
        }
    }

    func buildSpaceSystemInstructions(for bot: BotProfile, in space: SpaceModel, channel: SpaceChannel) -> String {
        let humans = space.humanParticipants.map { "\($0.displayName) (@\($0.handle))" }.joined(separator: ", ")
        let agents = space.agentParticipants.map { "\($0.displayName) (@\($0.handle) — \($0.roleTitle))" }.joined(separator: ", ")
        let pageSummary = space.sortedPages.prefix(3).map { "- \($0.title): \($0.markdownBody.prefix(240))" }.joined(separator: "\n")

        return """
        === APEX SPACE CONTEXT ===
        Space Name: \(space.name) (\(space.summary))
        Current Channel: #\(channel.name) (\(channel.topic))
        Shared Workspace Path: \(space.workspacePath)
        Human Teammates Present: \(humans.isEmpty ? "None" : humans)
        AI Agent Teammates Present: \(agents.isEmpty ? "None" : agents)
        Shared Space Pages:
        \(pageSummary.isEmpty ? "None" : pageSummary)

        Collaboration Rules for \(bot.name):
        1. You are in a shared multiplayer Space ('\(space.name)') with both humans and specialist AI agents.
        2. Address the specific human or agent who spoke last, and stay concise and actionable.
        3. Do the requested work yourself with your own tools. Do NOT reply with a plan to delegate, and do NOT hand the task back to the human. Delegation tools are withheld from you when you are directly @mentioned.
        4. Only tag another teammate with @handle when a genuinely different specialty is required — and then still deliver your own part of the answer.
        """
    }

    func buildSpacePromptContext(
        for bot: BotProfile,
        in space: SpaceModel,
        channel: SpaceChannel,
        threadParentId: UUID?
    ) -> String {
        let relevantMessages = Self.relevantMessages(in: channel, threadParentId: threadParentId)

        var transcript = buildSpaceSystemInstructions(for: bot, in: space, channel: channel) + "\n\n"
        transcript += "Recent conversation in #\(channel.name):\n\n"
        for msg in relevantMessages where !msg.isStreaming {
            let tag = msg.senderKind == .human ? "HUMAN" : (msg.senderKind == .bot ? "AGENT" : "SYSTEM")
            transcript += "[\(tag) • \(msg.senderName) (@\(msg.senderHandle))]: \(msg.content)\n\n"
        }

        // Memory & Turn Priority injection
        if let lastMsg = relevantMessages.last, lastMsg.senderName != bot.name {
            let mentions = lastMsg.mentionedHandles
            let cleanBotName = SpaceParticipant.normalizeHandle(bot.name).replacingOccurrences(of: "-", with: "")
            let isMentioned = mentions.contains(where: {
                let mClean = $0.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
                return mClean == cleanBotName || mClean == "all" || mClean == "agents" || mClean == "bots" || mClean == "everyone" || mClean == "team"
            })
            if isMentioned {
                transcript += "⚡️ [TURN PRIORITY]: You (@\(SpaceParticipant.normalizeHandle(bot.name))) were explicitly mentioned by \(lastMsg.senderName). Address their request directly.\n\n"
            }
        }

        transcript += "Respond now as \(bot.name) (@\(SpaceParticipant.normalizeHandle(bot.name)))."
        return transcript
    }

    // MARK: - JSON Serialization for CollaborativeServer / Multi-Human Web & Peer Clients

    public func exportSpacesSnapshot() -> [SpaceSnapshotDTO] {
        let iso = ISO8601DateFormatter()
        return spaces.map { space in
            SpaceSnapshotDTO(
                id: space.id.uuidString,
                name: space.name,
                summary: space.summary,
                orchestrationMode: space.orchestrationMode.rawValue,
                inviteURL: inviteURL(for: space),
                participants: space.participants.map { p in
                    SpaceSnapshotDTO.ParticipantDTO(
                        id: p.id.uuidString,
                        displayName: p.displayName,
                        handle: p.handle,
                        roleTitle: p.roleTitle,
                        kind: p.kind.rawValue,
                        role: p.role.rawValue,
                        presenceState: p.presenceState.rawValue
                    )
                },
                channels: space.sortedChannels.map { ch in
                    SpaceSnapshotDTO.ChannelDTO(
                        id: ch.id.uuidString,
                        name: ch.name,
                        topic: ch.topic,
                        messages: ch.rootMessages.suffix(50).map { m in
                            SpaceSnapshotDTO.MessageDTO(
                                id: m.id.uuidString,
                                senderName: m.senderName,
                                senderHandle: m.senderHandle,
                                senderKind: m.senderKind.rawValue,
                                content: m.content,
                                timestamp: iso.string(from: m.timestamp),
                                threadParentId: m.threadParentId?.uuidString,
                                mentionedHandles: m.mentionedHandles,
                                isStreaming: m.isStreaming
                            )
                        }
                    )
                },
                pages: space.sortedPages.map { pg in
                    SpaceSnapshotDTO.PageDTO(
                        id: pg.id.uuidString,
                        title: pg.title,
                        markdownBody: pg.markdownBody,
                        lastEditedByName: pg.lastEditedByName,
                        updatedAt: iso.string(from: pg.updatedAt)
                    )
                }
            )
        }
    }

    public func exportSpacesSnapshotJSON() -> String {
        let snapshots = exportSpacesSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshots),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    public func exportSpaceAsMarkdown(spaceId: UUID) -> String? {
        guard let space = spaces.first(where: { $0.id == spaceId }) else { return nil }
        var md = "# Space: \(space.name)\n\n"
        if !space.summary.isEmpty {
            md += "> \(space.summary)\n\n"
        }
        md += "- **Orchestration Mode**: \(space.orchestrationMode.displayName)\n"
        md += "- **Created**: \(space.createdAt.formatted())\n\n"

        // Participants Table
        md += "## Participants (\(space.participants.count))\n\n"
        md += "| Name | Handle | Kind | Role | Status |\n"
        md += "|---|---|---|---|---|\n"
        for p in space.participants {
            md += "| **\(p.displayName)** | `@\(p.handle)` | `\(p.kind.rawValue)` | `\(p.role.badgeLabel)` | `\(p.presenceState.rawValue)` |\n"
        }
        md += "\n"

        // Channels & Messages
        md += "## Channels (\(space.channels.count))\n\n"
        for channel in space.channels {
            md += "### #\(channel.name)\n\n"
            if !channel.topic.isEmpty {
                md += "*Topic: \(channel.topic)*\n\n"
            }
            let rootMessages = channel.rootMessages
            if rootMessages.isEmpty {
                md += "_No messages in this channel._\n\n"
            } else {
                for msg in rootMessages {
                    let kindTag = msg.senderKind == .human ? "[HUMAN]" : (msg.senderKind == .bot ? "[AGENT]" : "[SYSTEM]")
                    md += "- **\(msg.senderName)** (`@\(msg.senderHandle)`) \(kindTag) — *\(msg.timestamp.formatted())*:\n"
                    md += "  > \(msg.content.replacingOccurrences(of: "\n", with: "\n  > "))\n\n"

                    let replies = channel.threadReplies(for: msg.id)
                    for reply in replies {
                        let replyKindTag = reply.senderKind == .human ? "[HUMAN]" : (reply.senderKind == .bot ? "[AGENT]" : "[SYSTEM]")
                        md += "  - ↳ **\(reply.senderName)** (`@\(reply.senderHandle)`) \(replyKindTag) — *\(reply.timestamp.formatted())*:\n"
                        md += "    > \(reply.content.replacingOccurrences(of: "\n", with: "\n    > "))\n\n"
                    }
                }
            }
        }

        // Shared Pages
        if !space.pages.isEmpty {
            md += "## Shared Pages (\(space.pages.count))\n\n"
            for page in space.pages {
                md += "### Page: \(page.title)\n\n"
                md += "*Last edited by \(page.lastEditedByName) on \(page.updatedAt.formatted())*\n\n"
                md += "\(page.markdownBody)\n\n---\n\n"
            }
        }

        return md
    }

    private func saveContext() {
        guard let context = modelContext else { return }
        try? context.save()
    }

    // MARK: - Markdown Workspaces Roster

    public func exportSpacesRosterMarkdown() -> String {
        guard !spaces.isEmpty else {
            return "No shared workspaces registered in SpaceManager."
        }

        var md = "### 🌌 Shared Workspaces Roster (\(spaces.count) active)\n\n"
        md += "| Workspace Name | Orchestration Mode | Channels | Participants | Pages |\n"
        md += "|---|---|---|---|---|\n"

        for space in spaces {
            let mode = space.orchestrationMode.displayName
            let chCount = space.channels.count
            let pCount = space.participants.count
            let pgCount = space.pages.count
            let safeName = space.name.replacingOccurrences(of: "|", with: "\\|")
            md += "| **\(safeName)** | `\(mode)` | `\(chCount)` | `\(pCount)` | `\(pgCount)` |\n"
        }
        return md
    }

}