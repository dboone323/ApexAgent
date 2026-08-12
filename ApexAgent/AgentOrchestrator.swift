import Foundation
import Security
import FoundationModels
import Observation
import SwiftData
import AppKit
import SharedKit
import os

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
    var id: UUID = UUID()
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
    case localMLX = "Local MLX"
    case hybrid = "Hybrid (On-Device + PCC Fallback)"

    var id: String { self.rawValue }
}

// MARK: - Agent Orchestrator

@Observable
@MainActor
public final class AgentOrchestrator: OrchestratorProvider, ToolEventLogger {


    /// Check if Private Cloud Compute is available by verifying the process has the required entitlement.
    /// Returns false when running in CLI/test environments without code signing.
    nonisolated static func isPrivateCloudComputeAvailable() -> Bool {
        let task = SecTaskCreateFromSelf(nil)
        guard let task else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.private-cloud-compute" as CFString, nil)
        return value != nil
    }

    // MARK: Constants
    private static let ragSimilarityThreshold: Double = 0.4
    private static let ragTopK: Int = 3
    private static let contextPruningMaxChars: Int = 1500
    private static let rehydrationWindowSize: Int = 10
    private static let contextCompactionThreshold: Int = 12000
    private static let terminalOutputCap: Int = 50000
    private static let maxToolEventCount: Int = 200
    private static let confirmationTimeoutSeconds: TimeInterval = 60
    private static let dangerousToolNames: Set<String> = ["run_shell_command", "delete_file", "write_file", "run_applescript", "create_skill"]
    private static let defaultOllamaURLString = "http://localhost:11434"
    private static let iso8601Formatter = ISO8601DateFormatter()

    // MARK: Public State
    // NOTE: these MUST NOT carry a `didSet`/`willSet`. The @Observable macro
    // opts a property OUT of observation when it has a custom accessor, which
    // silently breaks SwiftUI tracking — the chat would then show the agent's
    // reply in the logs but never re-render the bubble (stuck on "thinking").
    // The legacy onStateChanged push (used only by ApexGatewayServer for the
    // remote/collaborative bridge) is fired explicitly in sendMessage's defer
    // instead of via didSet.
    private(set) var messages: [ChatMessage] = []
    private(set) var toolEvents: [ToolEvent] = []
    private(set) var isGenerating: Bool = false
    // Internal (not private) setter: ViewHostingTests seeds a pending request
    // to drive ConfirmationOverlay's populated branch — requestConfirmation()
    // short-circuits under APEX_TEST_MODE so tests can't reach it otherwise.
    var pendingConfirmation: ConfirmationRequest?
    var modelAvailability: SystemLanguageModel.Availability = .available
    var currentConversationTitle: String = "New Conversation"
    var requireConfirmationForAll: Bool = false
    var agentInstructions: String = AgentSystemPrompt.default
    var proactiveAuditResult: String = ""
    var toolCallingMode: AgentToolCallingMode = .auto
    var modelPreference: AgentModelPreference = .localSystem
    // Default is .localSystem (on-device Apple Foundation Models) because the
    // native path works on macOS 27 beta 5 (build 26A5406g/26A5406e): a runtime
    // probe confirms `SystemLanguageModel.default.respond(to:)` returns real
    // text (~7s) with no SIGSEGV and no empty output. OllamaAgentEngine /
    // MLXAgentEngine remain selectable fallbacks via the Settings provider
    // picker for when a local model server (Ollama/MLX-LM) is preferred. Earlier
    // betas (26A5388g) SIGSEGV'd the executor channel, which is why the default
    // was temporarily .localOllama — that workaround is no longer needed.
    // model server over HTTP and run the same tool pipeline, so the agent
    // works end-to-end on this beta too.
    var pendingAttachments: [NSImage] = []
    private(set) var activeTurnToolCallCount: Int = 0
    var activeTerminalOutput: String = ""
    private(set) var activePlan: [PlanStep] = []
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
    public var onStateChanged: (() -> Void)?
    public var confirmationGateway: ((String, String, String) async -> Bool)?

    private(set) var session: LanguageModelSession?
    @ObservationIgnored private nonisolated(unsafe) var currentTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var auditTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var confirmationTimeoutTask: Task<Void, Never>?
    private(set) var activeAssistantMessageId: UUID?
    private var ptySessions: [UUID: PTYSession] = [:]
    private var _allTools: [AnyExecutableTool]?

