import Foundation
import SwiftData
import Observation
import AppKit
import FoundationModels

// MARK: - BotSession: Per-Bot execution state & conversation history

/// Manages a single Bot's conversation, execution loop, streaming state,
/// queued prompts, tool approval cards, and transcript synchronization.
@Observable
@MainActor
final class BotSession {
    let bot: BotProfile
    weak var orchestrator: AgentOrchestrator?
    weak var computer: Computer?
    weak var botManager: BotManager?
    var modelContext: ModelContext?

    var id: UUID { bot.id }
    var messages: [ChatMessage] = []
    var isGenerating: Bool = false
    var streamingMessageId: UUID?
    var activeAssistantMessageId: UUID?
    var pendingAttachments: [NSImage] = []
    var generationTask: Task<Void, Never>?
    var pendingAsyncContinuation: CheckedContinuation<String?, Never>?
    var currentConversation: Conversation?
    var session: LanguageModelSession?
    var modelAvailability: SystemLanguageModel.Availability = .available
    var activePlan: [PlanStep] = []

    // MARK: - Queued Prompts State
    /// User prompts submitted while generation is running. Drained in FIFO order.
    var queuedPrompts: [QueuedPrompt] = []

    // MARK: - WS4: Needs-Attention indicator
    /// True when this session is blocked on a peer-to-peer card or pending approval.
    var needsAttention: Bool = false
    var unreadActivity: Bool = false

    // MARK: - Tool Calling Preference Override
    var toolCallingMode: AgentToolCallingMode = .auto

    // MARK: - Dynamic Allowlist Computation
    var effectiveToolAllowlist: [String] {
        if !bot.allowedToolNames.isEmpty {
            return bot.allowedToolNames
        }
        return [
            "read_file", "write_file", "list_directory", "delete_file",
            "run_shell_command", "web_search", "fetch_url", "take_screenshot",
            "notification_tool", "system_info", "open_application"
        ]
    }

    // MARK: - Effective Privacy Tier
    var effectivePrivacyTier: PrivacyTier {
        ModelRegistry.privacyTier()
    }

    // MARK: - Active Model Provider
    var effectiveModelProvider: ModelProvider {
        bot.modelProvider ?? ModelRegistry.activeProvider()
    }

    // MARK: - Init
    init(
        bot: BotProfile,
        orchestrator: AgentOrchestrator,
        computer: Computer = Computer()
    ) {
        self.bot = bot
        self.orchestrator = orchestrator
        self.computer = computer
    }

    func checkAvailability() {
        let model = SystemLanguageModel.default
        self.modelAvailability = model.availability
    }

    /// Composed system instructions including the Chief-of-Staff roster prompt
    /// so every bot knows which teammates exist and can be delegated to via
    /// `delegate_task`.
    var systemInstructions: String {
        var baseInstructions = bot.systemInstructions

        // Inject long-term cognitive memory context for this bot
        let cognitiveSummary = CognitiveMemoryEngine.shared.buildContextSummary(forBotId: bot.id, maxLength: 800)
        if !cognitiveSummary.isEmpty {
            baseInstructions += "\n\n--- Long-Term Cognitive Memory ---\n" + cognitiveSummary
        }

        let facts = CognitiveMemoryEngine.shared.searchFacts(keyword: "", botId: bot.id)
        if !facts.isEmpty {
            let factsList = facts.prefix(10).map { "- \($0.subject) \($0.predicate) \($0.object)" }.joined(separator: "\n")
            baseInstructions += "\n\n--- Remembered Knowledge Graph ---\n" + factsList
        }

        guard bot.isChiefOfStaff, let botManager else { return baseInstructions }
        let profiles = botManager.allBots.map { ($0, botManager.isGenerating(botId: $0.id)) }
        let rosterPrompt = ChiefOfStaff.systemPrompt(
            chiefId: bot.id,
            profiles: profiles,
            canDelegate: true
        )
        return baseInstructions + "\n\n" + rosterPrompt
    }

    // MARK: - Queued Prompts Management

    func removeQueuedPrompt(id: UUID) {
        queuedPrompts.removeAll { $0.id == id }
    }

    func clearQueuedPrompts() {
        queuedPrompts.removeAll()
    }

