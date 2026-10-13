import Foundation
import AppKit
import FoundationModels
import SwiftData
import Observation

// MARK: - BotProfile: A persistent, named AI teammate

/// A Bot is a durable AI teammate with a name, a job, its own conversation,
/// and working context that develops over time. Bots share the local computer
/// (the Mac) but have separate conversations, memories, and preferences.
@Model
final class BotProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var title: String        // short role label, e.g. "Account Health"
    var descriptionText: String  // operational instructions — rules that stay true
    var avatarName: String   // SF Symbol name for the bot icon
    var createdAt: Date
    var updatedAt: Date

    /// Durable working preferences & facts the Bot retains across turns.
    /// Not a substitute for authoritative sources — used for style, format,
    /// boundaries, and accumulated role context.
    var memory: String

    /// Whether this Bot is pinned to the top of the sidebar.
    var isPinned: Bool

    /// The last time this Bot was active (for sorting "needs attention").
    var lastActiveAt: Date

    /// When true, this Bot's instructions include a live roster of its team
    /// ("chief of staff") so it can coordinate specialists.
    var isChiefOfStaff: Bool = false

    /// Per-bot model provider override. When nil, the bot uses the global
    /// `ModelRegistry.activeProvider()`. Set to a `ModelProvider.rawValue`
    /// string to assign a specific provider to this bot (e.g. one bot on
    /// Ollama while another uses Apple on-device). Defaults keep SwiftData
    /// lightweight migration working for existing stores.
    var modelProviderRaw: String?

    /// Per-bot Ollama model name override (e.g. "deepseek-r1:14b" vs the
    /// global "gemma4:12b"). Only used when this bot's provider is
    /// `.localOllama`. Nil = use the global `apex.ollamaModel` default.
    var ollamaModelOverride: String?

    /// Optional specific model identifier override (e.g. "claude-3.5-sonnet",
    /// "gemini-3.1-pro", or "gpt-4o") for the bot's configured provider.
    var customModelIdentifier: String?

    /// Type-safe accessor for the per-bot model provider.
    /// Returns nil when the bot should use the global default.
    var modelProvider: ModelProvider? {
        get {
            guard let raw = modelProviderRaw else { return nil }
            return ModelProvider(rawValue: raw)
        }
        set {
            modelProviderRaw = newValue?.rawValue
        }
    }

    /// Ordered list of tool names this Bot is permitted to execute.
    /// Empty = bot inherits the default group allowlist (web_search, read_file,
    /// list_directory, file_search, search_memory, store_memory, get_system_info,
    /// send_notification). A non-empty set enforces least-privilege RBAC: any
    /// tool not in the list is rejected with an error from BotSession.executeTool.
    var allowedToolNames: [String] = []

    /// Scoped list of MCP server names or IDs permitted for this Bot.
    /// Empty = inherits all globally configured MCP servers.
    var allowedMCPServers: [String] = []

    /// Default initializer for SwiftData insertion.
    init(
        id: UUID = UUID(),
        name: String,
        title: String = "",
        descriptionText: String = "",
        avatarName: String = "person.fill",
        memory: String = "",
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.descriptionText = descriptionText
        self.avatarName = avatarName
        self.createdAt = Date()
        self.updatedAt = Date()
        self.memory = memory
        self.isPinned = isPinned
        self.lastActiveAt = Date()
    }

    /// The full system prompt assembled from the Bot's description + memory.
    /// This is what gets fed into the LanguageModelSession as instructions.
    var systemInstructions: String {
        var parts: [String] = []
        if !title.isEmpty {
            parts.append("You are \(name). \(title)")
        } else {
            parts.append("You are \(name).")
        }
        if !descriptionText.isEmpty {
            parts.append(descriptionText)
        }
        if !memory.isEmpty {
            parts.append("\n\n--- Durable working context ---\n\(memory)")
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - BotMemoryEntry: Discrete memory facts attached to a Bot

@Model
final class BotMemoryEntry {
    @Attribute(.unique) var id: UUID
    var key: String          // topic/label for the memory
    var value: String        // the remembered fact or preference
    var source: String       // how this was learned (e.g. "user instruction", "demonstrated")
    var createdAt: Date
    var botProfileId: UUID   // back-reference to the owning Bot
    var embeddingData: Data? // Serialized semantic embedding vector for vector search

    init(key: String, value: String, source: String = "user instruction", botProfileId: UUID, embeddingData: Data? = nil) {
        self.id = UUID()
        self.key = key
        self.value = value
        self.source = source
        self.createdAt = Date()
        self.botProfileId = botProfileId
        self.embeddingData = embeddingData
    }
}

// MARK: - BotSessionState: In-memory session state per Bot (not persisted)

/// Holds the live session state for one Bot during a chat turn.
/// Resembles what AgentOrchestrator does today, but scoped to one Bot.
@Observable
@MainActor
final class BotSessionState {
    var messages: [ChatMessage] = []
    var toolEvents: [ToolEvent] = []
    var isGenerating: Bool = false
    var pendingConfirmation: ConfirmationRequest?
    var activeAssistantMessageId: UUID?
    var activePlan: [PlanStep] = []
    var agentInstructions: String = ""
    var toolCallingMode: AgentToolCallingMode = .auto
    var modelPreference: AgentModelPreference = .localSystem
    var pendingAttachments: [NSImage] = []

    /// The underlying LanguageModelSession for this Bot.
    var session: LanguageModelSession?

    /// The Bot this session belongs to.
    weak var bot: BotProfile?

    /// Orchestrator reference for tool execution, permissions, etc.
    weak var orchestrator: AgentOrchestrator?

    /// Reset for a new conversation with this Bot.
    func reset() {
        messages = []
        toolEvents = []
        isGenerating = false
        activeAssistantMessageId = nil
        activePlan = []
        pendingAttachments = []
        session = nil
    }
}
