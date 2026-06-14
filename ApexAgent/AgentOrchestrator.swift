import Foundation
import FoundationModels
import Observation
import SwiftData
import AppKit

// MARK: - Agent Trace Log

public struct AgentTraceLog: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let sourceAgent: String
    public let targetAgent: String
    public let action: String
    public let details: String
    
    public init(id: UUID = UUID(), timestamp: Date = Date(), sourceAgent: String, targetAgent: String, action: String, details: String) {
        self.id = id
        self.timestamp = timestamp
        self.sourceAgent = sourceAgent
        self.targetAgent = targetAgent
        self.action = action
        self.details = details
    }
}

// MARK: - Confirmation Request

struct ConfirmationRequest: Identifiable {
    let id = UUID()
    let toolName: String
    let arguments: String
    let riskDescription: String
    var oldContent: String?
    var newContent: String?
    var filePath: String?
    var continuation: CheckedContinuation<Bool, Never>?
}

// MARK: - Chat Message

enum MessageRole {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    var content: String
    var toolEvents: [ToolEvent] = []
    let timestamp: Date
    var isStreaming: Bool = false
    var attachments: [NSImage] = []

    init(id: UUID = UUID(), role: MessageRole, content: String, toolEvents: [ToolEvent] = [], timestamp: Date = Date(), isStreaming: Bool = false, attachments: [NSImage] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.toolEvents = toolEvents
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.attachments = attachments
    }
}

// MARK: - Tool Calling Mode

enum AgentToolCallingMode: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto"
    case required = "Required"
    case disabled = "Chat Only"
    
    var id: String { self.rawValue }
}

// MARK: - Model Preference

enum AgentModelPreference: String, CaseIterable, Identifiable, Codable {
    case localSystem = "Local System (AFM 3)"
    case privateCloud = "Private Cloud Compute"
    case cloudGemini = "Cloud Gemini"
    case localOllama = "Local Ollama"
    case hybrid = "Hybrid (On-Device + PCC Fallback)"
    
    var id: String { self.rawValue }
}

// MARK: - Agent Orchestrator

@Observable
@MainActor
public final class AgentOrchestrator: OrchestratorProvider, ToolEventLogger {
    
    /// Global test mode flag - set to true when running in test mode
    /// This allows tools to provide mock responses without needing environment variables
    static nonisolated(unsafe) var isTestMode: Bool = false

    // MARK: Public State
    var messages: [ChatMessage] = []
    var toolEvents: [ToolEvent] = []
    var isGenerating: Bool = false
    var pendingConfirmation: ConfirmationRequest?
    var modelAvailability: SystemLanguageModel.Availability = .available
    var currentConversationTitle: String = "New Conversation"
    var requireConfirmationForAll: Bool = false
    var agentInstructions: String = AgentSystemPrompt.default
    var toolCallingMode: AgentToolCallingMode = .auto
    var modelPreference: AgentModelPreference = .localSystem
    var pendingAttachments: [NSImage] = []
    var activeTurnToolCallCount: Int = 0
    var activeTerminalOutput: String = ""
    var activePlan: [PlanStep] = []
    var multiAgentModeEnabled: Bool = UserDefaults.standard.bool(forKey: "apex.multiAgentModeEnabled")
    var coordinationTraces: [AgentTraceLog] = []
    var reasoningLogs: [String] = []

    // MARK: SwiftData Persistence
    var modelContext: ModelContext? {
        didSet {
            if let modelContext = modelContext {
                loadOrCreatePermissions(context: modelContext)
            }
        }
    }
    var permissions: AppPermissions?
    var currentConversation: Conversation?
    var terminalOutputs: [UUID: String] = [:]

    // MARK: Private State
    var session: LanguageModelSession?
    private var currentTask: Task<Void, Never>?
    var activeAssistantMessageId: UUID?
    var ptySessions: [UUID: PTYSession] = [:]

    // MARK: Init

    init() {
        checkModelAvailability()
        resetSession()
        
        // Initialize dynamic tool system
        DynamicToolbox.shared.loadTools()
        DynamicToolbox.shared.startWatcher()
        
        // Start proactive workspace and project audits
        startProactiveAudits()
        
        // Start collaborative server if enabled
        if UserDefaults.standard.bool(forKey: "apex.collaborativeServerEnabled") {
            let port = UserDefaults.standard.integer(forKey: "apex.collaborativeServerPort")
            let portVal = port > 0 ? UInt16(port) : 1337
            CollaborativeServer.shared.start(port: portVal)
        }
    }
    
    private func startProactiveAudits() {
        Task {
            _ = await ProjectAuditor.shared.runWorkspaceAudit(at: "~/github-projects/fleet/apps")
            
            while true {
                try? await Task.sleep(for: .seconds(300))
                _ = await ProjectAuditor.shared.runWorkspaceAudit(at: "~/github-projects/fleet/apps")
            }
        }
    }

    // MARK: - App Permissions Handling

