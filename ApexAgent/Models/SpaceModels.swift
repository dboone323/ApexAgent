import Foundation
import SwiftData

// MARK: - Space Enums

public enum SpaceOrchestrationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case mentionDriven = "mention_driven"
    case chiefOfStaffModerated = "chief_of_staff"
    case roundRobin = "round_robin"
    case parallelSwarm = "parallel_swarm"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mentionDriven: return "@Mention Driven"
        case .chiefOfStaffModerated: return "Chief of Staff"
        case .roundRobin: return "Round-Robin"
        case .parallelSwarm: return "Parallel Swarm"
        }
    }

    public var symbolName: String {
        switch self {
        case .mentionDriven: return "at"
        case .chiefOfStaffModerated: return "person.crop.square.fill"
        case .roundRobin: return "arrow.triangle.2.circlepath"
        case .parallelSwarm: return "sparkles.rectangle.stack.fill"
        }
    }
}

public enum SpaceParticipantKind: String, Codable, CaseIterable, Sendable {
    case humanLocal = "human_local"
    case humanRemote = "human_remote"
    case botProfile = "bot_profile"
    case remoteA2AAgent = "remote_a2a"

    public var isHuman: Bool {
        self == .humanLocal || self == .humanRemote
    }

    public var isAgent: Bool {
        self == .botProfile || self == .remoteA2AAgent
    }
}

public enum SpaceParticipantRole: String, Codable, CaseIterable, Sendable {
    case owner = "owner"
    case admin = "admin"
    case member = "member"
    case guest = "guest"
    case agentTeammate = "agent_teammate"

    public var badgeLabel: String {
        switch self {
        case .owner: return "OWNER"
        case .admin: return "ADMIN"
        case .member: return "HUMAN"
        case .guest: return "GUEST"
        case .agentTeammate: return "AGENT"
        }
    }
}

public enum SpacePresenceState: String, Codable, CaseIterable, Sendable {
    case online = "online"
    case idle = "idle"
    case generating = "generating"
    case offline = "offline"
}

public enum SpaceChannelType: String, Codable, CaseIterable, Sendable {
    case chat = "chat"
    case playbookRun = "playbook_run"
    case debateRoom = "debate_room"
}

public enum SpaceSenderKind: String, Codable, CaseIterable, Sendable {
    case human = "human"
    case bot = "bot"
    case system = "system"
}

public enum SpaceProposalState: String, Codable, CaseIterable, Sendable {
    case pending = "pending"
    case approved = "approved"
    case denied = "denied"
    case modified = "modified"
}

// MARK: - SwiftData Models

