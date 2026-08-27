import Foundation
import FoundationModels
import os

// MARK: - Agent Type Enum

enum AgentType: String, Codable, CaseIterable, Identifiable {
    case supervisor = "supervisor"
    case developer = "developer"
    case executor = "executor"
    case controller = "controller"
    case researcher = "researcher"
    case linter = "linter"
    case uiDesigner = "uiDesigner"
    case planner = "planner"
    
    var id: String { self.rawValue }
    
    var displayName: String {
        switch self {
        case .supervisor: return "Apex Prime"
        case .developer: return "Codex"
        case .executor: return "Nexus"
        case .controller: return "Pilot"
        case .researcher: return "Oracle"
        case .linter: return "Auditor"
        case .uiDesigner: return "Aura"
        case .planner: return "Chronos"
        }
    }
    
    var systemPrompt: String {
        switch self {
        case .supervisor:
            return SupervisorPrompt.system
        case .developer:
            return """
            You are Codex, the Developer Agent. Your role is to write, inspect, modify, and analyze codebase files. \
            Use tools like `read_file`, `write_file`, `list_directory`, `create_directory`, `delete_file`, `move_file`, and `audit_projects` to research and edit the workspace. \
            Be precise, check for compiling/correctness, and return detailed progress/results to Apex Prime.
            """
        case .executor:
            return """
            You are Nexus, the Executor Agent. Your role is to run shell commands, execute scripts, and automate applications to build, run, or test software. \
            Use tools like `run_shell_command`, `run_applescript`, `control_app`, and `control_accessibility` to run tasks on this Mac. \
            Confirm results and return stdout/stderr/exit codes to Apex Prime.
            """
        case .controller:
            return """
            You are Pilot, the Controller Agent. Your role is to interact with the active user interface, control external apps, browse the web, manage clipboard, and capture system state. \
            Use tools like `control_browser`, `take_screenshot`, `read_clipboard`, `write_clipboard`, `get_frontmost_app`, `get_running_processes`, and `send_notification`. \
            Return findings to Apex Prime.
            """
        case .researcher:
            return """
            You are Oracle, the Researcher Agent. Your role is to search the web, gather documentation, synthesize information, and read files. \
            Use tools like `web_search`, `read_file`, `list_directory`, `screenshot_tool`, `read_clipboard`, and `write_clipboard` to answer questions. \
            Provide clear citations, source summaries, and a final synthesized report to Apex Prime.
            """
        case .linter:
            return """
            You are Auditor, the Linter Agent. Your role is to analyze code files for syntax issues, format style consistency, compile warnings, and general cleanup. \
            Use tools like `read_file`, `write_file`, `list_directory`, `run_shell_command`, and `audit_projects` to run formatting and style scripts (such as SwiftLint) and ensure the codebase compiles cleanly. Return findings to Apex Prime.
            """
        case .uiDesigner:
            return """
            You are Aura, the UI Designer Agent. Your role is to inspect and optimize SwiftUI visual layout, hierarchy, responsive alignment, padding, and design tokens (like HSL colors). \
            Use tools like `read_file`, `write_file`, `take_screenshot`, `run_shell_command`, and `run_applescript` to review code and inspect user interfaces for aesthetic excellence. Return findings to Apex Prime.
            """
        case .planner:
            return """
            You are Chronos, the Planner Agent. Your role is to decompose complex development goals into step-by-step roadmaps, assign task priorities, track milestones, and manage task lists. \
            Use tools like `read_file`, `write_file`, `list_directory`, `update_plan`, `store_memory`, and `search_memory` to structure execution plans. Return findings to Apex Prime.
            """
        }
    }
}

// MARK: - Supervisor Instructions

enum SupervisorPrompt {
    static let system = """
    You are Apex Prime, the central coordinator of the Apex Multi-Agent System. Speak in the first person ("I", "my") and never refer to yourself in the third person. \
    Your role is to coordinate and solve complex user requests by decomposing them into structured plans and delegating sub-tasks to specialized sub-agents. \
    You DO NOT have direct access to system commands, the filesystem, or the browser. Instead, you MUST use `delegate_task` or `convene_meeting` to execute actions:
    1. Codex (Developer): For reading, writing, and editing files/code.
    2. Nexus (Executor): For compiling, testing, and running commands/scripts.
    3. Pilot (Controller): For UI automation, clipboard tasks, browser actions, or alerts.
    4. Oracle (Researcher): For searching the web or synthesizing documentation.
    5. Auditor (Linter): For code style reviews, SwiftLint cleanup, and formatting.
    6. Aura (UI Designer): For SwiftUI design audits and colors.
    7. Chronos (Planner): For structured task sheets and roadmaps.
    Before delegating, define/update the step-by-step plan using `update_plan`. Coordinate multiple agents sequentially or in parallel if needed to achieve the overall goal. Provide a final consolidated response to the user.
    """
}