    private func loadOrCreatePermissions(context: ModelContext) {
        let descriptor = FetchDescriptor<AppPermissions>()
        do {
            if let existing = try context.fetch(descriptor).first {
                self.permissions = existing
            } else {
                let newPerms = AppPermissions()
                context.insert(newPerms)
                try context.save()
                self.permissions = newPerms
            }
        } catch {
            print("⚠️ Failed to load or create AppPermissions: \(error)")
        }
    }

    nonisolated func isFolderAccessRestricted() -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                return isFolderAccessRestrictedInternal()
            }
        } else {
            return DispatchQueue.main.sync {
                return MainActor.assumeIsolated {
                    return isFolderAccessRestrictedInternal()
                }
            }
        }
    }

    @MainActor
    private func isFolderAccessRestrictedInternal() -> Bool {
        guard let permissions = self.permissions else {
            return true
        }
        return !permissions.musicFolderAllowed ||
               !permissions.desktopFolderAllowed ||
               !permissions.documentsFolderAllowed ||
               !permissions.downloadsFolderAllowed
    }

    nonisolated func isPathAllowed(_ path: String) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                return isPathAllowedInternal(path)
            }
        } else {
            return DispatchQueue.main.sync {
                return MainActor.assumeIsolated {
                    return isPathAllowedInternal(path)
                }
            }
        }
    }

    @MainActor
    private func isPathAllowedInternal(_ path: String) -> Bool {
        guard let permissions = self.permissions else {
            return false
        }
        
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardized.path
        
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.standardized.path
        
        let desktopPath = (homeDir as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homeDir as NSString).appendingPathComponent("Documents")
        let downloadsPath = (homeDir as NSString).appendingPathComponent("Downloads")
        let musicPath = (homeDir as NSString).appendingPathComponent("Music")
        
        if !permissions.desktopFolderAllowed && (standardized == desktopPath || standardized.hasPrefix(desktopPath + "/")) {
            return false
        }
        if !permissions.documentsFolderAllowed && (standardized == documentsPath || standardized.hasPrefix(documentsPath + "/")) {
            return false
        }
        if !permissions.downloadsFolderAllowed && (standardized == downloadsPath || standardized.hasPrefix(downloadsPath + "/")) {
            return false
        }
        if !permissions.musicFolderAllowed && (standardized == musicPath || standardized.hasPrefix(musicPath + "/")) {
            return false
        }
        
        return true
    }

    // MARK: Model Check

    private func checkModelAvailability() {
        let model = SystemLanguageModel.default
        modelAvailability = model.availability
    }

    // MARK: - Semantic RAG Context Hydration

    func getSemanticContext(for prompt: String) -> String {
        print("🔍 RAG: Starting semantic search for '\(prompt)'")
        guard let context = modelContext else {
            print("🔍 RAG: modelContext is nil")
            return ""
        }
        guard let queryVector = EmbeddingHelper.getVector(for: prompt) else {
            print("🔍 RAG: Failed to generate query vector")
            return ""
        }
        
        let descriptor = FetchDescriptor<AgentMemory>()
        guard let allMemories = try? context.fetch(descriptor) else {
            print("🔍 RAG: Failed to fetch memories")
            return ""
        }
        print("🔍 RAG: Found \(allMemories.count) total memories in database")
        if allMemories.isEmpty {
            return ""
        }
        
        var scoredMemories: [(AgentMemory, Double)] = []
        for memory in allMemories {
            guard let data = memory.embeddingData,
                  let vector = EmbeddingHelper.deserialize(data) else {
                print("🔍 RAG: Memory '\(memory.key)' has no embeddingData or deserialization failed")
                continue
            }
            let score = EmbeddingHelper.cosineSimilarity(v1: queryVector, v2: vector)
            print("🔍 RAG: Candidate '\(memory.key)' score: \(score)")
            if score > 0.4 {
                scoredMemories.append((memory, score))
            }
        }
        
        scoredMemories.sort { $0.1 > $1.1 }
        
        let topMatches = scoredMemories.prefix(3)
        if topMatches.isEmpty {
            return ""
        }
        
        var contextStr = "\n\n🧠 Related Long-term Memories:\n"
        for (memory, score) in topMatches {
            contextStr += "- [Memory topic: '\(memory.key)' (relevance: \(String(format: "%.2f", score)))]: \(memory.val)\n"
        }
        return contextStr
    }

    // MARK: Session Management

    func resetSession() {
        rehydrateSession()
    }

    func createModelInstance() -> any LanguageModel {
        switch modelPreference {
        case .localSystem:
            return SystemLanguageModel.default
        case .privateCloud:
            return PrivateCloudComputeLanguageModel()
        case .cloudGemini:
            let apiKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
            return CloudGeminiLanguageModel(apiKey: apiKey)
        case .localOllama:
            let host = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
            return LocalOllamaLanguageModel(hostURL: host)
        case .hybrid:
            // Hybrid defaults to local system model for general orchestrator tasks
            return SystemLanguageModel.default
        }
    }

    private func prunedContent(_ content: String, maxChars: Int = 1500) -> String {
        if content.count <= maxChars {
            return content
        }
        let keepLength = maxChars - 100
        let prefix = content.prefix(keepLength)
        return prefix + "\n\n[... content truncated to conserve context space ...]"
    }

    private func rehydrateSession() {
    let instructions = multiAgentModeEnabled ? SupervisorPrompt.system : agentInstructions
        
        // Rehydrate model session history using Transcript.Entry
        var transcriptEntries: [Transcript.Entry] = []
        let systemInstructions = Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: instructions))],
            toolDefinitions: []
        )
        transcriptEntries.append(.instructions(systemInstructions))

        // Apply Sliding Rehydration Window: only rehydrate the last 10 messages (5 user-assistant turns)
        let rehydrationMessages = messages.suffix(10)
        for msg in rehydrationMessages {
            let truncated = prunedContent(msg.content)
            switch msg.role {
            case .user:
                let promptSegment = Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: truncated))])
                transcriptEntries.append(.prompt(promptSegment))
            case .assistant:
                let responseSegment = Transcript.Response(
                    id: UUID().uuidString,
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: truncated))]
                )
                transcriptEntries.append(.response(responseSegment))
            case .system:
                let instSegment = Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: truncated))],
                    toolDefinitions: []
                )
                transcriptEntries.append(.instructions(instSegment))
            }
        }

        let transcript = Transcript(entries: transcriptEntries)

        let mode: GenerationOptions.ToolCallingMode = switch toolCallingMode {
        case .auto: .allowed
        case .required: .required
        case .disabled: .disallowed
        }

        switch modelPreference {
        case .localSystem:
            let model = SystemLanguageModel.default
            if multiAgentModeEnabled {
                let profile = SupervisorAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self)
                session = LanguageModelSession(profile: profile, history: transcript)
            } else {
                let profile = ApexAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self)
                session = LanguageModelSession(profile: profile, history: transcript)
            }
            
        case .privateCloud:
            let model = PrivateCloudComputeLanguageModel()
            if multiAgentModeEnabled {
                let profile = SupervisorAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self)
                session = LanguageModelSession(profile: profile, history: transcript)
            } else {
                let profile = ApexAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self)
                session = LanguageModelSession(profile: profile, history: transcript)
            }
            
        case .cloudGemini:
            let apiKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
            let model = CloudGeminiLanguageModel(apiKey: apiKey)
            if multiAgentModeEnabled {
                let profile = SupervisorAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self)
                session = LanguageModelSession(profile: profile, history: transcript)
            } else {
                let profile = ApexAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self)
                session = LanguageModelSession(profile: profile, history: transcript)
            }
            
        case .localOllama:
            let host = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
            let model = LocalOllamaLanguageModel(hostURL: host)
            if multiAgentModeEnabled {
                let profile = SupervisorAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self)
                session = LanguageModelSession(profile: profile, history: transcript)
            } else {
                let profile = ApexAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self)
                session = LanguageModelSession(profile: profile, history: transcript)
            }
            
        case .hybrid:
            if multiAgentModeEnabled {
                // Supervisor (Apex Prime) runs locally on-device
                let model = SystemLanguageModel.default
                let profile = SupervisorAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self)
                session = LanguageModelSession(profile: profile, history: transcript)
            } else {
                // Single-agent mode uses Private Cloud Compute for deep reasoning (writing code / research)
                let model = PrivateCloudComputeLanguageModel()
                let profile = ApexAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self)
                session = LanguageModelSession(profile: profile, history: transcript)
            }
        }
        
        session?.prewarm()
    }

    var allTools: [any Tool] {
        [
            ShellTool(orchestrator: self),
            FileReadTool(orchestrator: self),
            FileWriteTool(orchestrator: self),
            ListDirectoryTool(orchestrator: self),
            CreateDirectoryTool(orchestrator: self),
            DeleteFileTool(orchestrator: self),
            MoveFileTool(orchestrator: self),
            WebSearchTool(orchestrator: self),
            AppleScriptTool(orchestrator: self),
            ScreenshotTool(orchestrator: self),
            ClipboardReadTool(orchestrator: self),
            ClipboardWriteTool(orchestrator: self),
            NotificationTool(orchestrator: self),
            SystemInfoTool(orchestrator: self),
            ProcessListTool(orchestrator: self),
            GetFrontmostAppTool(orchestrator: self),
            StoreMemoryTool(orchestrator: self),
            SearchMemoryTool(orchestrator: self),
            ApplicationControlTool(orchestrator: self),
            AccessibilityControlTool(orchestrator: self),
            BrowserAutomationTool(orchestrator: self),
            UpdatePlanTool(orchestrator: self),
            ProjectAuditTool(orchestrator: self),
            DelegateTaskTool(orchestrator: self),
            AnalyzeImageTool(orchestrator: self),
            DetectImageTextTool(orchestrator: self),
            ConveneMeetingTool(orchestrator: self),
            CreateSkillTool(orchestrator: self),
            RunWorkflowTool(orchestrator: self),
            DynamicToolCallTool(orchestrator: self)
        ]
    }

    func startNewConversation() {
        messages = []
        toolEvents = []
        coordinationTraces = []
        reasoningLogs = []
        currentConversationTitle = "New Conversation"
        currentConversation = nil
        activeTerminalOutput = ""
        resetSession()
    }

    func logReasoning(_ thought: String) {
        let timestamped = "[\(Date().formatted())] \(thought)"
        reasoningLogs.append(timestamped)
        print("[Reasoning] \(thought)")
    }

    func updateInstructions(_ newInstructions: String) {
        agentInstructions = newInstructions
        resetSession()
    }

    // MARK: Send Message

    func sendMessage(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !pendingAttachments.isEmpty else { return }
        guard !isGenerating else { return }

        // Stop any active text-to-speech playback
        VoiceController.shared.stopSpeaking()

        activeTurnToolCallCount = 0
        isGenerating = true

        Task {
            // 1. Asynchronously check and compact context if needed
            await compactContextIfNeeded()
            
            // 2. Hydrate/reset the model session with the compacted state
            resetSession()
            
            // 3. Launch the main response generation
            await runMessageGeneration(text: trimmedText)
        }
    }

    @MainActor
    private func createCompactionSession(model: any LanguageModel, instructions: String) -> LanguageModelSession {
        func helper<M: LanguageModel>(_ m: M) -> LanguageModelSession {
            let profile = ApexAgentProfile(
                instructions: instructions,
                model: m,
                toolCallingMode: .disallowed,
                orchestrator: self
            )
            return LanguageModelSession(profile: profile, history: Transcript(entries: []))
        }
        return helper(model)
    }

    @MainActor
    func compactContextIfNeeded() async {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        guard totalChars > 12000 else { return }
        guard messages.count > 5 else { return }
        
        let messagesToCompact = messages.dropLast(4)
        let remainingMessages = messages.suffix(4)
        
        var compactionText = "Summarize the following chat history details and results concisely to preserve context:\n"
        for msg in messagesToCompact {
            let roleName = msg.role == .user ? "User" : "Assistant"
            compactionText += "[\(roleName)]: \(msg.content)\n\n"
        }
        
        let model = createModelInstance()
        let session = createCompactionSession(model: model, instructions: "Summarize chat logs concisely. Focus on facts, status, file paths, and results.")
        
        do {
            let stream = session.streamResponse(to: compactionText)
            var summary = ""
            for try await response in stream {
                summary = response.content
            }
            
            if !summary.isEmpty {
                let summaryMsg = ChatMessage(role: .system, content: "Summary of earlier conversation:\n\(summary)")
                var newMessages = [summaryMsg]
                newMessages.append(contentsOf: remainingMessages)
                self.messages = newMessages
                
                // Sync to SwiftData
                if let conv = self.currentConversation, let context = self.modelContext {
                    let remainingIds = remainingMessages.map { $0.id }
                    
                    // Filter the database messages to remove compacted ones
                    for dbMsg in conv.messages {
                        if !remainingIds.contains(dbMsg.id) {
                            context.delete(dbMsg)
                        }
                    }
                    
                    // Add summary message to DB
                    let dbSummaryMsg = Message(role: .system, content: "Summary of earlier conversation:\n\(summary)")
                    dbSummaryMsg.conversation = conv
                    context.insert(dbSummaryMsg)
                    
                    conv.updatedAt = Date()
                    try? context.save()
                }
                
                print("Context compacted successfully! Reduced message history size.")
            }
        } catch {
            print("Failed to run background context compaction: \(error)")
        }
    }

    @MainActor
    private func runMessageGeneration(text: String) async {
        // Check if we need to initialize a SwiftData Conversation
        if currentConversation == nil {
            let title = text.isEmpty ? "Image Attachment" : String(text.prefix(50))
            let newConv = Conversation(title: title)
            currentConversation = newConv
            currentConversationTitle = title
            if let context = modelContext {
                context.insert(newConv)
                try? context.save()
            }
        }

        let historyMessages = messages
        let attachmentsToSend = pendingAttachments
        pendingAttachments = []

        // Add user message
        let userMsg = ChatMessage(role: .user, content: text, attachments: attachmentsToSend)
        messages.append(userMsg)

        // Save user message to SwiftData
        if let conv = currentConversation, let context = modelContext {
            let dbAttachments = attachmentsToSend.compactMap { $0.pngData }
            let dbUserMsg = Message(role: .user, content: text, attachmentsData: dbAttachments)
            dbUserMsg.id = userMsg.id
            dbUserMsg.conversation = conv
            context.insert(dbUserMsg)
            conv.updatedAt = Date()
            try? context.save()
        }

        // Add placeholder assistant message
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)
        activeAssistantMessageId = assistantMsg.id

        Task {
            await ScreenStreamer.shared.startCapture()
        }

        currentTask = Task {
            let engine: any AgentEngine
            switch self.modelPreference {
            case .localSystem, .privateCloud, .cloudGemini, .localOllama, .hybrid:
                engine = NativeAppleEngine(orchestrator: self)
            }

            do {
                let semanticContext = self.getSemanticContext(for: text)
                let finalInstructions = self.agentInstructions + semanticContext
                
                try await engine.streamResponse(
                    prompt: text,
                    attachments: userMsg.attachments,
                    history: historyMessages,
                    instructions: finalInstructions,
                    toolCallingMode: self.toolCallingMode,
                    onUpdate: { @MainActor partialContent in
                        guard let id = self.activeAssistantMessageId else { return }
                        if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                            self.messages[idx].content = partialContent
                        }
                    }
                )

                // Save assistant message to SwiftData
                if let conv = self.currentConversation, let context = self.modelContext {
                    guard let id = self.activeAssistantMessageId else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                        let dbAssistantMsg = Message(role: .assistant, content: self.messages[idx].content)
                        dbAssistantMsg.id = self.messages[idx].id
                        dbAssistantMsg.conversation = conv
                        context.insert(dbAssistantMsg)
                        conv.updatedAt = Date()
                        try? context.save()
                    }
                }

                // If Voice Mode is enabled, speak the response
                if UserDefaults.standard.bool(forKey: "apex.voiceModeEnabled") {
                    guard let id = self.activeAssistantMessageId else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                        VoiceController.shared.speak(self.messages[idx].content)
                    }
                }
            } catch {
                if let id = self.activeAssistantMessageId, let idx = self.messages.firstIndex(where: { $0.id == id }) {
                    self.messages[idx].content = "⚠️ Error: \(error.localizedDescription)"
                }

                // Save error message to SwiftData
                if let conv = self.currentConversation, let context = self.modelContext {
                    guard let id = self.activeAssistantMessageId else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                        let dbAssistantMsg = Message(role: .assistant, content: self.messages[idx].content)
                        dbAssistantMsg.id = self.messages[idx].id
                        dbAssistantMsg.conversation = conv
                        context.insert(dbAssistantMsg)
                        conv.updatedAt = Date()
                        try? context.save()
                    }
                }
            }

            if let id = self.activeAssistantMessageId, let idx = self.messages.firstIndex(where: { $0.id == id }) {
                self.messages[idx].isStreaming = false
            }
            self.activeAssistantMessageId = nil
            self.isGenerating = false
            ScreenStreamer.shared.stopCapture()
        }
    }

    func cancelGeneration() {
        currentTask?.cancel()
        currentTask = nil
        
        // Stop any active speech playback
        VoiceController.shared.stopSpeaking()
        
        if let id = activeAssistantMessageId, let idx = messages.firstIndex(where: { $0.id == id }), messages[idx].isStreaming {
            messages[idx].isStreaming = false
            // Save partially generated message to SwiftData
            if let conv = currentConversation, let context = modelContext {
                let dbAssistantMsg = Message(role: .assistant, content: messages[idx].content)
                dbAssistantMsg.id = messages[idx].id
                dbAssistantMsg.conversation = conv
                context.insert(dbAssistantMsg)
                conv.updatedAt = Date()
                try? context.save()
            }
        }
        activeAssistantMessageId = nil
        isGenerating = false
        ScreenStreamer.shared.stopCapture()
    }

    // MARK: SwiftData Load & Delete

    func loadConversation(_ conversation: Conversation) {
        cancelGeneration()

        currentConversation = conversation
        currentConversationTitle = conversation.title

        let sortedDbMessages = conversation.messages.sorted(by: { $0.timestamp < $1.timestamp })
        messages = sortedDbMessages.map { msg in
            ChatMessage(id: msg.id, role: msg.role, content: msg.content, timestamp: msg.timestamp, attachments: msg.attachments)
        }

        toolEvents = []
        activeTerminalOutput = terminalOutputs[conversation.id] ?? ""

        rehydrateSession()
    }

    func deleteConversation(_ conversation: Conversation) {
        ptySessions[conversation.id]?.cleanup()
        ptySessions[conversation.id] = nil
        terminalOutputs[conversation.id] = nil
        
        if let context = modelContext {
            context.delete(conversation)
            try? context.save()
        }
        
        if currentConversation?.id == conversation.id {
            startNewConversation()
        }
    }

    // MARK: - PTY Management
    
    func ptySession(for conversationId: UUID) async -> PTYSession {
        if let session = ptySessions[conversationId] {
            return session
        }
        do {
            let workspace = FileManager.default.currentDirectoryPath
            let session = try await PTYSession(workspacePath: workspace, orchestrator: self)
            ptySessions[conversationId] = session
            session.onOutput = { [weak self] output in
                DispatchQueue.main.async {
                    self?.appendTerminalOutput(conversationId: conversationId, text: output)
                }
            }
            return session
        } catch {
            print("Failed to initialize PTY session: \(error)")
            let fallback = try! await PTYSession(workspacePath: FileManager.default.currentDirectoryPath, orchestrator: self)
            ptySessions[conversationId] = fallback
            return fallback
        }
    }

    func resetPTYSession(for conversationId: UUID) async {
        ptySessions[conversationId]?.cleanup()
        ptySessions[conversationId] = nil
        _ = await ptySession(for: conversationId)
    }

    func appendTerminalOutput(conversationId: UUID, text: String) {
        let current = terminalOutputs[conversationId] ?? ""
        var updated = current + text
        if updated.count > 50000 {
            updated = String(updated.suffix(50000))
        }
        terminalOutputs[conversationId] = updated
        if currentConversation?.id == conversationId {
            activeTerminalOutput = updated
        }
    }

    func captureAndAttachScreenshot() async {
        let tool = ScreenshotTool(orchestrator: self)
        let timestamp = Int(Date().timeIntervalSince1970)
        let tempDir = NSTemporaryDirectory()
        let path = tempDir + "apex_temp_screenshot_\(timestamp).png"
        do {
            let result = try await tool.call(arguments: ScreenshotTool.Arguments(savePath: path, windowOnly: false))
            if result.contains("✅") {
                if let image = NSImage(contentsOfFile: path) {
                    self.pendingAttachments.append(image)
                }
            }
        } catch {
            print("Failed to capture screenshot: \(error)")
        }
    }

    func executeToolByName(name: String, jsonArguments: String) async throws -> String {
        let decoder = JSONDecoder()
        guard let data = jsonArguments.data(using: .utf8) else {
            throw NSError(domain: "AgentOrchestrator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON arguments"])
        }

        switch name {
        case "run_shell_command":
            let args = try decoder.decode(ShellTool.Arguments.self, from: data)
            let tool = ShellTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "read_file":
            let args = try decoder.decode(FileReadTool.Arguments.self, from: data)
            let tool = FileReadTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "write_file":
            let args = try decoder.decode(FileWriteTool.Arguments.self, from: data)
            let tool = FileWriteTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "list_directory":
            let args = try decoder.decode(ListDirectoryTool.Arguments.self, from: data)
            let tool = ListDirectoryTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "create_directory":
            let args = try decoder.decode(CreateDirectoryTool.Arguments.self, from: data)
            let tool = CreateDirectoryTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "delete_file":
            let args = try decoder.decode(DeleteFileTool.Arguments.self, from: data)
            let tool = DeleteFileTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "move_file":
            let args = try decoder.decode(MoveFileTool.Arguments.self, from: data)
            let tool = MoveFileTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "web_search":
            let args = try decoder.decode(WebSearchTool.Arguments.self, from: data)
            let tool = WebSearchTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "run_applescript":
            let args = try decoder.decode(AppleScriptTool.Arguments.self, from: data)
            let tool = AppleScriptTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "take_screenshot":
            let args = try decoder.decode(ScreenshotTool.Arguments.self, from: data)
            let tool = ScreenshotTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "read_clipboard":
            let args = try decoder.decode(ClipboardReadTool.Arguments.self, from: data)
            let tool = ClipboardReadTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "write_clipboard":
            let args = try decoder.decode(ClipboardWriteTool.Arguments.self, from: data)
            let tool = ClipboardWriteTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "send_notification":
            let args = try decoder.decode(NotificationTool.Arguments.self, from: data)
            let tool = NotificationTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "get_system_info":
            let args = try decoder.decode(SystemInfoTool.Arguments.self, from: data)
            let tool = SystemInfoTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "get_running_processes":
            let args = try decoder.decode(ProcessListTool.Arguments.self, from: data)
            let tool = ProcessListTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "get_frontmost_app":
            let args = try decoder.decode(GetFrontmostAppTool.Arguments.self, from: data)
            let tool = GetFrontmostAppTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "store_memory":
            let args = try decoder.decode(StoreMemoryTool.Arguments.self, from: data)
            let tool = StoreMemoryTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "search_memory":
            let args = try decoder.decode(SearchMemoryTool.Arguments.self, from: data)
            let tool = SearchMemoryTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "control_app":
            let args = try decoder.decode(ApplicationControlTool.Arguments.self, from: data)
            let tool = ApplicationControlTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "control_accessibility":
            let args = try decoder.decode(AccessibilityControlTool.Arguments.self, from: data)
            let tool = AccessibilityControlTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "control_browser":
            let args = try decoder.decode(BrowserAutomationTool.Arguments.self, from: data)
            let tool = BrowserAutomationTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "update_plan":
            let args = try decoder.decode(UpdatePlanTool.Arguments.self, from: data)
            let tool = UpdatePlanTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "audit_projects":
            let args = try decoder.decode(ProjectAuditTool.Arguments.self, from: data)
            let tool = ProjectAuditTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "delegate_task":
            let args = try decoder.decode(DelegateTaskTool.Arguments.self, from: data)
            let tool = DelegateTaskTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "analyze_image":
            let args = try decoder.decode(AnalyzeImageTool.Arguments.self, from: data)
            let tool = AnalyzeImageTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "detect_image_text":
            let args = try decoder.decode(DetectImageTextTool.Arguments.self, from: data)
            let tool = DetectImageTextTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "convene_meeting":
            let args = try decoder.decode(ConveneMeetingTool.Arguments.self, from: data)
            let tool = ConveneMeetingTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "create_skill":
            let args = try decoder.decode(CreateSkillTool.Arguments.self, from: data)
            let tool = CreateSkillTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "run_workflow":
            let args = try decoder.decode(RunWorkflowTool.Arguments.self, from: data)
            let tool = RunWorkflowTool(orchestrator: self)
            return try await tool.call(arguments: args)
        case "execute_dynamic_tool":
            let args = try decoder.decode(DynamicToolCallTool.Arguments.self, from: data)
            let tool = DynamicToolCallTool(orchestrator: self)
            return try await tool.call(arguments: args)
        default:
            if DynamicToolbox.shared.dynamicTools[name] != nil {
                return try await DynamicToolbox.shared.executeTool(name: name, jsonArguments: jsonArguments)
            }
            throw NSError(domain: "AgentOrchestrator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
        }
    }
    
    @MainActor
    func runExplicitCodingWorkflow(topic: String) async throws -> String {
        let graph = StateGraph(name: "Explicit Coding & Review Pipeline")
        
        // Add Codex (Developer) node
        graph.addNode(name: "Codex") { state in
            let developerTool = DelegateTaskTool(orchestrator: self)
            let args = DelegateTaskTool.Arguments(agentType: "developer", taskDescription: "Implement or fix the following: \(topic). Logs and compiler errors so far: \(state.values["logs"] as? String ?? "None")")
            do {
                let output = try await developerTool.call(arguments: args)
                var nextState = state
                nextState.values["logs"] = (nextState.values["logs"] as? String ?? "") + "\n[Codex]: \(output)"
                return .success(output: output, nextState: nextState)
            } catch {
                return .failure(error: error.localizedDescription, nextState: state)
            }
        }
        
        // Add Auditor (Linter) node
        graph.addNode(name: "Auditor") { state in
            let linterTool = DelegateTaskTool(orchestrator: self)
            let args = DelegateTaskTool.Arguments(agentType: "linter", taskDescription: "Audit and review the changes made for syntax issues and style guidelines.")
            do {
                let output = try await linterTool.call(arguments: args)
                var nextState = state
                nextState.values["logs"] = (nextState.values["logs"] as? String ?? "") + "\n[Auditor]: \(output)"
                if output.contains("warning") || output.contains("error") {
                    return .failure(error: output, nextState: nextState)
                }
                return .success(output: output, nextState: nextState)
            } catch {
                return .failure(error: error.localizedDescription, nextState: state)
            }
        }
        
        // Add Nexus (Executor) node
        graph.addNode(name: "Nexus") { state in
            let executorTool = DelegateTaskTool(orchestrator: self)
            let args = DelegateTaskTool.Arguments(agentType: "executor", taskDescription: "Compile the project and run unit tests. Report if there are compile errors or failing tests.")
            do {
                let output = try await executorTool.call(arguments: args)
                var nextState = state
                nextState.values["logs"] = (nextState.values["logs"] as? String ?? "") + "\n[Nexus]: \(output)"
                if output.contains("TEST FAILED") || output.contains("error:") || output.contains("Command failed") {
                    return .failure(error: output, nextState: nextState)
                }
                return .success(output: output, nextState: nextState)
            } catch {
                return .failure(error: error.localizedDescription, nextState: state)
            }
        }
        
        graph.entryNode = "Codex"
        
        // Codex passes -> go to Auditor to lint check
        graph.addEdge(from: "Codex") { output, isSuccess, state in
            return (isSuccess ? "Auditor" : nil, state)
        }
        
        // Auditor passes -> go to Nexus to build; fails -> return to Codex to fix lint issues (limit loops to prevent infinite)
        graph.addEdge(from: "Auditor") { output, isSuccess, state in
            let loopCount = state.values["audit_loops"] as? Int ?? 0
            var nextState = state
            if !isSuccess && loopCount < 2 {
                nextState.values["audit_loops"] = loopCount + 1
                return ("Codex", nextState)
            }
            return ("Nexus", nextState)
        }
        
        // Nexus fails -> go back to Codex to fix build errors; passes -> terminate (success)
        graph.addEdge(from: "Nexus") { output, isSuccess, state in
            let loopCount = state.values["build_loops"] as? Int ?? 0
            var nextState = state
            if !isSuccess && loopCount < 2 {
                nextState.values["build_loops"] = loopCount + 1
                return ("Codex", nextState)
            }
            return (nil, nextState)
        }
        
        // Append entry workflow announcement
        let startMsg = "🏁 Starting Explicit State-Graph Workflow: [Codex ➡️ Auditor ➡️ Nexus]"
        let chatMsg = ChatMessage(role: .assistant, content: startMsg)
        self.messages.append(chatMsg)
        
        let finalState = try await graph.execute(initialState: StateGraphState()) { nodeName in
            print("StateGraph Transitioning to node: \(nodeName)")
        }
        
        let finalLogs = finalState.values["logs"] as? String ?? "No logs generated."
        return finalLogs
    }

    // MARK: - OrchestratorProvider Conformance
    
    public var orchestrator: AgentOrchestrator { self }
    
    // MARK: - ToolEventLogger Conformance
    
    public func logToolStart(name: String, arguments: String) {
        activeTurnToolCallCount += 1
        let event = ToolEvent(toolName: name, arguments: arguments)
        logToolEvent(event)
    }
    
    public func logToolEvent(_ event: ToolEvent) {
        toolEvents.insert(event, at: 0) // Most recent first
        // Limit to 200 events
        if toolEvents.count > 200 {
            toolEvents = Array(toolEvents.prefix(200))
        }
    }
    
    public func logToolEnd(name: String, result: String, status: ToolStatus) {
        if let index = toolEvents.firstIndex(where: { $0.toolName == name && $0.result == nil }) {
            toolEvents[index].result = result
            toolEvents[index].status = status
        }
    }
    
    public func updateToolStatus(name: String, status: ToolStatus) {
        if let index = toolEvents.firstIndex(where: { $0.toolName == name && $0.result == nil }) {
            toolEvents[index].status = status
        }
    }
    
    public func shouldConfirmTool(name: String) -> Bool {
        if ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1" { return false }
        if requireConfirmationForAll { return true }
        let dangerousTools = ["run_shell_command", "delete_file", "write_file", "run_applescript"]
        return dangerousTools.contains(name)
    }
    
    public func requestConfirmation(
        toolName: String,
        arguments: String,
        riskDescription: String,
        oldContent: String? = nil,
        newContent: String? = nil,
        filePath: String? = nil
    ) async -> Bool {
        if AgentOrchestrator.isTestMode {
            return true
        }
        return await withCheckedContinuation { continuation in
            let request = ConfirmationRequest(
                toolName: toolName,
                arguments: arguments,
                riskDescription: riskDescription,
                oldContent: oldContent,
                newContent: newContent,
                filePath: filePath,
                continuation: continuation
            )
            pendingConfirmation = request
            
            // Auto-deny after 60 seconds
            Task {
                try? await Task.sleep(for: .seconds(60))
                if self.pendingConfirmation?.id == request.id {
                    self.resolveConfirmation(approved: false)
                }
            }
        }
    }
    
    public func resolveConfirmation(approved: Bool) {
        guard let pending = pendingConfirmation else { return }
        pending.continuation?.resume(returning: approved)
        pendingConfirmation = nil
    }
}