@Model
public final class SpaceModel: @unchecked Sendable {
    public var id: UUID
    public var name: String
    public var iconName: String
    public var summary: String
    public var workspacePath: String
    public var memoryNamespace: String
    public var defaultOrchestrationModeRaw: String
    public var executionTargetRaw: String
    public var inviteToken: String
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SpaceChannel.space)
    public var channels: [SpaceChannel] = []

    @Relationship(deleteRule: .cascade, inverse: \SpaceParticipant.space)
    public var participants: [SpaceParticipant] = []

    @Relationship(deleteRule: .cascade, inverse: \SpacePage.space)
    public var pages: [SpacePage] = []

    @Relationship(deleteRule: .cascade, inverse: \SpacePageProposal.space)
    public var proposals: [SpacePageProposal] = []

    public init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "person.3.sequence.fill",
        summary: String = "",
        workspacePath: String? = nil,
        defaultOrchestrationMode: SpaceOrchestrationMode = .mentionDriven,
        executionTargetRaw: String = "host"
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.summary = summary
        let baseDir = ApexAgentStoragePaths.directory("spaces")
            .appendingPathComponent(id.uuidString, isDirectory: true)
        self.workspacePath = workspacePath ?? baseDir.appendingPathComponent("workspace").path
        self.memoryNamespace = "spaces/\(id.uuidString)"
        self.defaultOrchestrationModeRaw = defaultOrchestrationMode.rawValue
        self.executionTargetRaw = executionTargetRaw
        self.inviteToken = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var orchestrationMode: SpaceOrchestrationMode {
        get { SpaceOrchestrationMode(rawValue: defaultOrchestrationModeRaw) ?? .mentionDriven }
        set { defaultOrchestrationModeRaw = newValue.rawValue }
    }

    public var executionTarget: String { executionTargetRaw }

    public var isSandboxVM: Bool { executionTargetRaw == "tartVM" }

    public var isSeatbelt: Bool { executionTargetRaw == "seatbelt" }

    public var sortedChannels: [SpaceChannel] {
        channels.sorted { $0.createdAt < $1.createdAt }
    }

    public var sortedPages: [SpacePage] {
        pages.sorted { $0.updatedAt > $1.updatedAt }
    }

    public var humanParticipants: [SpaceParticipant] {
        participants
            .filter { $0.kind.isHuman }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public var agentParticipants: [SpaceParticipant] {
        participants
            .filter { $0.kind.isAgent }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public var pendingProposals: [SpacePageProposal] {
        proposals
            .filter { $0.state == .pending }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public var sortedProposals: [SpacePageProposal] {
        proposals.sorted { $0.createdAt > $1.createdAt }
    }
}

@Model
public final class SpaceParticipant {
    public var id: UUID
    public var displayName: String
    public var handle: String
    public var roleTitle: String
    public var avatarSymbol: String
    public var colorHex: String
    public var kindRaw: String
    public var roleRaw: String
    public var presenceStateRaw: String
    public var botProfileId: UUID?
    public var a2aEndpointURL: String?
    public var joinedAt: Date

    public var space: SpaceModel?

    public init(
        id: UUID = UUID(),
        displayName: String,
        handle: String? = nil,
        roleTitle: String = "",
        avatarSymbol: String = "person.fill",
        colorHex: String = "#7C5CFF",
        kind: SpaceParticipantKind,
        role: SpaceParticipantRole,
        presenceState: SpacePresenceState = .online,
        botProfileId: UUID? = nil,
        a2aEndpointURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.handle = Self.normalizeHandle(handle ?? displayName)
        self.roleTitle = roleTitle
        self.avatarSymbol = avatarSymbol
        self.colorHex = colorHex
        self.kindRaw = kind.rawValue
        self.roleRaw = role.rawValue
        self.presenceStateRaw = presenceState.rawValue
        self.botProfileId = botProfileId
        self.a2aEndpointURL = a2aEndpointURL
        self.joinedAt = Date()
    }

    public var kind: SpaceParticipantKind {
        get { SpaceParticipantKind(rawValue: kindRaw) ?? .humanLocal }
        set { kindRaw = newValue.rawValue }
    }

    public var role: SpaceParticipantRole {
        get { SpaceParticipantRole(rawValue: roleRaw) ?? .member }
        set { roleRaw = newValue.rawValue }
    }

    public var presenceState: SpacePresenceState {
        get { SpacePresenceState(rawValue: presenceStateRaw) ?? .online }
        set { presenceStateRaw = newValue.rawValue }
    }

    public static func normalizeHandle(_ raw: String) -> String {
        let cleaned = raw
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return cleaned.isEmpty ? "member" : cleaned
    }
}

@Model
public final class SpaceChannel {
    public var id: UUID
    public var name: String
    public var topic: String
    public var channelTypeRaw: String
    public var activePlaybookRunId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public var space: SpaceModel?

    @Relationship(deleteRule: .cascade, inverse: \SpaceMessage.channel)
    public var messages: [SpaceMessage] = []

    public init(
        id: UUID = UUID(),
        name: String,
        topic: String = "",
        channelType: SpaceChannelType = .chat
    ) {
        self.id = id
        self.name = Self.normalizeChannelName(name)
        self.topic = topic
        self.channelTypeRaw = channelType.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var channelType: SpaceChannelType {
        get { SpaceChannelType(rawValue: channelTypeRaw) ?? .chat }
        set { channelTypeRaw = newValue.rawValue }
    }

    public var rootMessages: [SpaceMessage] {
        messages
            .filter { $0.threadParentId == nil }
            .sorted { $0.timestamp < $1.timestamp }
    }

    public func threadReplies(for parentId: UUID) -> [SpaceMessage] {
        messages
            .filter { $0.threadParentId == parentId }
            .sorted { $0.timestamp < $1.timestamp }
    }

    public static func normalizeChannelName(_ raw: String) -> String {
        let cleaned = raw
            .lowercased()
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "general" : cleaned
    }
}

@Model
public final class SpaceMessage {
    public var id: UUID
    public var senderParticipantId: UUID
    public var senderName: String
    public var senderHandle: String
    public var senderKindRaw: String
    public var senderAvatarSymbol: String
    public var content: String
    public var timestamp: Date
    public var threadParentId: UUID?
    public var mentionedHandlesCSV: String
    public var isStreaming: Bool

    public var channel: SpaceChannel?

    public init(
        id: UUID = UUID(),
        senderParticipantId: UUID,
        senderName: String,
        senderHandle: String,
        senderKind: SpaceSenderKind,
        senderAvatarSymbol: String = "person.fill",
        content: String,
        timestamp: Date = Date(),
        threadParentId: UUID? = nil,
        mentionedHandles: [String] = [],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.senderParticipantId = senderParticipantId
        self.senderName = senderName
        self.senderHandle = senderHandle
        self.senderKindRaw = senderKind.rawValue
        self.senderAvatarSymbol = senderAvatarSymbol
        self.content = content
        self.timestamp = timestamp
        self.threadParentId = threadParentId
        self.mentionedHandlesCSV = mentionedHandles.joined(separator: ",")
        self.isStreaming = isStreaming
    }

    public var senderKind: SpaceSenderKind {
        get { SpaceSenderKind(rawValue: senderKindRaw) ?? .human }
        set { senderKindRaw = newValue.rawValue }
    }

    public var mentionedHandles: [String] {
        get {
            mentionedHandlesCSV
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            mentionedHandlesCSV = newValue.joined(separator: ",")
        }
    }
}

@Model
public final class SpacePage {
    public var id: UUID
    public var title: String
    public var markdownBody: String
    public var lastEditedByName: String
    public var createdAt: Date
    public var updatedAt: Date

    public var space: SpaceModel?

    public init(
        id: UUID = UUID(),
        title: String,
        markdownBody: String,
        lastEditedByName: String = "System"
    ) {
        self.id = id
        self.title = title
        self.markdownBody = markdownBody
        self.lastEditedByName = lastEditedByName
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Space Page Proposal (Human-in-the-Loop Diff Staging)

@Model
public final class SpacePageProposal: @unchecked Sendable {
    public var id: UUID
    public var pageId: UUID
    public var pageTitle: String
    public var authorBotId: UUID?
    public var authorName: String
    public var summary: String
    public var originalContent: String
    public var proposedContent: String
    public var stateRaw: String
    public var createdAt: Date
    public var reviewedAt: Date?
    public var userFeedback: String?

    public var space: SpaceModel?

    public init(
        id: UUID = UUID(),
        pageId: UUID,
        pageTitle: String,
        authorBotId: UUID? = nil,
        authorName: String = "Agent",
        summary: String,
        originalContent: String,
        proposedContent: String,
        state: SpaceProposalState = .pending
    ) {
        self.id = id
        self.pageId = pageId
        self.pageTitle = pageTitle
        self.authorBotId = authorBotId
        self.authorName = authorName
        self.summary = summary
        self.originalContent = originalContent
        self.proposedContent = proposedContent
        self.stateRaw = state.rawValue
        self.createdAt = Date()
    }

    public var state: SpaceProposalState {
        get { SpaceProposalState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }
}

public enum ChatAutocomplete {

    public enum Trigger: Character, Sendable {
        case mention = "@"
        case command = "/"
    }

    public struct Suggestion: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let display: String
        public let insertion: String
        public init(display: String, insertion: String) {
            self.id = UUID()
            self.display = display
            self.insertion = insertion
        }
    }

    public static func currentToken(in text: String) -> String? {
        if text.isEmpty { return nil }
        var start = text.endIndex
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev].isWhitespace { break }
            start = prev
        }
        if start == text.endIndex { return nil }
        return String(text[start..<text.endIndex])
    }

    public static func trigger(for token: String) -> Trigger? {
        guard let first = token.first else { return nil }
        switch first {
        case "@": return .mention
        case "/": return .command
        default: return nil
        }
    }

    public static func isActiveTrigger(in text: String) -> Bool {
        guard let token = currentToken(in: text) else { return false }
        return trigger(for: token) != nil
    }

    public static func query(for token: String) -> String {
        guard token.count > 1 else { return "" }
        return String(token.dropFirst())
    }

    public static func mentionSuggestions(botNames: [String], query: String) -> [Suggestion] {
        let q = query.lowercased()
        return botNames
            .filter { bot in
                if q.isEmpty { return true }
                if bot.localizedCaseInsensitiveContains(q) { return true }
                return handle(for: bot).localizedCaseInsensitiveContains(q)
            }
            .map { name in
                Suggestion(display: name, insertion: "@" + handle(for: name))
            }
    }

    public static func commandSuggestions(commands: [String], query: String) -> [Suggestion] {
        let q = query.lowercased()
        return commands
            .filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
            .map { Suggestion(display: $0, insertion: "/" + $0) }
    }

    public static func applyInsertion(_ insertion: String, to text: String) -> String {
        guard let token = currentToken(in: text) else {
            var result = text + insertion
            if !result.hasSuffix(" ") { result += " " }
            return result
        }
        let tokenStart = text.index(text.endIndex, offsetBy: -token.count)
        var result = String(text[..<tokenStart]) + insertion
        if !result.hasSuffix(" ") { result += " " }
        return result
    }

    private static func handle(for raw: String) -> String {
        let cleaned = raw
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return cleaned.isEmpty ? "member" : cleaned
    }
}
