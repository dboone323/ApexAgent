import Foundation
import AppKit
import FoundationModels
import SwiftData
import Observation

// MARK: - BotSession: A chat session scoped to one Bot

/// Each Bot gets one BotSession when you open a conversation with it.
/// It holds the LanguageModelSession, messages, tool events, and routing
/// for that Bot — equivalent to what AgentOrchestrator does today, but
/// per-Bot instead of global.
///
/// The BotSession delegates tool execution and permissions to the shared
/// AgentOrchestrator (which owns the SwiftData context, security sandbox,
/// and tool registry), but keeps its own message history, instructions,
/// memory, and model session.
@Observable
@MainActor
final class BotSession {
    // MARK: - Identity
    var bot: BotProfile

    // MARK: - Conversation State (per-Bot)
    var messages: [ChatMessage] = []
    var toolEvents: [ToolEvent] = []
    var isGenerating: Bool = false
    var pendingConfirmation: ConfirmationRequest?
    var activeAssistantMessageId: UUID?
    var activePlan: [PlanStep] = []
    var pendingAttachments: [NSImage] = []
    var pendingAsyncContinuation: CheckedContinuation<String?, Never>?

    // MARK: - Model State
    var modelPreference: AgentModelPreference = .localSystem
    var toolCallingMode: AgentToolCallingMode = .auto
    var session: LanguageModelSession?
    var modelAvailability: SystemLanguageModel.Availability = .available

    // MARK: - Shared references (not owned)
    weak var orchestrator: AgentOrchestrator?
    weak var computer: Computer?
    /// Back-reference for chief-of-staff roster composition. Set by BotManager
    /// when it creates the session.
    weak var botManager: BotManager?

    // MARK: - SwiftData
    var modelContext: ModelContext?
    var currentConversation: Conversation?

    // MARK: - Attention state
    var needsAttention: Bool = false       // waiting for approval/question/handoff
    var unreadActivity: Bool = false       // new result since last viewed

    // MARK: - Init
    init(bot: BotProfile, orchestrator: AgentOrchestrator, computer: Computer) {
        self.bot = bot
        self.orchestrator = orchestrator
        self.computer = computer
        self.modelAvailability = orchestrator.modelAvailability
    }

    // MARK: - System Instructions (dynamic, includes memory + chief roster)

    var systemInstructions: String {
        var baseInstructions = bot.systemInstructions
        
        // Inject Cognitive Memory (episodes, facts, procedures)
        let memorySummary = CognitiveMemoryEngine.shared.buildContextSummary(forBotId: bot.id, maxLength: 800)
        if !memorySummary.isEmpty && memorySummary.contains(":\n") {
            baseInstructions += "\n\n### Cognitive Memory Context:\n" + memorySummary
        }
        
        guard bot.isChiefOfStaff, let botManager else { return baseInstructions }
        // Chief of staff: append a live roster so the commander knows who it
        // can delegate to. Caps/clipping live in ChiefOfStaff itself.
        let members = botManager.allBots.map { profile in
            ChiefTeamMember(
                id: profile.id.uuidString,
                name: profile.name,
                title: profile.title.isEmpty ? nil : profile.title,
                descriptionText: profile.descriptionText.isEmpty ? nil : profile.descriptionText,
                busy: botManager.isGenerating(botId: profile.id),
                hidden: false,
                section: nil)
        }
        let rosterPrompt = ChiefOfStaff.systemPrompt(
            chiefId: bot.id.uuidString,
            bots: members,
            canDelegate: true)
        return baseInstructions + "\n\n" + rosterPrompt
    }

    // MARK: - Reset / New Conversation

    func reset() {
        messages = []
        toolEvents = []
        isGenerating = false
        activeAssistantMessageId = nil
        activePlan = []
        pendingAttachments = []
        session = nil
        needsAttention = false
        unreadActivity = false
        currentConversation = nil
    }

    // MARK: - Message Management

    /// Sends a message and awaits the final assistant response.
    /// Uses a continuation to bridge the callback-based generation flow.
    func sendMessageAsync(_ text: String, attachments: [NSImage] = []) async -> String? {
        guard !isGenerating else { return nil }
        return await withCheckedContinuation { continuation in
            self.pendingAsyncContinuation = continuation
            self.sendMessage(text, attachments: attachments)
        }
    }