// MARK: - Apex Agent Dynamic Profile

struct ApexAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    let toolCallingMode: GenerationOptions.ToolCallingMode
    let orchestrator: OrchestratorProvider
    
    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider) {
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
    }

    private var shellTool: ShellTool { ShellTool(orchestrator: orchestrator) }
    private var fileReadTool: FileReadTool { FileReadTool(orchestrator: orchestrator) }
    private var fileWriteTool: FileWriteTool { FileWriteTool(orchestrator: orchestrator) }
    private var listDirectoryTool: ListDirectoryTool { ListDirectoryTool(orchestrator: orchestrator) }
    private var createDirectoryTool: CreateDirectoryTool { CreateDirectoryTool(orchestrator: orchestrator) }
    private var deleteFileTool: DeleteFileTool { DeleteFileTool(orchestrator: orchestrator) }
    private var moveFileTool: MoveFileTool { MoveFileTool(orchestrator: orchestrator) }
    private var webSearchTool: WebSearchTool { WebSearchTool(orchestrator: orchestrator) }
    private var appleScriptTool: AppleScriptTool { AppleScriptTool(orchestrator: orchestrator) }
    private var screenshotTool: ScreenshotTool { ScreenshotTool(orchestrator: orchestrator) }
    private var clipboardReadTool: ClipboardReadTool { ClipboardReadTool(orchestrator: orchestrator) }
    private var clipboardWriteTool: ClipboardWriteTool { ClipboardWriteTool(orchestrator: orchestrator) }
    private var notificationTool: NotificationTool { NotificationTool(orchestrator: orchestrator) }
    private var systemInfoTool: SystemInfoTool { SystemInfoTool(orchestrator: orchestrator) }
    private var processListTool: ProcessListTool { ProcessListTool(orchestrator: orchestrator) }
    private var getFrontmostAppTool: GetFrontmostAppTool { GetFrontmostAppTool(orchestrator: orchestrator) }
    private var storeMemoryTool: StoreMemoryTool { StoreMemoryTool(orchestrator: orchestrator) }
    private var searchMemoryTool: SearchMemoryTool { SearchMemoryTool(orchestrator: orchestrator) }
    private var applicationControlTool: ApplicationControlTool { ApplicationControlTool(orchestrator: orchestrator) }
    private var accessibilityControlTool: AccessibilityControlTool { AccessibilityControlTool(orchestrator: orchestrator) }
    private var browserAutomationTool: BrowserAutomationTool { BrowserAutomationTool(orchestrator: orchestrator) }
    private var updatePlanTool: UpdatePlanTool { UpdatePlanTool(orchestrator: orchestrator) }
    private var projectAuditTool: ProjectAuditTool { ProjectAuditTool(orchestrator: orchestrator) }
    private var createSkillTool: CreateSkillTool { CreateSkillTool(orchestrator: orchestrator) }
    private var dynamicToolCallTool: DynamicToolCallTool { DynamicToolCallTool(orchestrator: orchestrator) }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            
            shellTool
            fileReadTool
            fileWriteTool
            listDirectoryTool
            createDirectoryTool
            deleteFileTool
            moveFileTool
            webSearchTool
            appleScriptTool
            screenshotTool
            clipboardReadTool
            clipboardWriteTool
            notificationTool
            systemInfoTool
            processListTool
            getFrontmostAppTool
            storeMemoryTool
            searchMemoryTool
            applicationControlTool
            accessibilityControlTool
            browserAutomationTool
            updatePlanTool
            projectAuditTool
            createSkillTool
            dynamicToolCallTool
        }
        .model(model)
        .toolCallingMode(toolCallingMode)
    }
}