    // MARK: Init

    init() {
        MCPManager.shared.orchestrator = self
        DynamicToolbox.shared.orchestrator = self

        checkModelAvailability()
        resetSession()

        // Initialize dynamic tool system
        DynamicToolbox.shared.loadTools()

        #if DEBUG
        // In tests, skip the long-lived FS watcher + proactive audit loop so the
        // test helper process can exit. Only enabled when APEX_ENABLE_FS_WATCHER=1.
        if getenv("APEX_ENABLE_FS_WATCHER").flatMap({ String(cString: $0) }) == "1" {
            DynamicToolbox.shared.startWatcher()
            startProactiveAudits()
        }
        #else
        DynamicToolbox.shared.startWatcher()
        startProactiveAudits()
        #endif

        // Start collaborative server if enabled
        if UserDefaults.standard.bool(forKey: "apex.collaborativeServerEnabled") {
            let port = UserDefaults.standard.integer(forKey: "apex.collaborativeServerPort")
            let portVal = port > 0 ? UInt16(port) : 1337
            CollaborativeServer.shared.start(port: portVal)
        }
    }

    deinit {
        auditTask?.cancel()
        currentTask?.cancel()
        confirmationTimeoutTask?.cancel()
    }

    private func startProactiveAudits() {
        #if DEBUG
        if getenv("APEX_ENABLE_FS_WATCHER").flatMap({ String(cString: $0) }) == "1" {
            return
        }
        #endif
        auditTask = Task {
            let workspace = Self.proactiveAuditWorkspacePath()
            _ = await ProjectAuditor.shared.runWorkspaceAudit(at: workspace)

            while true {
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(300))
                _ = await ProjectAuditor.shared.runWorkspaceAudit(at: Self.proactiveAuditWorkspacePath())
            }
        }
    }

    /// Resolves the workspace directory that the proactive audit loop scans.
    /// No hardcoded developer paths: user-configured setting → APEX_WORKSPACE →
    /// ~/Developer (if present) → the user's home directory.
    nonisolated static func proactiveAuditWorkspacePath() -> String {
        if let configured = UserDefaults.standard.string(forKey: "apex.workspacePath"),
           !configured.isEmpty,
           FileManager.default.fileExists(atPath: configured) {
            return configured
        }
        if let envPath = ProcessInfo.processInfo.environment["APEX_WORKSPACE"],
           !envPath.isEmpty {
            return envPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let devPath = home.appendingPathComponent("Developer").path
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return home.path
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

    @MainActor
    func isFolderAccessRestricted() -> Bool {
        guard let permissions = self.permissions else {
            return true
        }
        return !permissions.musicFolderAllowed ||
               !permissions.desktopFolderAllowed ||
               !permissions.documentsFolderAllowed ||
               !permissions.downloadsFolderAllowed
    }

    private var customWorkspacePath: String?

    public var currentWorkspacePath: String {
        get {
            if let custom = customWorkspacePath {
                return custom
            }
            if let configured = UserDefaults.standard.string(forKey: "apex.workspacePath"),
               !configured.isEmpty {
                return NSString(string: configured).expandingTildeInPath
            }
            return FileManager.default.currentDirectoryPath
        }
        set {
            customWorkspacePath = newValue
        }
    }

    @MainActor
    private func saveSandboxBookmark(for url: URL) {
        guard let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        var bookmarks = UserDefaults.standard.dictionary(forKey: "apex.sandboxBookmarks") as? [String: Data] ?? [:]
        bookmarks[url.standardized.path] = bookmarkData
        UserDefaults.standard.set(bookmarks, forKey: "apex.sandboxBookmarks")
    }

    @MainActor
    private func accessSandboxBookmark(for path: String) -> URL? {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: "apex.sandboxBookmarks") as? [String: Data] else {
            return nil
        }
        var currentPath = URL(fileURLWithPath: path).standardized.path
        while !currentPath.isEmpty && currentPath != "/" {
            if let data = bookmarks[currentPath] {
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
                   url.startAccessingSecurityScopedResource() {
                    return url
                }
            }
            currentPath = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        }
        return nil
    }

    @MainActor
    func verifyPathAllowed(_ path: String) throws(SecuritySandboxError) {
        let wsPath = currentWorkspacePath
        let wsURL = URL(fileURLWithPath: wsPath)
        saveSandboxBookmark(for: wsURL)

        guard let permissions = self.permissions else {
            throw .pathViolation(path)
        }

        let expanded = NSString(string: path).expandingTildeInPath
        let resolvedURL = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        let standardized = resolvedURL.path

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.standardized.path

        let desktopPath = (homeDir as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homeDir as NSString).appendingPathComponent("Documents")
        let downloadsPath = (homeDir as NSString).appendingPathComponent("Downloads")
        let musicPath = (homeDir as NSString).appendingPathComponent("Music")

        if !permissions.desktopFolderAllowed && (standardized == desktopPath || standardized.hasPrefix(desktopPath + "/")) {
            throw .desktopFolderRestricted
        }
        if !permissions.documentsFolderAllowed && (standardized == documentsPath || standardized.hasPrefix(documentsPath + "/")) {
            throw .documentsFolderRestricted
        }
        if !permissions.downloadsFolderAllowed && (standardized == downloadsPath || standardized.hasPrefix(downloadsPath + "/")) {
            throw .downloadsFolderRestricted
        }
        if !permissions.musicFolderAllowed && (standardized == musicPath || standardized.hasPrefix(musicPath + "/")) {
            throw .musicFolderRestricted
        }
        if accessSandboxBookmark(for: standardized) != nil {
            return
        }

        // STRENGTHENED SANDBOX: Enforce workspace boundary checks
        let resolvedWorkspace = URL(fileURLWithPath: wsPath).resolvingSymlinksInPath().path

        let isInWorkspace = standardized == resolvedWorkspace || standardized.hasPrefix(resolvedWorkspace + "/")

        let tempDir = NSTemporaryDirectory()
        let resolvedTemp = URL(fileURLWithPath: tempDir).resolvingSymlinksInPath().path
        let isInTemp = standardized == resolvedTemp || standardized.hasPrefix(resolvedTemp + "/")

        let skillsDir = (homeDir as NSString).appendingPathComponent(".apex/skills")
        let isInSkills = standardized == skillsDir || standardized.hasPrefix(skillsDir + "/")

        if !isInWorkspace && !isInTemp && !isInSkills {
            throw .pathViolation(path)
        }
    }

    @MainActor
    func isPathAllowed(_ path: String) -> Bool {
        do {
            try verifyPathAllowed(path)
            return true
        } catch {
            return false
        }
    }

    @MainActor
    func isCommandOrScriptAllowed(_ input: String) -> Bool {
        guard let permissions = self.permissions else {
            return false
        }

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.standardized.path

        let desktopPath = (homeDir as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homeDir as NSString).appendingPathComponent("Documents")
        let downloadsPath = (homeDir as NSString).appendingPathComponent("Downloads")
        let musicPath = (homeDir as NSString).appendingPathComponent("Music")

        if !permissions.desktopFolderAllowed && input.contains(desktopPath) {
            return false
        }
        if !permissions.documentsFolderAllowed && input.contains(documentsPath) {
            return false
        }
        if !permissions.downloadsFolderAllowed && input.contains(downloadsPath) {
            return false
        }
        if !permissions.musicFolderAllowed && input.contains(musicPath) {
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
            if score > AgentOrchestrator.ragSimilarityThreshold {
                scoredMemories.append((memory, score))
            }
        }

        scoredMemories.sort { $0.1 > $1.1 }

        let topMatches = scoredMemories.prefix(AgentOrchestrator.ragTopK)
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
            return localSystemModel()
        case .privateCloud:
            if Self.isPrivateCloudComputeAvailable() {
                return PrivateCloudComputeLanguageModel()
            } else {
                return localSystemModel()
            }
        case .cloudGemini:
            let apiKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
            return CloudGeminiLanguageModel(apiKey: apiKey)
        case .localOllama:
            let host = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? AgentOrchestrator.defaultOllamaURLString) ?? URL(string: AgentOrchestrator.defaultOllamaURLString)!
            return LocalOllamaLanguageModel(hostURL: host)
        case .localMLX:
            let host = URL(string: UserDefaults.standard.string(forKey: "apex.mlxHost") ?? LocalMLXLanguageModel.defaultHostURLString) ?? URL(string: LocalMLXLanguageModel.defaultHostURLString)!
            return LocalMLXLanguageModel(hostURL: host)
        case .hybrid:
            // Hybrid defaults to local system model for general orchestrator tasks
            return localSystemModel()
        }
    }

    /// Returns the on-device system language model. Callers are responsible for
    /// surfacing unavailability (e.g. Apple Intelligence not enabled) through the
    /// existing engine error paths rather than crashing on an unavailable model.
    private func localSystemModel() -> SystemLanguageModel {
        SystemLanguageModel.default
    }

    // MARK: Reasoning / output budget (read from Settings AppStorage)

    /// Maps the user's `apex.reasoningBudget` setting to the native
    /// `ContextOptions.ReasoningLevel`. "off" yields nil (model default).
    private var configuredReasoningLevel: ContextOptions.ReasoningLevel? {
        apexConfiguredReasoningLevel()
    }

    /// Reads the `apex.maxResponseTokens` setting; returns nil when it is 0
    /// (meaning "no cap").
    private var configuredMaxResponseTokens: Int? {
        apexConfiguredMaxResponseTokens()
    }

    private func resolveModelForSession() -> any LanguageModel {
        if modelPreference == .hybrid && !multiAgentModeEnabled {
            // Single-agent hybrid mode uses PCC for deep reasoning, falling back to local system if unavailable
            if Self.isPrivateCloudComputeAvailable() {
                return PrivateCloudComputeLanguageModel()
            } else {
                return localSystemModel()
            }
        }
        return createModelInstance()
    }

    private func createSession<M: LanguageModel>(model: M, instructions: String, mode: GenerationOptions.ToolCallingMode, transcript: Transcript) -> LanguageModelSession {
        let reasoning = configuredReasoningLevel
        let maxTokens = configuredMaxResponseTokens
        if multiAgentModeEnabled {
            let profile = SupervisorAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self, reasoningLevel: reasoning, maxResponseTokens: maxTokens)
            return LanguageModelSession(profile: profile, history: transcript)
        } else {
            let profile = ApexAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self, reasoningLevel: reasoning, maxResponseTokens: maxTokens)
            return LanguageModelSession(profile: profile, history: transcript)
        }
    }

    private func prunedContent(_ content: String, maxChars: Int = AgentOrchestrator.contextPruningMaxChars) -> String {
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
        let rehydrationMessages = messages.suffix(AgentOrchestrator.rehydrationWindowSize)
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

        let model = resolveModelForSession()
        session = createSession(model: model, instructions: instructions, mode: mode, transcript: transcript)

        // Warm the KV cache with a likely first-prompt prefix to cut
        // first-token latency (native session.prewarm(promptPrefix:)).
        session?.prewarm(promptPrefix: Prompt("Analyze the following"))
    }

    var allTools: [AnyExecutableTool] {
        if let cached = _allTools {
            return cached
        }
        let tools: [AnyExecutableTool] = [
            AnyExecutableTool(ShellTool(orchestrator: self)),
            AnyExecutableTool(FileReadTool(orchestrator: self)),
            AnyExecutableTool(FileWriteTool(orchestrator: self)),
            AnyExecutableTool(ListDirectoryTool(orchestrator: self)),
            AnyExecutableTool(CreateDirectoryTool(orchestrator: self)),
            AnyExecutableTool(DeleteFileTool(orchestrator: self)),
            AnyExecutableTool(MoveFileTool(orchestrator: self)),
            AnyExecutableTool(WebSearchTool(orchestrator: self)),
            AnyExecutableTool(AppleScriptTool(orchestrator: self)),
            AnyExecutableTool(ScreenshotTool(orchestrator: self)),
            AnyExecutableTool(ClipboardReadTool(orchestrator: self)),
            AnyExecutableTool(ClipboardWriteTool(orchestrator: self)),
            AnyExecutableTool(NotificationTool(orchestrator: self)),
            AnyExecutableTool(SystemInfoTool(orchestrator: self)),
            AnyExecutableTool(ProcessListTool(orchestrator: self)),
            AnyExecutableTool(GetFrontmostAppTool(orchestrator: self)),
            AnyExecutableTool(StoreMemoryTool(orchestrator: self)),
            AnyExecutableTool(SearchMemoryTool(orchestrator: self)),
            AnyExecutableTool(ApplicationControlTool(orchestrator: self)),
            AnyExecutableTool(AccessibilityControlTool(orchestrator: self)),
            AnyExecutableTool(BrowserAutomationTool(orchestrator: self)),
            AnyExecutableTool(UpdatePlanTool(orchestrator: self)),
            AnyExecutableTool(ProjectAuditTool(orchestrator: self)),
            AnyExecutableTool(DelegateTaskTool(orchestrator: self)),
            AnyExecutableTool(AnalyzeImageTool(orchestrator: self)),
            AnyExecutableTool(DetectImageTextTool(orchestrator: self)),
            AnyExecutableTool(ConveneMeetingTool(orchestrator: self)),
            AnyExecutableTool(CreateSkillTool(orchestrator: self)),
            AnyExecutableTool(RunWorkflowTool(orchestrator: self)),
            AnyExecutableTool(FileSearchTool(orchestrator: self)),
            AnyExecutableTool(SpotlightSearchTool(orchestrator: self)),
            AnyExecutableTool(DynamicToolCallTool(orchestrator: self)),
            AnyExecutableTool(DailyBriefingTool(orchestrator: self))
        ]
        _allTools = tools
        return tools
    }

    func startNewConversation() {
        messages = []
        toolEvents = []
        coordinationTraces = []
        reasoningLogs = []
        currentConversationTitle = "New Conversation"
        currentConversation = nil
        activeTerminalOutput = ""
        UIRegistry.shared.clearAll()
        resetSession()
    }

    func clearAllConversations() {
        if let context = modelContext {
            try? context.delete(model: Conversation.self)
            try? context.delete(model: Message.self)
            saveContext(context)
        }
        startNewConversation()
    }

    func logReasoning(_ thought: String) {
        let timestamped = "[\(Self.iso8601Formatter.string(from: Date()))] \(thought)"
        reasoningLogs.append(timestamped)
        print("[Reasoning] \(thought)")
    }

    func updateInstructions(_ newInstructions: String) {
        agentInstructions = newInstructions
        resetSession()
    }

    func clearPlan() {
        activePlan = []
    }

    func updatePlan(steps: [PlanStep]) {
        activePlan = steps
    }

    func clearToolEvents() {
        toolEvents = []
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

    func resetActiveTurnToolCallCount() {
        activeTurnToolCallCount = 0
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

        let spanID = AgentSignpost.begin("SendMessage", detail: trimmedText.prefix(64).description)
        Task { TraceBus.shared.append(TraceEvent(source: "orchestrator", operation: "sendMessage", detail: String(trimmedText.prefix(120)))) }
        currentTask = Task {
            defer {
                AgentSignpost.end("SendMessage", spanID)
                Task { TraceBus.shared.append(TraceEvent(source: "orchestrator", operation: "sendMessage", detail: "complete")) }
                self.isGenerating = false
                self.activeAssistantMessageId = nil
            }
            // 1. Asynchronously check and compact context if needed
            await compactContextIfNeeded()
            guard !Task.isCancelled else { return }

            // 2. Hydrate/reset the model session with the compacted state
            resetSession()
            guard !Task.isCancelled else { return }

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
                orchestrator: self,
                reasoningLevel: configuredReasoningLevel,
                maxResponseTokens: configuredMaxResponseTokens
            )
            return LanguageModelSession(profile: profile, history: Transcript(entries: []))
        }
        return helper(model)
    }

    @MainActor
    func compactContextIfNeeded() async {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        guard totalChars > AgentOrchestrator.contextCompactionThreshold else { return }
        guard messages.count > 5 else { return }

        print("[DIAG] compactContextIfNeeded start; totalChars=\(totalChars) count=\(messages.count)")

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
            let response = try await session.respond(to: compactionText)
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[DIAG] compaction respond ended; summary.isEmpty=\(summary.isEmpty)")

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
                    saveContext(context)
                }

                print("Context compacted successfully! Reduced message history size.")
            }
        } catch {
            print("[DIAG] compactContextIfNeeded error: \(error)")
        }
        print("[DIAG] compactContextIfNeeded complete")
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
                saveContext(context)
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
            saveContext(context)
        }

        // Add placeholder assistant message
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)
        activeAssistantMessageId = assistantMsg.id
        // Capture the id in a local let. The `currentTask` defer (below) and
        // sendMessage's defer both nil `activeAssistantMessageId` on teardown,
        // which races `onUpdate` and left it nil at streaming time (blank
        // bubble). Using the captured id decouples the update from teardown.
        let assistantId = assistantMsg.id

        Task {
            // Only capture the screen when the collaborative/sharing server is
            // active — ScreenCaptureKit streams (1024x768 @1fps) are RAM-heavy
            // and were being started on EVERY generation, pushing an already
            // memory-pressured system into CriticalMemoryPressure (which makes
            // on-device FM inference fail or thrash). Screen frames are only
            // consumed by CollaborativeServer, so don't capture for plain chat.
            if UserDefaults.standard.bool(forKey: "apex.collaborativeServerEnabled") {
                await ScreenStreamer.shared.startCapture()
            }
        }

        currentTask = Task {
            defer {
                isGenerating = false
                activeAssistantMessageId = nil
                // Legacy remote-gateway bridge: push final state. (Replaces the
                // former didSet on isGenerating/messages, which defeated
                // @Observable tracking and froze the chat UI on "thinking".)
                onStateChanged?()
            }
            let engine: any AgentEngine
            switch self.modelPreference {
            case .localOllama:
                // Direct-HTTP Ollama path: the FoundationModels
                // LanguageModelExecutorGenerationChannel pump crashes on
                // macOS 27.0 26A5388g, so we stream from Ollama's local
                // /api/chat directly and run tools through allTools.
                engine = OllamaAgentEngine(orchestrator: self)
            case .localMLX:
                // Direct-HTTP MLX-LM path (OpenAI-compatible SSE) — same
                // FoundationModels channel bypass rationale as Ollama.
                engine = MLXAgentEngine(orchestrator: self)
            case .localSystem, .privateCloud, .cloudGemini, .hybrid:
                engine = NativeAppleEngine(orchestrator: self)
            }

            do {
                let semanticContext = self.getSemanticContext(for: text)
                var finalInstructions = self.agentInstructions + semanticContext
                if !self.proactiveAuditResult.isEmpty {
                    finalInstructions += "\n\n\(self.proactiveAuditResult)\nUse the above proactive audit report to suggest improvements, tasks, and fixes (e.g. missing tests or TODOs) when requested or appropriate."
                }

                Logger.agent.info("Generation started (provider: \(self.modelPreference.rawValue, privacy: .public))")
                let generationSpan = AgentSignpost.begin("Generate", detail: self.modelPreference.rawValue)
                defer { AgentSignpost.end("Generate", generationSpan) }

                try await engine.streamResponse(
                    prompt: text,
                    attachments: userMsg.attachments,
                    history: historyMessages,
                    instructions: finalInstructions,
                    toolCallingMode: self.toolCallingMode,
                    onUpdate: { @MainActor partialContent in
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                            // Reassign the whole array (not just a nested
                            // `messages[idx].content =`) so @Observable tracks
                            // the change and SwiftUI re-renders the streaming
                            // bubble. A nested struct mutation does NOT trigger
                            // @Observable, which left the UI stuck on "thinking".
                            var copy = self.messages
                            copy[idx].content = partialContent
                            self.messages = copy
                        } else {
                            Logger.agent.info("[DIAG-onUpdate] assistant id not found in messages (idx miss)")
                        }
                    }
                )

                // Save assistant message to SwiftData
                if let conv = self.currentConversation, let context = self.modelContext {
                    let id = assistantId
                    if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                        let dbAssistantMsg = Message(role: .assistant, content: self.messages[idx].content)
                        dbAssistantMsg.id = self.messages[idx].id
                        dbAssistantMsg.conversation = conv
                        context.insert(dbAssistantMsg)
                        conv.updatedAt = Date()
                        saveContext(context)

                        // Phase 7: index the updated session into Core Spotlight
                        // so past agent sessions are retrievable (system search
                        // + SpotlightSearchTool RAG).
                        SpotlightIndexer.indexConversation(
                            id: conv.id,
                            title: conv.title,
                            messages: self.messages.map { (role: $0.role == .user ? "user" : "assistant", content: $0.content) },
                            updatedAt: conv.updatedAt
                        )
                    }
                }

                // Trigger procedural skill reflection if an error was resolved in this turn
                ReflectionManager.shared.reflectIfResolved(prompt: text, history: self.messages, orchestrator: self)

                // If Voice Mode is enabled, speak the response
                if UserDefaults.standard.bool(forKey: "apex.voiceModeEnabled") {
                    let id = assistantId
                    if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                        VoiceController.shared.speak(self.messages[idx].content)
                    }
                }
            } catch {
                let id = assistantId
                if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                    // Reassign (not nested mutation) so @Observable publishes the error.
                    var copy = self.messages
                    copy[idx].content = "⚠️ Error: \(error.localizedDescription)"
                    self.messages = copy
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
                        saveContext(context)
                    }
                }
            }

            if let id = self.activeAssistantMessageId, let idx = self.messages.firstIndex(where: { $0.id == id }) {
                // Reassign (not nested mutation) so @Observable publishes the
                // isStreaming=false flip — otherwise the view keeps showing the
                // "thinking"/typing indicator forever even after content arrives.
                var copy = self.messages
                copy[idx].isStreaming = false
                self.messages = copy
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
            // Reassign so @Observable publishes isStreaming=false (not nested mutation).
            var copy = messages
            copy[idx].isStreaming = false
            messages = copy
            // Save partially generated message to SwiftData
            if let conv = currentConversation, let context = modelContext {
                let dbAssistantMsg = Message(role: .assistant, content: messages[idx].content)
                dbAssistantMsg.id = messages[idx].id
                dbAssistantMsg.conversation = conv
                context.insert(dbAssistantMsg)
                conv.updatedAt = Date()
                saveContext(context)
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
            saveContext(context)
        }

        if currentConversation?.id == conversation.id {
            startNewConversation()
        }
    }

    private func saveContext(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            print("⚠️ SwiftData context save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - PTY Management

    func ptySession(for conversationId: UUID) async -> PTYSession? {
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
            let workspacePath = FileManager.default.currentDirectoryPath
            do {
                let fallback = try await PTYSession(workspacePath: workspacePath, orchestrator: self)
                ptySessions[conversationId] = fallback
                return fallback
            } catch {
                return nil
            }
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
        if updated.count > AgentOrchestrator.terminalOutputCap {
            updated = String(updated.suffix(AgentOrchestrator.terminalOutputCap))
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
        if let tool = allTools.first(where: { $0.name == name }) {
            return try await tool.execute(jsonArguments: jsonArguments)
        }
        if DynamicToolbox.shared.dynamicTools[name] != nil {
            return try await DynamicToolbox.shared.executeTool(name: name, jsonArguments: jsonArguments)
        }
        throw NSError(domain: "AgentOrchestrator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
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

    public var orchestrator: AgentOrchestrator { self }
    public var dataBus: AppGroupDataBus { AppGroupDataBus.shared }

    // MARK: - ToolEventLogger Conformance

    public func logToolStart(name: String, arguments: String) {
        activeTurnToolCallCount += 1
        let event = ToolEvent(toolName: name, arguments: arguments)
        logToolEvent(event)
    }

    public func logToolEvent(_ event: ToolEvent) {
        toolEvents.insert(event, at: 0) // Most recent first
        // Limit to maxToolEventCount events
        if toolEvents.count > AgentOrchestrator.maxToolEventCount {
            toolEvents = Array(toolEvents.prefix(AgentOrchestrator.maxToolEventCount))
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
        if requireConfirmationForAll { return true }
        return AgentOrchestrator.dangerousToolNames.contains(name) || AgentSecurity.requiresConfirmation(name)
    }

    public func requestConfirmation(
        toolName: String,
        arguments: String,
        riskDescription: String,
        oldContent: String? = nil,
        newContent: String? = nil,
        filePath: String? = nil
    ) async -> Bool {
        let isTesting = ProcessInfo.processInfo.arguments.contains { $0.contains("test") || $0.contains("xctest") } || ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1"
        if isTesting {
            return true
        }
        if let gateway = confirmationGateway {
            return await gateway(toolName, arguments, riskDescription)
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

            // Auto-deny after timeout
            confirmationTimeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(AgentOrchestrator.confirmationTimeoutSeconds))
                if self.pendingConfirmation?.id == request.id {
                    self.resolveConfirmation(approved: false)
                }
            }
        }
    }

    public func resolveConfirmation(approved: Bool) {
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
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
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let maxResponseTokens: Int?

    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider, reasoningLevel: ContextOptions.ReasoningLevel? = nil, maxResponseTokens: Int? = nil) {
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
        self.reasoningLevel = reasoningLevel
        self.maxResponseTokens = maxResponseTokens
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
        .apexAuditHooks()
        .model(model)
        .toolCallingMode(toolCallingMode)
        .reasoningLevel(reasoningLevel)
        .maximumResponseTokens(maxResponseTokens)
    }
}