    func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        persistMessage(message)
    }

    func updateMessage(id: UUID, content: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].content = content
            if let conv = currentConversation,
               let persistedMsg = conv.messages.first(where: { $0.id == id }) {
                persistedMsg.content = content
                try? modelContext?.save()
            }
        }
    }

    func updateMessage(id: UUID, isStreaming: Bool) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].isStreaming = isStreaming
        }
    }

    func loadConversationFromDisk() {
        guard let context = modelContext else { return }
        let botId = bot.id
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.botProfileId == botId },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let existing = try? context.fetch(descriptor).first {
            self.currentConversation = existing
            self.messages = existing.messages.sorted(by: { $0.timestamp < $1.timestamp }).map { m in
                ChatMessage(
                    id: m.id,
                    role: m.role,
                    content: m.content,
                    timestamp: m.timestamp,
                    attachments: m.attachments
                )
            }
        }
    }

    private func persistMessage(_ message: ChatMessage) {
        guard let context = modelContext else { return }
        let conv: Conversation
        if let current = currentConversation {
            conv = current
        } else {
            conv = Conversation(title: "Chat with \(bot.name)", botProfileId: bot.id)
            context.insert(conv)
            self.currentConversation = conv
        }
        conv.updatedAt = Date()

        let msg = Message(
            role: message.role,
            content: message.content,
            attachmentsData: message.attachments.compactMap { $0.pngData }
        )
        msg.id = message.id
        msg.timestamp = message.timestamp
        msg.conversation = conv
        context.insert(msg)
        try? context.save()
        
        // Record Episodic Memory turn for this bot
        let summary = String(message.content.prefix(200))
        if !summary.isEmpty {
            CognitiveMemoryEngine.shared.recordEpisode(
                CognitiveMemoryEngine.EpisodicEntry(
                    botId: bot.id,
                    eventType: message.role == .user ? "user_prompt" : "assistant_response",
                    summary: summary
                )
            )
        }
    }

    // MARK: - Tool Execution (delegates to shared orchestrator, enforces per-bot allowlist)

    /// When non-empty, this Bot may only execute tools whose names appear here.
    /// Empty = no restriction (the bot inherits whatever the orchestrator allows).
    var effectiveToolAllowlist: Set<String> {
        guard !bot.allowedToolNames.isEmpty else { return [] }
        return Set(bot.allowedToolNames)
    }

    func executeTool(name: String, arguments: String) async throws -> String {
        guard let orchestrator else {
            return "ERROR: No orchestrator available."
        }
        if !effectiveToolAllowlist.isEmpty && !effectiveToolAllowlist.contains(name) {
            return "ERROR: Tool '\(name)' is not permitted for bot '\(bot.name)' under least-privilege security policy."
        }
        if let dynamicTool = DynamicToolbox.shared.dynamicTools[name],
           let mcpId = dynamicTool.mcpServerId,
           !bot.allowedMCPServers.isEmpty {
            let serverName = MCPManager.shared.servers.first(where: { $0.id == mcpId })?.name ?? mcpId.uuidString
            if !bot.allowedMCPServers.contains(serverName) && !bot.allowedMCPServers.contains(mcpId.uuidString) {
                return "ERROR: MCP tool '\(name)' from server '\(serverName)' is not permitted for bot '\(bot.name)'."
            }
        }
        return try await orchestrator.executeToolByName(name: name, jsonArguments: arguments)
    }

    // MARK: - Confirmation (delegates to shared orchestrator)

    func requestConfirmation(
        toolName: String,
        arguments: String,
        riskDescription: String,
        oldContent: String? = nil,
        newContent: String? = nil,
        filePath: String? = nil
    ) async -> Bool {
        await orchestrator?.requestConfirmation(
            toolName: toolName,
            arguments: arguments,
            riskDescription: riskDescription,
            oldContent: oldContent,
            newContent: newContent,
            filePath: filePath
        ) ?? false
    }

    func resolveConfirmation(approved: Bool) {
        orchestrator?.resolveConfirmation(approved: approved)
    }

    // MARK: - Context Compaction
    
    public static let contextCompactionThreshold: Int = 12000
    
    /// Checks message history volume and compacts older turns into a structured summary
    /// and durable episodic memory when character threshold is exceeded.
    public func compactContextIfNeeded() async {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        guard totalChars > Self.contextCompactionThreshold else { return }
        guard messages.count > 5 else { return }
        
        let targetBotId = bot.id
        
        do {
            let (compacted, archivedCount) = try await CognitiveMemoryEngine.shared.compactMessages(
                messages: self.messages,
                keepRecent: 4,
                maxChars: 4000,
                botId: targetBotId
            ) { [weak self] transcript in
                guard let self else { return "" }
                // Use the bot's configured engine or fallback to local model
                let model = ModelRegistry.model(for: self.bot)
                let session = LanguageModelSession(
                    model: model,
                    instructions: "You are a concise context compaction assistant. Summarize earlier chat history accurately preserving file paths, error codes, and technical findings."
                )
                let response = try await session.respond(to: transcript)
                return response.content
            }
            
            guard archivedCount > 0 else { return }
            
            self.messages = compacted
            
            // Sync to SwiftData if conversation exists
            if let conv = self.currentConversation, let context = self.modelContext {
                let remainingIds = Set(compacted.map { $0.id })
                for dbMsg in conv.messages where !remainingIds.contains(dbMsg.id) {
                    context.delete(dbMsg)
                }
                
                // If a summary message was inserted at index 0, persist it
                if let first = compacted.first, first.role == .system {
                    let dbSummaryMsg = Message(role: .system, content: first.content)
                    dbSummaryMsg.id = first.id
                    dbSummaryMsg.conversation = conv
                    context.insert(dbSummaryMsg)
                }
                
                conv.updatedAt = Date()
                try? context.save()
            }
        } catch {
            print("⚠️ [BotSession] Context compaction skipped: \(error.localizedDescription)")
        }
    }

    // MARK: - Model Session Creation

    func resetSession() {
        let instructions = systemInstructions
        let mode: GenerationOptions.ToolCallingMode = switch toolCallingMode {
        case .auto: .allowed
        case .required: .required
        case .disabled: .disallowed
        }
        let transcript = Transcript(entries: [])
        // Per-bot model: use the bot's own provider when set, otherwise
        // fall back to the global provider via ModelRegistry.
        let resolvedModel = ModelRegistry.model(for: bot)
        session = makeSession(model: resolvedModel, instructions: instructions, mode: mode, transcript: transcript)
        let isTesting = getenv("APEX_TEST_MODE") != nil
            || ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("xctest")
            || NSClassFromString("XCTestCase") != nil
            || CommandLine.arguments.contains("--cli")
            || CommandLine.arguments.contains("--daemon")
        if !isTesting {
            session?.prewarm(promptPrefix: Prompt("Analyze the following"))
        }
    }

    private func makeSession<M: LanguageModel>(
        model: M,
        instructions: String,
        mode: GenerationOptions.ToolCallingMode,
        transcript: Transcript
    ) -> LanguageModelSession {
        let allowedTools: [String] = bot.allowedToolNames.isEmpty
            ? (AgentRegistry.builtInDefaults[bot.name.lowercased()]?.allowedTools
               ?? ["read_file", "write_file", "patch_file", "git_operation", "list_directory", "file_search", "web_search", "search_memory", "store_memory", "get_system_info", "send_notification"])
            : bot.allowedToolNames

        let profile = SpecializedAgentProfile(
            instructions: instructions,
            model: model,
            toolCallingMode: mode,
            orchestrator: orchestrator!,
            allowedTools: allowedTools,
            reasoningLevel: orchestrator!.configuredReasoningLevel,
            maxResponseTokens: orchestrator!.configuredMaxResponseTokens
        )
        return LanguageModelSession(profile: profile, history: transcript)
    }

    // MARK: - Semantic Context (delegates to orchestrator)

    func getSemanticContext(for prompt: String) -> String {
        orchestrator?.getSemanticContext(for: prompt) ?? ""
    }
}
