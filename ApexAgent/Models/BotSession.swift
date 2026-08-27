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
        guard bot.isChiefOfStaff, let botManager else { return bot.systemInstructions }
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
        return bot.systemInstructions + "\n\n" + rosterPrompt
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
    }

    func updateMessage(id: UUID, content: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].content = content
        }
    }

    func updateMessage(id: UUID, isStreaming: Bool) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].isStreaming = isStreaming
        }
    }

    // MARK: - Tool Execution (delegates to shared orchestrator)

    func executeTool(name: String, arguments: String) async throws -> String {
        guard let orchestrator else {
            return "ERROR: No orchestrator available."
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
        session?.prewarm(promptPrefix: Prompt("Analyze the following"))
    }

    private func makeSession<M: LanguageModel>(
        model: M,
        instructions: String,
        mode: GenerationOptions.ToolCallingMode,
        transcript: Transcript
    ) -> LanguageModelSession {
        let profile = ApexAgentProfile(
            instructions: instructions,
            model: model,
            toolCallingMode: mode,
            orchestrator: orchestrator!,
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
