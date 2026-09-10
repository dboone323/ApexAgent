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
    var botName: String? = nil

    init(id: UUID = UUID(), role: MessageRole, content: String, toolEvents: [ToolEvent] = [], timestamp: Date = Date(), isStreaming: Bool = false, attachments: [NSImage] = [], botName: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.toolEvents = toolEvents
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.attachments = attachments
        self.botName = botName
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
    case autoPicker = "Auto (Native → Gemini Flash → Ollama)"
    case localSystem = "Local System (AFM 3)"
    case privateCloud = "Private Cloud Compute"
    case cloudGemini = "Cloud Gemini (Flash / Pro)"
    case localOllama = "Local Ollama"
    case localMLX = "Local MLX"
    case hybrid = "Hybrid (On-Device + PCC Fallback)"

    var id: String { self.rawValue }
}

// MARK: - Agent Orchestrator

@Observable
@MainActor
public final class AgentOrchestrator: OrchestratorProvider, ToolEventLogger {
    let contextCompactor = ContextCompactor.shared
    let speculativeExecutor = SpeculativeToolExecutor.shared

    // MARK: - OrchestratorProvider conformance

    func sessionForAgent(
        agent: RegisteredAgent,
        preference: AgentModelPreference,
        instructions: String,
        allowedTools: [String],
        toolCallingMode: GenerationOptions.ToolCallingMode,
        reasoningLevel: ContextOptions.ReasoningLevel? = nil,
        maxResponseTokens: Int? = nil,
        history: Transcript? = nil
    ) -> LanguageModelSession {
        sessionForAgent(
            agent: agent,
            preference: preference,
            instructions: instructions,
            allowedTools: allowedTools,
            toolCallingMode: toolCallingMode,
            reasoningLevel: reasoningLevel,
            maxResponseTokens: maxResponseTokens,
            history: history,
            prompt: ""
        )
    }

