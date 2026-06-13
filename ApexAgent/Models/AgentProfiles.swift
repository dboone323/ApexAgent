import Foundation
import FoundationModels

// MARK: - Agent Type Enum

enum AgentType: String, Codable, CaseIterable, Identifiable {
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

// MARK: - Supervisor Agent Profile

struct SupervisorAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    let toolCallingMode: GenerationOptions.ToolCallingMode
    let orchestrator: OrchestratorProvider?
    
    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider? = nil) {
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
    }
    
    private var delegateTaskTool: DelegateTaskTool { DelegateTaskTool(orchestrator: orchestrator!) }
    private var conveneMeetingTool: ConveneMeetingTool { ConveneMeetingTool(orchestrator: orchestrator!) }
    private var updatePlanTool: UpdatePlanTool { UpdatePlanTool(orchestrator: orchestrator!) }
    private var notificationTool: NotificationTool { NotificationTool(orchestrator: orchestrator!) }
    private var storeMemoryTool: StoreMemoryTool { StoreMemoryTool(orchestrator: orchestrator!) }
    private var searchMemoryTool: SearchMemoryTool { SearchMemoryTool(orchestrator: orchestrator!) }
    private var createSkillTool: CreateSkillTool { CreateSkillTool(orchestrator: orchestrator!) }
    private var runWorkflowTool: RunWorkflowTool { RunWorkflowTool(orchestrator: orchestrator!) }
    private var dynamicToolCallTool: DynamicToolCallTool { DynamicToolCallTool(orchestrator: orchestrator!) }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            
            delegateTaskTool
            conveneMeetingTool
            updatePlanTool
            notificationTool
            storeMemoryTool
            searchMemoryTool
            createSkillTool
            runWorkflowTool
            dynamicToolCallTool
        }
        .model(model)
        .toolCallingMode(toolCallingMode)
    }
}

// MARK: - Developer Agent Profile

struct DeveloperAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    let toolCallingMode: GenerationOptions.ToolCallingMode
    
        let orchestrator: OrchestratorProvider?
    
    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider? = nil) {
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
    }
    
    private var fileReadTool: FileReadTool { FileReadTool(orchestrator: orchestrator!) }
    private var fileWriteTool: FileWriteTool { FileWriteTool(orchestrator: orchestrator!) }
    private var listDirectoryTool: ListDirectoryTool { ListDirectoryTool(orchestrator: orchestrator!) }
    private var createDirectoryTool: CreateDirectoryTool { CreateDirectoryTool(orchestrator: orchestrator!) }
    private var deleteFileTool: DeleteFileTool { DeleteFileTool(orchestrator: orchestrator!) }
    private var moveFileTool: MoveFileTool { MoveFileTool(orchestrator: orchestrator!) }
    private var projectAuditTool: ProjectAuditTool { ProjectAuditTool(orchestrator: orchestrator!) }
    private var createSkillTool: CreateSkillTool { CreateSkillTool(orchestrator: orchestrator!) }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            
            fileReadTool
            fileWriteTool
            listDirectoryTool
            createDirectoryTool
            deleteFileTool
            moveFileTool
            projectAuditTool
            createSkillTool
        }
        .model(model)
        .toolCallingMode(toolCallingMode)
    }
}

// MARK: - Executor Agent Profile

struct ExecutorAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    let toolCallingMode: GenerationOptions.ToolCallingMode
    
        let orchestrator: OrchestratorProvider?
    
    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider? = nil) {
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
    }
    
    private var shellTool: ShellTool { ShellTool(orchestrator: orchestrator!) }
    private var appleScriptTool: AppleScriptTool { AppleScriptTool(orchestrator: orchestrator!) }
    private var applicationControlTool: ApplicationControlTool { ApplicationControlTool(orchestrator: orchestrator!) }
    private var accessibilityControlTool: AccessibilityControlTool { AccessibilityControlTool(orchestrator: orchestrator!) }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            
            shellTool
            appleScriptTool
            applicationControlTool
            accessibilityControlTool
        }
        .model(model)
        .toolCallingMode(toolCallingMode)
    }
}

// MARK: - Controller Agent Profile

struct ControllerAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    let toolCallingMode: GenerationOptions.ToolCallingMode
    
        let orchestrator: OrchestratorProvider?
    
    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider? = nil) {
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
    }
    
    private var getFrontmostAppTool: GetFrontmostAppTool { GetFrontmostAppTool(orchestrator: orchestrator!) }
    private var processListTool: ProcessListTool { ProcessListTool(orchestrator: orchestrator!) }
    private var clipboardReadTool: ClipboardReadTool { ClipboardReadTool(orchestrator: orchestrator!) }
    private var clipboardWriteTool: ClipboardWriteTool { ClipboardWriteTool(orchestrator: orchestrator!) }
    private var notificationTool: NotificationTool { NotificationTool(orchestrator: orchestrator!) }
    private var systemInfoTool: SystemInfoTool { SystemInfoTool(orchestrator: orchestrator!) }
    private var accessibilityControlTool: AccessibilityControlTool { AccessibilityControlTool(orchestrator: orchestrator!) }
    private var applicationControlTool: ApplicationControlTool { ApplicationControlTool(orchestrator: orchestrator!) }
    private var browserAutomationTool: BrowserAutomationTool { BrowserAutomationTool(orchestrator: orchestrator!) }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            
            getFrontmostAppTool
            processListTool
            clipboardReadTool
            clipboardWriteTool
            notificationTool
            systemInfoTool
            accessibilityControlTool
            applicationControlTool
            browserAutomationTool
        }
        .model(model)
        .toolCallingMode(toolCallingMode)
    }
}