    func clearPromptQueue() {
        clearQueuedPrompts()
    }

    /// Appends a user prompt to the queue while generation is active.
    func queuePrompt(
        _ text: String,
        attachments: [NSImage] = []
    ) {
        let queued = QueuedPrompt(
            id: UUID(),
            text: text,
            attachments: attachments
        )
        queuedPrompts.append(queued)
    }

    /// Drains the next queued prompt if not generating.
    func drainNextQueuedPromptIfIdle() {
        guard !queuedPrompts.isEmpty, !isGenerating else { return }
        let next = queuedPrompts.removeFirst()
        Task { @MainActor in
            await self.send(
                prompt: next.text,
                attachments: next.attachments
            )
        }
    }

    func processNextQueuedPromptIfNeeded() {
        drainNextQueuedPromptIfIdle()
    }

    // MARK: - Stop / Cancel

    /// Stops any ongoing generation or streaming for this bot and clears queued prompts.
    func stopGeneration() {
        isGenerating = false
        generationTask?.cancel()
        generationTask = nil
        if let streamingId = streamingMessageId {
            updateMessage(id: streamingId, isStreaming: false)
            streamingMessageId = nil
        }
        activeAssistantMessageId = nil
    }

    func cancelGeneration() {
        stopGeneration()
    }

    func captureAndAttachScreenshot() async {
        if let orch = orchestrator {
            await orch.captureAndAttachScreenshot()
            if let screenshot = orch.pendingAttachments.popLast() {
                pendingAttachments.append(screenshot)
            }
        }
    }

    // MARK: - Direct Tool Execution

    func executeTool(name: String, arguments: String) async throws -> String {
        guard let orch = orchestrator else {
            return "ERROR: Orchestrator unavailable"
        }

        // RBAC Allowlist check
        if !bot.allowedToolNames.isEmpty && !bot.allowedToolNames.contains(name) {
            return "ERROR: Tool '\(name)' is not permitted for bot '\(bot.name)' under least-privilege security policy. Allowed tools: \(bot.allowedToolNames.joined(separator: ", "))"
        }
        // MCP Scoping check
        if !bot.allowedMCPServers.isEmpty {
            if let entry = DynamicToolbox.shared.dynamicTools[name], let serverId = entry.mcpServerId {
                let matchingServer = MCPManager.shared.servers.first(where: { $0.id == serverId })
                let serverName = matchingServer?.name ?? ""
                let serverIdStr = serverId.uuidString
                let isAllowed = bot.allowedMCPServers.contains { allowed in
                    allowed.caseInsensitiveCompare(serverName) == .orderedSame ||
                    allowed.caseInsensitiveCompare(serverIdStr) == .orderedSame
                }
                if !isAllowed {
                    let displayName = serverName.isEmpty ? serverIdStr : serverName
                    return "ERROR: Tool '\(name)' from MCP server '\(displayName)' is not permitted for bot '\(bot.name)' under least-privilege MCP scoping policy. Allowed MCP servers: \(bot.allowedMCPServers.joined(separator: ", "))"
                }
            }
        }

        do {
            return try await orch.executeToolByName(
                name: name,
                jsonArguments: arguments,
                bot: bot,
                agentIdentity: AgentIdentity.bot(id: bot.id, name: bot.name)
            )
        } catch {
            let desc = error.localizedDescription
            if desc.contains("is not permitted for bot") || desc.contains("Permission Denied") || desc.contains("ERROR:") {
                return desc
            }
            throw error
        }
    }

    // MARK: - Prompt Execution & Delivery

    /// Sends a prompt to the bot. If generation is in progress, automatically queues it.
    func send(
        prompt: String,
        attachments: [NSImage] = [],
        toolCallingMode: AgentToolCallingMode? = nil
    ) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = !attachments.isEmpty ? attachments : self.pendingAttachments
        self.pendingAttachments = []
        guard !trimmed.isEmpty || !attachmentsToSend.isEmpty else { return }

        // If generation is active, queue this prompt instead of dropping or conflicting
        if isGenerating {
            queuePrompt(trimmed, attachments: attachmentsToSend)
            return
        }