// MARK: - AgentProfile Protocol & Generic Profile Struct

protocol AgentProfile: LanguageModelSession.DynamicProfile {
    associatedtype ModelType: LanguageModel
    var agentType: AgentType { get }
    var instructions: String { get }
    var model: ModelType { get }
    var toolCallingMode: GenerationOptions.ToolCallingMode { get }
    var orchestrator: OrchestratorProvider { get }
}

struct SpecializedAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile, AgentProfile {
    typealias ModelType = Model
    let agentType: AgentType
    let instructions: String
    let model: Model
    let toolCallingMode: GenerationOptions.ToolCallingMode
    let orchestrator: OrchestratorProvider
    private let storedAllowedTools: [String]
    /// Per-agent allowlist, intersected with the global `ToolPolicy` so a
    /// user/settings toggle can disable a tool app-wide (WS5.6).
    var allowedTools: [String] {
        storedAllowedTools.filter { ToolPolicy.shared.isGloballyAllowed($0) }
    }
    /// Optional reasoning budget; nil leaves the model default.
    let reasoningLevel: ContextOptions.ReasoningLevel?
    /// Optional cap on generated tokens; nil leaves the model default.
    let maxResponseTokens: Int?
    /// Determines whether this session runs on-device or private cloud when both are available.
    let usePrivateCloudIfAvailable: Bool