// MARK: - Researcher Agent Profile

struct ResearcherAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    let toolCallingMode: GenerationOptions.ToolCallingMode
    
        let orchestrator: OrchestratorProvider?
    
    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider? = nil) {
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
    }
    
    private var webSearchTool: WebSearchTool { WebSearchTool(orchestrator: orchestrator!) }
    private var clipboardReadTool: ClipboardReadTool { ClipboardReadTool(orchestrator: orchestrator!) }
    private var clipboardWriteTool: ClipboardWriteTool { ClipboardWriteTool(orchestrator: orchestrator!) }
    private var fileReadTool: FileReadTool { FileReadTool(orchestrator: orchestrator!) }
    private var listDirectoryTool: ListDirectoryTool { ListDirectoryTool(orchestrator: orchestrator!) }
    private var screenshotTool: ScreenshotTool { ScreenshotTool(orchestrator: orchestrator!) }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            
            webSearchTool
            clipboardReadTool
            clipboardWriteTool
            fileReadTool
            listDirectoryTool
            screenshotTool
        }
        .model(model)
        .toolCallingMode(toolCallingMode)
    }
}

// MARK: - Linter Agent Profile

struct LinterAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    let toolCallingMode: GenerationOptions.ToolCallingMode
    
        let orchestrator: OrchestratorProvider?
    
    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider? = nil) {
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
    }
    
    private var fileReadTool: FileReadTool { FileReadTool(orchestrator: orchestrator!) }
    private var fileWriteTool: FileWriteTool { FileWriteTool(orchestrator: orchestrator!) }
    private var listDirectoryTool: ListDirectoryTool { ListDirectoryTool(orchestrator: orchestrator!) }
    private var shellTool: ShellTool { ShellTool(orchestrator: orchestrator!) }
    private var projectAuditTool: ProjectAuditTool { ProjectAuditTool(orchestrator: orchestrator!) }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            
            fileReadTool
            fileWriteTool
            listDirectoryTool
            shellTool
            projectAuditTool
        }
        .model(model)
        .toolCallingMode(toolCallingMode)
    }
}

// MARK: - UI Designer Agent Profile

struct UIDesignerAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    let toolCallingMode: GenerationOptions.ToolCallingMode
    
        let orchestrator: OrchestratorProvider?
    
    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider? = nil) {
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
    }
    
    private var fileReadTool: FileReadTool { FileReadTool(orchestrator: orchestrator!) }
    private var fileWriteTool: FileWriteTool { FileWriteTool(orchestrator: orchestrator!) }
    private var screenshotTool: ScreenshotTool { ScreenshotTool(orchestrator: orchestrator!) }
    private var shellTool: ShellTool { ShellTool(orchestrator: orchestrator!) }
    private var appleScriptTool: AppleScriptTool { AppleScriptTool(orchestrator: orchestrator!) }
    private var applicationControlTool: ApplicationControlTool { ApplicationControlTool(orchestrator: orchestrator!) }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            
            fileReadTool
            fileWriteTool
            screenshotTool
            shellTool
            appleScriptTool
            applicationControlTool
        }
        .model(model)
        .toolCallingMode(toolCallingMode)
    }
}

// MARK: - Planner Agent Profile

struct PlannerAgentProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    let toolCallingMode: GenerationOptions.ToolCallingMode
    
        let orchestrator: OrchestratorProvider?
    
    init(instructions: String, model: Model, toolCallingMode: GenerationOptions.ToolCallingMode, orchestrator: OrchestratorProvider? = nil) {
        self.instructions = instructions
        self.model = model
        self.toolCallingMode = toolCallingMode
        self.orchestrator = orchestrator
    }
    
    private var fileReadTool: FileReadTool { FileReadTool(orchestrator: orchestrator!) }
    private var fileWriteTool: FileWriteTool { FileWriteTool(orchestrator: orchestrator!) }
    private var listDirectoryTool: ListDirectoryTool { ListDirectoryTool(orchestrator: orchestrator!) }
    private var updatePlanTool: UpdatePlanTool { UpdatePlanTool(orchestrator: orchestrator!) }
    private var storeMemoryTool: StoreMemoryTool { StoreMemoryTool(orchestrator: orchestrator!) }
    private var searchMemoryTool: SearchMemoryTool { SearchMemoryTool(orchestrator: orchestrator!) }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            
            fileReadTool
            fileWriteTool
            listDirectoryTool
            updatePlanTool
            storeMemoryTool
            searchMemoryTool
        }
        .model(model)
        .toolCallingMode(toolCallingMode)
    }
}