        isGenerating = true
        activeAssistantMessageId = nil
        defer {
            isGenerating = false
            drainNextQueuedPromptIfIdle()
        }

        let userMsg = ChatMessage(
            id: UUID(),
            role: .user,
            content: trimmed,
            timestamp: Date(),
            attachments: attachmentsToSend
        )
        appendMessage(userMsg)

        let assistantId = UUID()
        activeAssistantMessageId = assistantId
        let assistantMsg = ChatMessage(
            id: assistantId,
            role: .assistant,
            content: "",
            timestamp: Date(),
            isStreaming: true,
            botName: bot.name
        )
        appendMessage(assistantMsg)
        streamingMessageId = assistantId

        let mode = toolCallingMode ?? self.toolCallingMode

        do {
            let request = AgentRequest(
                id: UUID(),
                senderIdentity: .bot(id: bot.id, name: bot.name),
                prompt: trimmed,
                attachments: attachmentsToSend,
                toolCallingMode: mode
            )

            guard let orch = orchestrator else {
                updateMessage(id: assistantId, content: "⚠️ Orchestrator unavailable.")
                updateMessage(id: assistantId, isStreaming: false)
                return
            }

            let result = await AgentRequestRouter.shared.route(
                request,
                bot: bot,
                session: session,
                history: messages.dropLast(), // exclude the empty assistant placeholder
                instructions: systemInstructions,
                orchestrator: orch,
                onEvent: { _ in
                    // Granular events can be logged or reflected in UI
                },
                onUpdate: { [weak self] delta in
                    Task { @MainActor in
                        self?.updateMessage(id: assistantId, content: delta)
                    }
                }
            )

            if case .completed(let output) = result {
                updateMessage(id: assistantId, content: output)
            } else if case .failed(let error, _) = result {
                updateMessage(id: assistantId, content: "❌ Error: \(error)")
            } else if case .fallbackExhausted(let errors) = result {
                updateMessage(id: assistantId, content: "⚠️ Provider fallback exhausted: \(errors.joined(separator: "; "))")
            } else if case .cancelled(let reason) = result {
                updateMessage(id: assistantId, content: "⏹️ \(reason)")
            }

            updateMessage(id: assistantId, isStreaming: false)
            if let finalMsg = messages.first(where: { $0.id == assistantId }) {
                saveMessageToDisk(finalMsg)
            }

            // Compact context if history exceeds budget
            await compactContextIfNeeded()
        }
    }

    // MARK: - Message Helpers

    func appendMessage(_ msg: ChatMessage) {
        messages.append(msg)
        saveMessageToDisk(msg)
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

    func clearMessages() {
        reset()
    }

    func reset() {
        stopGeneration()
        messages.removeAll()
        queuedPrompts.removeAll()
        pendingAttachments.removeAll()
        currentConversation = nil
        needsAttention = false
        unreadActivity = false
        activePlan.removeAll()
    }

    // MARK: - Persistence (SwiftData)

    func loadConversationFromDisk() {
        guard let context = modelContext else { return }
        let targetId = bot.id
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.botProfileId == targetId },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        if let conv = try? context.fetch(descriptor).first {
            self.currentConversation = conv
            let sortedDbMsgs = conv.messages.sorted { $0.timestamp < $1.timestamp }
            self.messages = sortedDbMsgs.map { dbMsg in
                ChatMessage(
                    id: dbMsg.id,
                    role: dbMsg.role == .user ? .user : (dbMsg.role == .assistant ? .assistant : .system),
                    content: dbMsg.content,
                    timestamp: dbMsg.timestamp,
                    attachments: dbMsg.attachments,
                    botName: dbMsg.role == .assistant ? bot.name : nil
                )
            }
        }
    }

    private func saveMessageToDisk(_ msg: ChatMessage) {
        guard let context = modelContext else { return }

        let conv: Conversation
        if let existing = currentConversation {
            conv = existing
        } else {
            let newConv = Conversation(title: "Chat with \(bot.name)", botProfileId: bot.id)
            context.insert(newConv)
            self.currentConversation = newConv
            conv = newConv
        }

        let attData = msg.attachments.compactMap { $0.pngData }
        let dbMsg = Message(
            role: msg.role == .user ? .user : (msg.role == .assistant ? .assistant : .system),
            content: msg.content,
            attachmentsData: attData.isEmpty ? nil : attData
        )
        dbMsg.id = msg.id
        dbMsg.timestamp = msg.timestamp
        dbMsg.conversation = conv
        context.insert(dbMsg)

        conv.updatedAt = Date()
        try? context.save()
    }

    // MARK: - Context Compaction & Token Budgeting

    func compactContextIfNeeded() async {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        guard messages.count > 10 || totalChars > 16000 else { return }
        let targetBotId = bot.id
        do {
            let (compacted, archivedCount) = try await CognitiveMemoryEngine.shared.compactMessages(
                messages: self.messages,
                keepRecent: 4,
                maxChars: 4000,
                botId: targetBotId
            ) { [weak self] transcript in
                guard self != nil else { return "" }
                let model = SystemLanguageModel.default
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
                    let dbSummaryMsg = Message(role: MessageRole.system, content: first.content, attachmentsData: nil)
                    dbSummaryMsg.id = first.id
                    dbSummaryMsg.conversation = conv
                    context.insert(dbSummaryMsg)
                }
                
                conv.updatedAt = Date()
                try? context.save()
            }
        } catch {
            AppLog.error(.bot, "⚠️ Context compaction skipped: \(error.localizedDescription)")
        }
    }

    /// Prunes excessive tool output blocks in older conversation turns to prevent context window overflow.
    func pruneExcessiveToolOutputs(maxOutputChars: Int = 3000) {
        guard messages.count > 1 else { return }
        var modified = false
        var updated = messages
        // Leave the very last message intact (most recent prompt/turn)
        for i in 0..<(updated.count - 1) {
            let msg = updated[i]
            if msg.content.count > maxOutputChars {
                let origCount = msg.content.count
                let head = msg.content.prefix(maxOutputChars / 2)
                let tail = msg.content.suffix(maxOutputChars / 2)
                let prunedContent = "\(head)\n\n[... Tool output truncated from \(origCount) chars for model context window budget ...]\n\n\(tail)"
                updated[i].content = prunedContent
                modified = true
            }
        }
        if modified {
            self.messages = updated
        }
    }

    /// Pre-flight character and token budget validation before dispatching to the selected model provider.
    func enforceTokenBudgetBeforeDispatch(provider: ModelProvider) async {
        let ceiling = ModelRegistry.contextCeiling(for: provider)
        let threshold = Int(Double(ceiling) * 0.75)
        let estimatedTokens = ModelRegistry.estimateTokenCount(
            prompt: "",
            history: self.messages,
            instructions: self.systemInstructions,
            tools: self.bot.allowedToolNames
        )
        if estimatedTokens > threshold {
            await self.compactContextIfNeeded()
            let updatedTokens = ModelRegistry.estimateTokenCount(
                prompt: "",
                history: self.messages,
                instructions: self.systemInstructions,
                tools: self.bot.allowedToolNames
            )
            if updatedTokens > threshold {
                self.pruneExcessiveToolOutputs(maxOutputChars: 3000)
            }
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
        let resolvedModel = SystemLanguageModel.default
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

    // MARK: - Markdown Session Diagnostics

    func formatSessionDiagnosticsMarkdown() -> String {
        var md = "### 🤖 BotSession Runtime Diagnostics: \(bot.name)\n\n"
        md += "| Metric / Property | Value | Description |\n"
        md += "|---|---|---|\n"
        md += "| Bot Persona | `\(bot.name)` | Assigned agent persona |\n"
        md += "| Generation Status | \(isGenerating ? "⚡️ Generating" : "💤 Idle") | Active streaming state |\n"
        md += "| Transcript Messages | `\(messages.count)` | Session message count |\n"
        md += "| Effective Tools | `\(effectiveToolAllowlist.count)` tools | Allowed tools in sandbox |\n"
        md += "| Hardware Privacy Tier | `\(effectivePrivacyTier.displayName)` | Privacy assurance level |\n"
        md += "| Queued Prompts | `\(queuedPrompts.count)` | Pending prompt queue |\n"
        md += "| Tool Calling Mode | `\(String(describing: toolCallingMode))` | Tool invocation strategy |\n"
        return md
    }

}