    func sessionForAgent(
        agent: RegisteredAgent,
        preference: AgentModelPreference,
        instructions: String,
        allowedTools: [String],
        toolCallingMode: GenerationOptions.ToolCallingMode,
        reasoningLevel: ContextOptions.ReasoningLevel? = nil,
        maxResponseTokens: Int? = nil,
        history: Transcript? = nil,
        prompt: String
    ) -> LanguageModelSession {
        func makeSession<M: LanguageModel>(_ model: M) -> LanguageModelSession {
            let effectiveReasoning = reasoningLevel ?? configuredReasoningLevel
            let effectiveMaxTokens = maxResponseTokens ?? configuredMaxResponseTokens
            let transcript: Transcript = history ?? Transcript(entries: [])
            if agent.name.lowercased() == "supervisor" {
                let profile = SupervisorAgentProfile(
                    instructions: instructions,
                    model: model,
                    toolCallingMode: toolCallingMode,
                    orchestrator: self,
                    reasoningLevel: effectiveReasoning,
                    maxResponseTokens: effectiveMaxTokens
                )
                return LanguageModelSession(profile: profile, history: transcript)
            } else {
                let profile = SpecializedAgentProfile(
                    instructions: instructions,
                    model: model,
                    toolCallingMode: toolCallingMode,
                    orchestrator: self,
                    allowedTools: allowedTools,
                    reasoningLevel: effectiveReasoning,
                    maxResponseTokens: effectiveMaxTokens
                )
                return LanguageModelSession(profile: profile, history: transcript)
            }
        }

        switch preference {
        case .autoPicker:
            let (resolved, _) = ModelRegistry.resolveProviderForTask(
                preferred: .autoPicker,
                prompt: prompt,
                instructions: instructions,
                tools: allowedTools
            )
            switch resolved {
            case .cloudGemini:
                let apiKey = ModelRegistry.geminiAPIKey()
                return makeSession(CloudGeminiLanguageModel(apiKey: apiKey))
            case .localOllama:
                let host = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? AgentOrchestrator.defaultOllamaURLString) ?? URL(string: AgentOrchestrator.defaultOllamaURLString)!
                return makeSession(LocalOllamaLanguageModel(hostURL: host))
            case .localMLX:
                let host = URL(string: UserDefaults.standard.string(forKey: "apex.mlxHost") ?? LocalMLXLanguageModel.defaultHostURLString) ?? URL(string: LocalMLXLanguageModel.defaultHostURLString)!
                return makeSession(LocalMLXLanguageModel(hostURL: host))
            case .applePCC:
                if Self.isPrivateCloudComputeAvailable() {
                    return makeSession(PrivateCloudComputeLanguageModel())
                } else {
                    return makeSession(localSystemModel())
                }
            default:
                return makeSession(localSystemModel())
            }
        case .localSystem:
            return makeSession(localSystemModel())
        case .privateCloud:
            if Self.isPrivateCloudComputeAvailable() {
                return makeSession(PrivateCloudComputeLanguageModel())
            } else {
                return makeSession(localSystemModel())
            }
        case .cloudGemini:
            let apiKey = ModelRegistry.geminiAPIKey()
            return makeSession(CloudGeminiLanguageModel(apiKey: apiKey))
        case .localOllama:
            let host = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? AgentOrchestrator.defaultOllamaURLString) ?? URL(string: AgentOrchestrator.defaultOllamaURLString)!
            return makeSession(LocalOllamaLanguageModel(hostURL: host))
        case .localMLX:
            let host = URL(string: UserDefaults.standard.string(forKey: "apex.mlxHost") ?? LocalMLXLanguageModel.defaultHostURLString) ?? URL(string: LocalMLXLanguageModel.defaultHostURLString)!
            return makeSession(LocalMLXLanguageModel(hostURL: host))
        case .hybrid:
            if multiAgentModeEnabled {
                return makeSession(localSystemModel())
            } else if Self.isPrivateCloudComputeAvailable() {
                return makeSession(PrivateCloudComputeLanguageModel())
            } else {
                return makeSession(localSystemModel())
            }
        }
    }

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
    /// On-device FM (AFM 3) enforces a hard 4,096-token input ceiling. The
    /// rehydration window + per-message pruning below are tuned so `rehydrateSession()`
    /// assembles a transcript that stays comfortably under that budget (system
    /// instructions + tool definitions + rehydrated history), preventing the
    /// `DecoderModelError("Provided X tokens, maximum 4,096")` crash seen when
    /// the window was 10×1500. Tool-heavy turns should be routed to sub-agent
    /// profiles (Layer 2) rather than inflated into the supervisor's context.
    private static let contextPruningMaxChars: Int = 500
    private static let rehydrationWindowSize: Int = 4
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
    var modelPreference: AgentModelPreference = {
        if let saved = UserDefaults.standard.string(forKey: "apex.modelPreference"),
           let pref = AgentModelPreference(rawValue: saved) {
            return pref
        }
        return .autoPicker
    }() {
        didSet {
            UserDefaults.standard.set(modelPreference.rawValue, forKey: "apex.modelPreference")
            UserDefaults.standard.set(modelPreference.toModelProvider.rawValue, forKey: ModelRegistry.providerKey)
        }
    }
    // Default is .autoPicker (Native on-device <=3,200 tokens -> Cloud Gemini Flash -> Local Ollama).
    // The Auto Model Picker dynamically resolves the best engine per turn and per agent,
    // avoiding the 4k hardware context ceiling on AFM by auto-tiering to Local Ollama (gemma4:12b)
    // or Cloud Gemini Flash when token thresholds are exceeded.
    var pendingAttachments: [NSImage] = []
    private(set) var activeTurnToolCallCount: Int = 0
    private(set) var activeTurnDelegationsByAgent: [String: Int] = [:]
    private(set) var totalTurnDelegations: Int = 0
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

    // MARK: - Bot Manager (multi-bot registry)
    /// Set by the app after both the orchestrator and botManager are created.
    /// Weak reference — does not extend the orchestrator's lifetime.
    weak var botManager: BotManager?

    private(set) var session: LanguageModelSession?
    private var compactionSession: LanguageModelSession?
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
        let effectivePath: String
        if expanded.hasPrefix("/") {
            effectivePath = expanded
        } else if expanded.isEmpty || expanded == "." || expanded == "./" {
            effectivePath = wsPath
        } else {
            effectivePath = (wsPath as NSString).appendingPathComponent(expanded)
        }
        let rawStandardized = URL(fileURLWithPath: effectivePath).standardized.path
        let resolvedURL = URL(fileURLWithPath: effectivePath).resolvingSymlinksInPath()
        let standardized = resolvedURL.path

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.standardized.path

        let destinationOfSymlink: String?
        do {
            let rawDest = try fm.destinationOfSymbolicLink(atPath: path)
            destinationOfSymlink = NSString(string: rawDest).expandingTildeInPath
        } catch {
            destinationOfSymlink = nil
        }
        // Helper: does `p` land inside any forbidden home-relative directory?
        func isForbiddenHomeSubpath(_ p: String) -> Bool {
            let sensitiveNames = [".ssh", ".aws", ".gnupg", ".config"]
            for name in sensitiveNames {
                let forbidden = (homeDir as NSString).appendingPathComponent(name)
                if p == forbidden || p.hasPrefix(forbidden + "/") { return true }
            }
            return false
        }

        let desktopPath = (homeDir as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homeDir as NSString).appendingPathComponent("Documents")
        let downloadsPath = (homeDir as NSString).appendingPathComponent("Downloads")
        let musicPath = (homeDir as NSString).appendingPathComponent("Music")
        let sshPath = (homeDir as NSString).appendingPathComponent(".ssh")
        let awsPath = (homeDir as NSString).appendingPathComponent(".aws")
        let gnupgPath = (homeDir as NSString).appendingPathComponent(".gnupg")
        let configPath = (homeDir as NSString).appendingPathComponent(".config")

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
        if standardized == sshPath || standardized.hasPrefix(sshPath + "/") {
            throw .pathViolation(path)
        }
        if standardized == awsPath || standardized.hasPrefix(awsPath + "/") {
            throw .pathViolation(path)
        }
        if standardized == gnupgPath || standardized.hasPrefix(gnupgPath + "/") {
            throw .pathViolation(path)
        }
        if standardized == configPath || standardized.hasPrefix(configPath + "/") {
            throw .pathViolation(path)
        }

        // Forbidden-directory check on the raw symlink destination.
        if let dest = destinationOfSymlink, isForbiddenHomeSubpath(dest) {
            throw .symlinkTraversal(path)
        }

        // Host system root enforcement
        if standardized == "/" {
            throw .pathViolation(path)
        }

        let resolvedWorkspace = URL(fileURLWithPath: wsPath).resolvingSymlinksInPath().path
        let isInWorkspace = standardized == resolvedWorkspace || standardized.hasPrefix(resolvedWorkspace + "/")

        let tempDir = NSTemporaryDirectory()
        let resolvedTemp = URL(fileURLWithPath: tempDir).resolvingSymlinksInPath().path
        let isSystemTmp = standardized == "/tmp" || standardized.hasPrefix("/tmp/")
            || standardized == "/private/tmp" || standardized.hasPrefix("/private/tmp/")
        let isInTemp = standardized == resolvedTemp || standardized.hasPrefix(resolvedTemp + "/") || isSystemTmp

        let skillsDir = (homeDir as NSString).appendingPathComponent(".apex/skills")
        let resolvedSkills = URL(fileURLWithPath: skillsDir).resolvingSymlinksInPath().path
        let dotApexDir = (homeDir as NSString).appendingPathComponent(".apex")
        let resolvedDotApex = URL(fileURLWithPath: dotApexDir).resolvingSymlinksInPath().path
        let apexDir = (homeDir as NSString).appendingPathComponent("apex")
        let resolvedApex = URL(fileURLWithPath: apexDir).resolvingSymlinksInPath().path
        let userTmpDir = (homeDir as NSString).appendingPathComponent("tmp")
        let resolvedUserTmp = URL(fileURLWithPath: userTmpDir).resolvingSymlinksInPath().path

        let isInSkills = standardized == resolvedSkills || standardized.hasPrefix(resolvedSkills + "/")
            || standardized == resolvedDotApex || standardized.hasPrefix(resolvedDotApex + "/")
            || standardized == resolvedApex || standardized.hasPrefix(resolvedApex + "/")
            || standardized == resolvedUserTmp || standardized.hasPrefix(resolvedUserTmp + "/")

        let forbiddenSystemPrefixes = [
            "/System", "/Library", "/etc", "/private/etc", "/usr", "/bin", "/sbin", "/var", "/private/var", "/dev", "/Volumes"
        ]

        // 1. Symlink Traversal Detection:
        let isSymlink = (destinationOfSymlink != nil) || (rawStandardized != standardized)
        if isSymlink {
            for forbidden in forbiddenSystemPrefixes {
                if standardized == forbidden || standardized.hasPrefix(forbidden + "/") {
                    throw .symlinkTraversal(path)
                }
            }
            if let dest = destinationOfSymlink {
                for forbidden in forbiddenSystemPrefixes {
                    if dest == forbidden || dest.hasPrefix(forbidden + "/") {
                        throw .symlinkTraversal(path)
                    }
                }
            }
            let rawInWorkspace = rawStandardized == wsPath || rawStandardized.hasPrefix(wsPath + "/") || rawStandardized == resolvedWorkspace || rawStandardized.hasPrefix(resolvedWorkspace + "/")
            if rawInWorkspace && !isInWorkspace {
                throw .symlinkTraversal(path)
            }
        }

        // 2. Direct system directory access
        for forbidden in forbiddenSystemPrefixes {
            if standardized == forbidden || standardized.hasPrefix(forbidden + "/") {
                if !isInTemp {
                    throw .pathViolation(path)
                }
            }
        }

        if accessSandboxBookmark(for: standardized) != nil {
            return
        }

        if isInWorkspace || isInTemp || isInSkills {
            return
        }

        throw .pathViolation(path)
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
    func isCommandOrScriptAllowed(_ input: String, isContainerSandboxed: Bool = false) -> Bool {
        if isContainerSandboxed {
            return true
        }

        guard let permissions = self.permissions else {
            return false
        }

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.standardized.path

        let desktopPath = (homeDir as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homeDir as NSString).appendingPathComponent("Documents")
        let downloadsPath = (homeDir as NSString).appendingPathComponent("Downloads")
        let musicPath = (homeDir as NSString).appendingPathComponent("Music")

        let desktopAllowed = permissions.desktopFolderAllowed
        let documentsAllowed = permissions.documentsFolderAllowed
        let downloadsAllowed = permissions.downloadsFolderAllowed
        let musicAllowed = permissions.musicFolderAllowed

        if !desktopAllowed && (input.contains(desktopPath) || input.contains("~/Desktop")) {
            return false
        }
        if !documentsAllowed && (input.contains(documentsPath) || input.contains("~/Documents")) {
            return false
        }
        if !downloadsAllowed && (input.contains(downloadsPath) || input.contains("~/Downloads")) {
            return false
        }
        if !musicAllowed && (input.contains(musicPath) || input.contains("~/Music")) {
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
        case .autoPicker:
            let (resolved, _) = ModelRegistry.resolveProviderForTask(
                preferred: .autoPicker,
                prompt: "",
                instructions: agentInstructions
            )
            switch resolved {
            case .cloudGemini:
                let apiKey = ModelRegistry.geminiAPIKey()
                return CloudGeminiLanguageModel(apiKey: apiKey)
            case .localOllama:
                let host = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? AgentOrchestrator.defaultOllamaURLString) ?? URL(string: AgentOrchestrator.defaultOllamaURLString)!
                return LocalOllamaLanguageModel(hostURL: host)
            case .localMLX:
                let host = URL(string: UserDefaults.standard.string(forKey: "apex.mlxHost") ?? LocalMLXLanguageModel.defaultHostURLString) ?? URL(string: LocalMLXLanguageModel.defaultHostURLString)!
                return LocalMLXLanguageModel(hostURL: host)
            case .applePCC:
                if Self.isPrivateCloudComputeAvailable() {
                    return PrivateCloudComputeLanguageModel()
                } else {
                    return localSystemModel()
                }
            default:
                return localSystemModel()
            }
        case .localSystem:
            return localSystemModel()
        case .privateCloud:
            if Self.isPrivateCloudComputeAvailable() {
                return PrivateCloudComputeLanguageModel()
            } else {
                return localSystemModel()
            }
        case .cloudGemini:
            let apiKey = ModelRegistry.geminiAPIKey()
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
    var configuredReasoningLevel: ContextOptions.ReasoningLevel? {
        apexConfiguredReasoningLevel()
    }

    /// Reads the `apex.maxResponseTokens` setting; returns nil when it is 0
    /// (meaning "no cap").
    var configuredMaxResponseTokens: Int? {
        apexConfiguredMaxResponseTokens()
    }

    func resolveModelForSession() -> any LanguageModel {
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
        let profile = SupervisorAgentProfile(instructions: instructions, model: model, toolCallingMode: mode, orchestrator: self, reasoningLevel: reasoning, maxResponseTokens: maxTokens)
        return LanguageModelSession(profile: profile, history: transcript)
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
        // Layer 2: the on-device session always runs the supervisor profile with
        // supervisor instructions. `multiAgentModeEnabled` controls whether the
        // supervisor ALSO uses `convene_meeting` (parallel panel) vs only
        // `delegate_task` (sequential delegation) — both routes delegate to
        // sub-agent sessions, never inflate the supervisor's own context.
        let instructions = SupervisorPrompt.system

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
        // Skipped in test mode so background prewarm XPC tasks don't collide
        // with immediate synchronous generation calls.
        let isTesting = getenv("APEX_TEST_MODE") != nil
            || ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("xctest")
            || NSClassFromString("XCTestCase") != nil
            || CommandLine.arguments.contains("--cli")
            || CommandLine.arguments.contains("--daemon")
        if !isTesting {
            session?.prewarm(promptPrefix: Prompt("Analyze the following"))
        }
    }

    let repeatDetector = RepeatDetector(thresholds: [3, 5])

    func checkRepeat(tool: String, arguments: String?) -> String? {
        if tool == "delegate_task" && totalTurnDelegations >= 3 {
            return "Loop detected: Maximum delegations (3) reached for this turn. Do not call delegate_task again. Formulate your final response to the user now."
        }
        if tool == "convene_meeting" && activeTurnToolCallCount >= 4 {
            return "Loop detected: Maximum meeting invocations reached for this turn. Synthesize findings and respond to the user."
        }
        guard let key = RepeatCallKey.make(tool: tool, arguments: arguments) else { return nil }
        let callCount = repeatDetector.record(thread: "default", key: key)
        if callCount.count >= 5 {
            return "Loop detected: Tool '\(tool)' was invoked repeatedly with identical arguments."
        }
        return nil
    }

    func recordDelegation(to agent: String) -> (allowed: Bool, message: String?) {
        let agentKey = agent.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if totalTurnDelegations >= 3 {
            return (false, "DELEGATION LIMIT REACHED: Maximum total delegations (3) reached for this turn. Do not call delegate_task again. Formulate your final response to the user now.")
        }
        let count = activeTurnDelegationsByAgent[agentKey] ?? 0
        if count >= 2 {
            return (false, "DELEGATION LIMIT REACHED: Specialist '\(agent)' has already completed 2 tasks this turn. Do not call delegate_task again. Formulate your final response to the user now.")
        }
        activeTurnDelegationsByAgent[agentKey] = count + 1
        totalTurnDelegations += 1
        return (true, nil)
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
            AnyExecutableTool(AccessibilityOmniTargeter(orchestrator: self)),
            AnyExecutableTool(DifferentialScreenPerception(orchestrator: self)),
            AnyExecutableTool(CaptureWindowImageTool(orchestrator: self)),
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
            AnyExecutableTool(DailyBriefingTool(orchestrator: self)),
            AnyExecutableTool(AskBotTool(botManager: botManager)),
            AnyExecutableTool(ConfirmCompletionTool(orchestrator: self)),
            AnyExecutableTool(SaveReviewSessionTool(orchestrator: self)),
            AnyExecutableTool(ListReviewSessionsTool(orchestrator: self)),
            AnyExecutableTool(WeatherTool(orchestrator: self)),
            AnyExecutableTool(MapSearchTool(orchestrator: self)),
            AnyExecutableTool(DirectionsTool(orchestrator: self)),
            AnyExecutableTool(CalendarTool(orchestrator: self)),
            AnyExecutableTool(ReminderTool(orchestrator: self)),
            AnyExecutableTool(TranslateTool(orchestrator: self)),
            AnyExecutableTool(EntityExtractTool(orchestrator: self)),
            AnyExecutableTool(AppleShortcutsTool(orchestrator: self)),
            AnyExecutableTool(OSLogQueryTool(orchestrator: self)),
            AnyExecutableTool(WatchPathsTool(orchestrator: self)),
            AnyExecutableTool(NetworkDiagnosticsTool(orchestrator: self)),
            AnyExecutableTool(ScreenPerceptionTool(orchestrator: self)),
            AnyExecutableTool(FilePatchTool(orchestrator: self)),
            AnyExecutableTool(GitOperationsTool(orchestrator: self)),
            AnyExecutableTool(DispatchSwarmTool(botManager: botManager))
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
            var copy = messages
            copy[idx].content = content
            messages = copy
        }
    }

    func updateMessage(id: UUID, isStreaming: Bool) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            var copy = messages
            copy[idx].isStreaming = isStreaming
            messages = copy
        }
    }

    func resetActiveTurnToolCallCount() {
        activeTurnToolCallCount = 0
        activeTurnDelegationsByAgent.removeAll()
        totalTurnDelegations = 0
        repeatDetector.settle(thread: "default")
    }

    // MARK: Send Message

    func sendMessage(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !pendingAttachments.isEmpty else { return }
        guard !isGenerating else { return }

        // Stop any active text-to-speech playback
        VoiceController.shared.stopSpeaking()
        activeTurnToolCallCount = 0
        activeTurnDelegationsByAgent.removeAll()
        totalTurnDelegations = 0
        repeatDetector.settle(thread: "default")
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

    func sendMessageAndWait(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !pendingAttachments.isEmpty else { return }
        guard !isGenerating else { return }

        VoiceController.shared.stopSpeaking()
        activeTurnToolCallCount = 0
        activeTurnDelegationsByAgent.removeAll()
        totalTurnDelegations = 0
        repeatDetector.settle(thread: "default")
        isGenerating = true

        let spanID = AgentSignpost.begin("SendMessage", detail: trimmedText.prefix(64).description)
        TraceBus.shared.append(TraceEvent(source: "orchestrator", operation: "sendMessageAndWait", detail: String(trimmedText.prefix(120))))
        defer {
            AgentSignpost.end("SendMessage", spanID)
            TraceBus.shared.append(TraceEvent(source: "orchestrator", operation: "sendMessageAndWait", detail: "complete"))
            self.isGenerating = false
            self.activeAssistantMessageId = nil
        }

        await compactContextIfNeeded()
        resetSession()
        await runMessageGeneration(text: trimmedText)
    }

    private struct CompactionProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
        let instructions: String
        let model: Model

        var body: some LanguageModelSession.DynamicProfile {
            LanguageModelSession.Profile {
                Instructions(instructions)
            }
            .model(model)
            .toolCallingMode(.disallowed)
        }
    }

    @MainActor
    private func createCompactionSession(model: any LanguageModel, instructions: String) -> LanguageModelSession {
        func helper<M: LanguageModel>(_ m: M) -> LanguageModelSession {
            let profile = CompactionProfile(instructions: instructions, model: m)
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

        // AFM 3 on-device context window is 4k tokens (~16k chars total including prompt and system instructions).
        // Cap the summarization input to 4,000 characters to ensure safe tokenization and avoid Metal buffer overflow.
        if compactionText.count > 4000 {
            compactionText = String(compactionText.prefix(4000)) + "\n[... truncated for summarization context limit ...]"
        }

        let session: LanguageModelSession
        if let existing = compactionSession {
            session = existing
        } else {
            let model = createModelInstance()
            let newSession = createCompactionSession(model: model, instructions: "Summarize chat logs concisely. Focus on facts, status, file paths, and results.")
            compactionSession = newSession
            session = newSession
        }

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
        // Capture the id in a local let.
        let assistantId = assistantMsg.id

        Task {
            if UserDefaults.standard.bool(forKey: "apex.collaborativeServerEnabled") {
                await ScreenStreamer.shared.startCapture()
            }
        }

        defer {
            onStateChanged?()
        }
        let semanticContext = self.getSemanticContext(for: text)
        var finalInstructions = self.agentInstructions + semanticContext
        let lowerText = text.lowercased()
            let isAuditRequested = lowerText.contains("audit")
                || lowerText.contains("todo")
                || lowerText.contains("health")
                || lowerText.contains("missing test")
            if !self.proactiveAuditResult.isEmpty && isAuditRequested {
                finalInstructions += "\n\n\(self.proactiveAuditResult)\nUse the above proactive audit report to suggest improvements, tasks, and fixes (e.g. missing tests or TODOs) when requested or appropriate."
            }

            let explicitlyNoTools = lowerText.contains("without tools")
                || lowerText.contains("without running tools")
                || lowerText.contains("without using tools")
                || lowerText.contains("no tools")
                || lowerText.contains("don't use tools")
                || lowerText.contains("do not use tools")
                || lowerText.contains("without running any tools")

            let effectiveToolCallingMode: AgentToolCallingMode = explicitlyNoTools ? .disabled : self.toolCallingMode

            let engine = ModelRegistry.resolveEngine(
                preferredProvider: self.modelPreference.toModelProvider,
                prompt: text,
                history: self.messages,
                instructions: finalInstructions,
                tools: self.allTools.map { $0.name },
                orchestrator: self
            )

            do {
                Logger.agent.info("Generation started (provider: \(self.modelPreference.rawValue, privacy: .public))")
                let generationSpan = AgentSignpost.begin("Generate", detail: self.modelPreference.rawValue)
                defer { AgentSignpost.end("Generate", generationSpan) }

                try await engine.streamResponse(
                    prompt: text,
                    attachments: userMsg.attachments,
                    history: historyMessages,
                    instructions: finalInstructions,
                    toolCallingMode: effectiveToolCallingMode,
                    onUpdate: { @MainActor partialContent in
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                            var copy = self.messages
                            copy[idx].content = partialContent
                            self.messages = copy
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
            let workspace = await MainActor.run { self.currentWorkspacePath }
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
            let workspacePath = await MainActor.run { self.currentWorkspacePath }
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
        do {
            // Enterprise zero-trust capability validation
            if !AgentSecurity.validateCapabilityToken(for: name, botName: nil) {
                throw NSError(domain: "AgentSecurity", code: 403, userInfo: [NSLocalizedDescriptionKey: "Enterprise Security: Missing or expired capability token for high-risk tool '\(name)'"])
            }
            
            let result: String
            if let speculativeResult = await SpeculativeToolExecutor.shared.resolve(toolName: name, jsonArguments: jsonArguments) {
                result = speculativeResult
            } else if let tool = allTools.first(where: { $0.name == name }) {
                result = try await tool.execute(jsonArguments: jsonArguments)
            } else if DynamicToolbox.shared.dynamicTools[name] != nil {
                result = try await DynamicToolbox.shared.executeTool(name: name, jsonArguments: jsonArguments)
            } else {
                throw NSError(domain: "AgentOrchestrator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
            }
            
            // Invalidate cache if a write tool executes
            let speculableToolNames: Set<String> = [
                "read_file", "file_search", "list_directory",
                "get_system_info", "search_memory", "query_logs"
            ]
            if !speculableToolNames.contains(name) {
                await SpeculativeToolExecutor.shared.invalidateAll()
            }
            
            // Audit log
            CryptographicAuditChain.shared.record(
                toolName: name,
                input: jsonArguments,
                output: String(result.prefix(500)),
                status: "success",
                botName: nil
            )
            
            return result
        } catch {
            CryptographicAuditChain.shared.record(
                toolName: name,
                input: jsonArguments,
                output: error.localizedDescription,
                status: "error",
                botName: nil
            )
            throw error
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

    // MARK: - Auto-approve policy (O3/O6 wiring)
    //
    /// When true, tool calls that survive the destructive/sensitive guards are
    /// approved without showing the human a card (Grok Bot-style auto mode).
    public var autoApproveToolCalls: Bool = false
    /// Remembered "Always allow" grant keys (narrowed per-program for shell
    /// tools by `ApprovalPolicy.approvalKey`).
    public var alwaysAllowKeys: [String] = []
    /// True while the current turn was started by an external trigger
    /// (webhook/schedule) with nobody at the keyboard: grants do not inherit.
    public var isUnattendedTurn: Bool = false

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
        let isTesting = ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("xctest")
            || getenv("APEX_TEST_MODE") != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains { $0.localizedCaseInsensitiveContains("test") }
            || Bundle.main.bundleURL.pathExtension == "xctest"
        if isTesting {
            return true
        }

        // O3/O6: auto-grant fast path. The destructive/sensitive guards outrank
        // grants, so an always-allow can never widen into them — a guarded or
        // unguarded-but-ungranted call still falls through to the human card,
        // with the deciding rule written to the decision log either way.
        let isContainer = UserDefaults.standard.bool(forKey: "apex.appleContainersEnabled") && toolName == "run_shell_command"
        let verdict = ApprovalPolicy.verdict(
            tool: toolName,
            summary: arguments,
            alwaysAllow: alwaysAllowKeys,
            autoApprove: autoApproveToolCalls,
            unattended: isUnattendedTurn,
            isContainerSandboxed: isContainer
        )
        if verdict.approve != nil {
            await AgentAuditLog.shared.recordDecision(
                toolName: toolName, arguments: arguments, approved: true,
                source: verdict.source, rule: verdict.rule)
            return true
        }
        if verdict.source != .noGrant {
            // The row worth auditing: this WOULD have auto-approved, and only
            // the guard (or the absence of a grant on an unattended turn)
            // stood in the way.
            await AgentAuditLog.shared.recordDecision(
                toolName: toolName, arguments: arguments, approved: false,
                source: verdict.source, rule: verdict.rule)
        }

        if let gateway = confirmationGateway {
            let approved = await gateway(toolName, arguments, riskDescription)
            await AgentAuditLog.shared.recordDecision(
                toolName: toolName, arguments: arguments, approved: approved,
                source: .user, rule: nil)
            return approved
        }
        let approved: Bool = await withCheckedContinuation { continuation in
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
            
            // Relay confirmation request to paired Remote Companion (iPhone / iPad)
            let companionEvent = CompanionApprovalRelayEvent(
                requestId: request.id.uuidString,
                stageId: "orchestrator_tool",
                stageName: toolName,
                summary: riskDescription,
                riskLevel: "high"
            )
            RemoteCompanionGateway.shared.postApprovalRelay(companionEvent)

            // Auto-deny after timeout
            confirmationTimeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(AgentOrchestrator.confirmationTimeoutSeconds))
                if self.pendingConfirmation?.id == request.id {
                    self.resolveConfirmation(approved: false)
                }
            }
        }
        await AgentAuditLog.shared.recordDecision(
            toolName: toolName, arguments: arguments, approved: approved,
            source: .user, rule: nil)
        return approved
    }

    public func resolveConfirmation(approved: Bool) {
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        guard let pending = pendingConfirmation else { return }
        _ = RemoteCompanionGateway.shared.resolveApprovalRelay(requestId: pending.id.uuidString, allow: approved)
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