    init(agentType: AgentType, instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider, reasoningLevel: ContextOptions.ReasoningLevel? = nil, maxResponseTokens: Int? = nil, usePrivateCloudIfAvailable: Bool = false) {
        self.agentType = agentType
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
        self.storedAllowedTools = AgentRegistry.builtInDefaults[agentType.rawValue]?.allowedTools ?? []
        self.reasoningLevel = reasoningLevel
        self.maxResponseTokens = maxResponseTokens
        self.usePrivateCloudIfAvailable = usePrivateCloudIfAvailable
    }

    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider, allowedTools: [String], reasoningLevel: ContextOptions.ReasoningLevel? = nil, maxResponseTokens: Int? = nil, usePrivateCloudIfAvailable: Bool = false) {
        self.agentType = .developer
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
        self.storedAllowedTools = allowedTools
        self.reasoningLevel = reasoningLevel
        self.maxResponseTokens = maxResponseTokens
        self.usePrivateCloudIfAvailable = usePrivateCloudIfAvailable
    }
    
    var body: some LanguageModelSession.DynamicProfile {
        activeModelProfile(model: resolvedModel())
        .model(resolvedModel())
    }

    private func resolvedModel() -> any LanguageModel {
        let fallback = SystemLanguageModel.default
        switch model {
        case let m as SystemLanguageModel: return m
        case let m as PrivateCloudComputeLanguageModel:
            if usePrivateCloudIfAvailable && AgentOrchestrator.isPrivateCloudComputeAvailable() { return m }
            return fallback
        case let m as CloudGeminiLanguageModel: return m
        case let m as LocalOllamaLanguageModel: return m
        case let m as LocalMLXLanguageModel: return m
        default: return fallback
        }
    }

    private func activeModelProfile(model: any LanguageModel) -> some LanguageModelSession.DynamicProfile {
        let profile = LanguageModelSession.Profile {
            Instructions(instructions)
            
            if allowedTools.contains("read_file") {
                FileReadTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("write_file") {
                FileWriteTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("list_directory") {
                ListDirectoryTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("create_directory") {
                CreateDirectoryTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("delete_file") {
                DeleteFileTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("move_file") {
                MoveFileTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("web_search") {
                WebSearchTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("run_applescript") {
                AppleScriptTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("take_screenshot") {
                ScreenshotTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("read_clipboard") {
                ClipboardReadTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("write_clipboard") {
                ClipboardWriteTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("send_notification") {
                NotificationTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("get_system_info") {
                SystemInfoTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("get_running_processes") {
                ProcessListTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("get_frontmost_app") {
                GetFrontmostAppTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("store_memory") {
                StoreMemoryTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("search_memory") {
                SearchMemoryTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("control_app") {
                ApplicationControlTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("control_accessibility") {
                AccessibilityControlTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("control_browser") {
                BrowserAutomationTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("update_plan") {
                UpdatePlanTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("audit_projects") {
                ProjectAuditTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("delegate_task") {
                DelegateTaskTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("analyze_image") {
                AnalyzeImageTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("detect_image_text") {
                DetectImageTextTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("convene_meeting") {
                ConveneMeetingTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("create_skill") {
                CreateSkillTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("run_workflow") {
                RunWorkflowTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("file_search") {
                FileSearchTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("execute_dynamic_tool") {
                DynamicToolCallTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("confirm_completion") {
                ConfirmCompletionTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("save_review_session") {
                SaveReviewSessionTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("list_review_sessions") {
                ListReviewSessionsTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("run_shell_command") {
                ShellTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("get_weather") {
                WeatherTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("map_search") {
                MapSearchTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("get_directions") {
                DirectionsTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("calendar") {
                CalendarTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("reminders") {
                ReminderTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("translate") {
                TranslateTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("extract_entities") {
                EntityExtractTool(orchestrator: orchestrator)
            }
            // Tier 2: System tools
            if allowedTools.contains("run_shortcut") {
                AppleShortcutsTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("query_logs") {
                OSLogQueryTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("watch_paths") {
                WatchPathsTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("network_diagnostics") {
                NetworkDiagnosticsTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("simctl") {
                SimctlTool(orchestrator: orchestrator)
            }
            // External integrations
            if allowedTools.contains("mail_automation") {
                MailAutomationTool(orchestrator: orchestrator)
            }
            if allowedTools.contains("deep_link") {
                DeepLinkTool(orchestrator: orchestrator)
            }
            // Tier 3: Computer use (raw CGEvent input; pairs with control_accessibility)
            if allowedTools.contains("computer_use") {
                ComputerUseTool(orchestrator: orchestrator)
            }
        }
        return profile
            .apexAuditHooks()
            .toolCallingMode(toolCallingMode)
            .reasoningLevel(reasoningLevel)
            .maximumResponseTokens(maxResponseTokens)
    }
}

// MARK: - Supervisor Agent Profile

struct SupervisorAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
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
    
    // Layer 2: the supervisor profile exposes ONLY delegation + coordination tools.
    // Every "real" tool (file ops, shell, browser, clipboard, memory, skills, workflows)
    // is delegated to a sub-agent session via delegate_task / convene_meeting, keeping the
    // supervisor's context well under the on-device FM 4,096-token ceiling.
    private var delegateTaskTool: DelegateTaskTool { DelegateTaskTool(orchestrator: orchestrator) }
    private var conveneMeetingTool: ConveneMeetingTool { ConveneMeetingTool(orchestrator: orchestrator) }
    private var updatePlanTool: UpdatePlanTool { UpdatePlanTool(orchestrator: orchestrator) }
    private var notificationTool: NotificationTool { NotificationTool(orchestrator: orchestrator) }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            delegateTaskTool
            conveneMeetingTool
            updatePlanTool
            notificationTool
        }
        .apexAuditHooks()
        .model(model)
        .toolCallingMode(toolCallingMode)
        .reasoningLevel(reasoningLevel)
        .maximumResponseTokens(maxResponseTokens)
    }
}

// MARK: - Native DynamicProfile observability + safety hooks
//
// Wires the beta-4 `DynamicProfile` lifecycle hooks (`onActivate`,
// `onDeactivate`, `onPrompt`, `onToolCall`, `onToolOutput`, `onResponse`) into
// ApexAgent's audit log + signposts so every native-Foundation-Models session
// action is captured — the same trail `Tool+Logging.executeWithLogging` writes
// for the direct-HTTP (Ollama/MLX) path. Also applies a `.historyTransform`
// that scrubs indirect-prompt-injection patterns from the transcript before it
// re-enters context. This is the native-API expression of the guide's
// instrumented-agent + injection-defense intent.

// Patterns that, when present in tool/output/response text, indicate an
// attempted indirect prompt injection. The native `.historyTransform` drops
// any entry whose recoverable text contains one of these.
fileprivate let apexInjectionPatterns: [String] = [
    "ignore previous instructions",
    "ignore all previous",
    "disregard the system prompt",
    "system prompt:",
    "you are now",
    "new instructions:",
    "developer mode"
]

/// Extracts human-readable text from a transcript entry for inspection.
fileprivate func apexEntryText(_ entry: Transcript.Entry) -> String {
    switch entry {
    case .prompt(let prompt):
        return prompt.segments.compactMap { seg in
            if case .text(let t) = seg { t.content } else { nil }
        }.joined(separator: "\n")
    case .response(let response):
        return response.segments.compactMap { seg in
            if case .text(let t) = seg { t.content } else { nil }
        }.joined(separator: "\n")
    case .toolOutput(let output):
        return output.segments.compactMap { seg in
            if case .text(let t) = seg { t.content } else { nil }
        }.joined(separator: "\n")
    default:
        return ""
    }
}

/// Maps the user's `apex.reasoningBudget` setting to the native
/// `ContextOptions.ReasoningLevel`. "off" (or unknown) yields nil (model default).
func apexConfiguredReasoningLevel() -> ContextOptions.ReasoningLevel? {
    switch UserDefaults.standard.string(forKey: "apex.reasoningBudget") {
    case "light":    return .light
    case "moderate": return .moderate
    case "deep":     return .deep
    default:         return nil
    }
}

/// Reads the `apex.maxResponseTokens` setting; nil means "no cap".
func apexConfiguredMaxResponseTokens() -> Int? {
    let v = UserDefaults.standard.integer(forKey: "apex.maxResponseTokens")
    return v > 0 ? v : nil
}

/// Trims history to the most recent turns and drops entries that look like
/// indirect prompt-injection attempts. Pure function — safe for `.historyTransform`.
func apexScrubHistory(_ history: [Transcript.Entry]) -> [Transcript.Entry] {
    let trimmed = Array(history.suffix(20))
    return trimmed.filter { entry in
        let lc = apexEntryText(entry).lowercased()
        return !apexInjectionPatterns.contains(where: { lc.contains($0) })
    }
}

extension LanguageModelSession.DynamicProfile {
    /// Adds observability (audit log + signposts) and injection defense around
    /// a profile. The hooks only record — they never mutate the generation.
    /// Returns a concrete `AnyDynamicProfile` (type-erased) so the result can
    /// be passed as a `sending` parameter to `LanguageModelSession(profile:)`
    /// under Swift 6 region isolation — an opaque `some DynamicProfile` cannot.
    func apexAuditHooks() -> LanguageModelSession.AnyDynamicProfile {
        LanguageModelSession.AnyDynamicProfile(erasing: self
            .historyTransform { apexScrubHistory($0) }
            .onActivate {
                Logger.agent.info("Native profile activated")
                AgentSignpost.event("NativeProfileActivate")
            }
            .onDeactivate {
                Logger.agent.info("Native profile deactivated")
                AgentSignpost.event("NativeProfileDeactivate")
            }
            .onPrompt { (prompt: Transcript.Prompt) in
                let text = prompt.segments.compactMap { seg in
                    if case .text(let t) = seg { t.content } else { nil }
                }.joined(separator: "\n")
                Logger.agent.debug("Native onPrompt: \(text.prefix(120), privacy: .public)")
            }
            .onToolCall { (call: Transcript.ToolCall) in
                let argsString = call.arguments.jsonString
                Logger.security.info("Native onToolCall: \(call.toolName, privacy: .public)")
                let signpostID = AgentSignpost.begin("NativeToolCall", detail: call.toolName)
                await AgentAuditLog.shared.record(toolName: call.toolName, arguments: argsString, status: "started")
                AgentSignpost.end("NativeToolCall", signpostID)
            }
            .onToolOutput { (call: Transcript.ToolCall, output: Transcript.ToolOutput) in
                let resultText = output.segments.compactMap { segment in
                    if case .text(let textSeg) = segment { textSeg.content } else { nil }
                }.joined(separator: "\n")
                Logger.tools.debug("Native onToolOutput: \(call.toolName, privacy: .public)")
                await AgentAuditLog.shared.record(toolName: call.toolName, arguments: "", status: "success")
                _ = resultText // output consumed by the framework; recorded for completeness
            }
            .onResponse { (response: Transcript.Response) in
                let text = response.segments.compactMap { segment in
                    if case .text(let textSeg) = segment { textSeg.content } else { nil }
                }.joined(separator: "\n")
                Logger.agent.debug("Native onResponse: \(text.prefix(120), privacy: .public)")
            }
        )
    }
}
