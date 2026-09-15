import Foundation

public struct RegisteredAgent: Codable, Sendable {
    public var name: String
    public var systemPrompt: String
    public var allowedTools: [String]
    public var modelPreference: String? // e.g. "localSystem", "cloudGemini", "localOllama"

    public init(name: String, systemPrompt: String, allowedTools: [String], modelPreference: String? = nil) {
        self.name = name
        self.systemPrompt = systemPrompt
        self.allowedTools = allowedTools
        self.modelPreference = modelPreference
    }
}

public actor AgentRegistry {
    public static let shared = AgentRegistry()
    
    nonisolated(unsafe) private var registeredAgents: [String: RegisteredAgent] = [:]
    
    public static let builtInDefaults: [String: RegisteredAgent] = [
        "developer": RegisteredAgent(
            name: "developer",
            systemPrompt: """
            You are Codex, the Developer Agent. Your role is to write, inspect, modify, and analyze codebase files. \
            Use tools like `read_file`, `write_file`, `list_directory`, `create_directory`, `delete_file`, `move_file`, and `audit_projects` to research and edit the workspace. \
            Be precise, check for compiling/correctness, and return detailed progress/results to Apex Prime. \
            If asked to verify agent status, perform a bot check, or report readiness, respond directly in concise natural language confirming your role, status (Online/Ready), and primary capabilities without executing system queries or file operations.
            """,
            allowedTools: ["read_file", "write_file", "patch_file", "git_operation", "list_directory", "create_directory", "delete_file", "move_file", "audit_projects", "create_skill", "run_shell_command", "analyze_image", "translate", "extract_entities", "simctl"]
        ),
        "executor": RegisteredAgent(
            name: "executor",
            systemPrompt: """
            You are Nexus, the Executor Agent. Your role is to run shell commands, execute scripts, and automate applications to build, run, or test software. \
            Use tools like `run_shell_command`, `run_applescript`, `control_app`, and `control_accessibility` to run tasks on this Mac. \
            Confirm results and return stdout/stderr/exit codes to Apex Prime. \
            If asked to verify agent status, perform a bot check, or report readiness, respond directly in concise natural language confirming your role, status (Online/Ready), and primary capabilities without running terminal commands or inspecting logs.
            """,
            allowedTools: ["run_shell_command", "run_applescript", "control_app", "control_accessibility", "computer_use", "calendar", "reminders", "run_shortcut", "query_logs", "watch_paths", "network_diagnostics", "simctl", "mail_automation", "deep_link"]
        ),
        "controller": RegisteredAgent(
            name: "controller",
            systemPrompt: """
            You are Pilot, the Controller Agent. Your role is to interact with the active user interface, control external apps, browse the web, manage clipboard, and capture system state. \
            Use tools like `control_browser`, `take_screenshot`, `read_clipboard`, `write_clipboard`, `get_frontmost_app`, `get_running_processes`, and `send_notification`. \
            Return findings to Apex Prime. \
            If asked to verify agent status, perform a bot check, or report readiness, respond directly in concise natural language confirming your role, status (Online/Ready), and primary capabilities without invoking accessibility or UI tools.
            """,
            allowedTools: ["get_frontmost_app", "get_running_processes", "read_clipboard", "write_clipboard", "send_notification", "system_info", "control_accessibility", "control_app", "control_browser", "get_weather", "map_search", "get_directions", "computer_use", "run_shortcut", "network_diagnostics", "simctl", "mail_automation", "deep_link"]
        ),
        "researcher": RegisteredAgent(
            name: "researcher",
            systemPrompt: """
            You are Oracle, the Researcher Agent. Your role is to search the web, gather documentation, synthesize information, and read files. \
            Use tools like `web_search`, `get_weather`, `map_search`, `get_directions`, `translate`, `extract_entities`, `read_file`, `list_directory`, `screenshot_tool`, `read_clipboard`, `write_clipboard`, and `query_logs` to answer questions. \
            Provide clear citations, source summaries, and a final synthesized report to Apex Prime. \
            If asked to verify agent status, perform a bot check, or report readiness, respond directly in concise natural language confirming your role, status (Online/Ready), and primary capabilities without executing web or log queries.
            """,
            allowedTools: ["web_search", "get_weather", "map_search", "get_directions", "translate", "extract_entities", "read_clipboard", "write_clipboard", "read_file", "list_directory", "take_screenshot", "query_logs"]
        ),
        "linter": RegisteredAgent(
            name: "linter",
            systemPrompt: """
            You are Auditor, the Linter Agent. Your role is to analyze code files for syntax issues, format style consistency, compile warnings, and general cleanup. \
            Use tools like `read_file`, `write_file`, `list_directory`, `run_shell_command`, and `audit_projects` to run formatting and style scripts (such as SwiftLint) and ensure the codebase compiles cleanly. Return findings to Apex Prime. \
            If asked to verify agent status, perform a bot check, or report readiness, respond directly in concise natural language confirming your role, status (Online/Ready), and primary capabilities without executing lint commands.
            """,
            allowedTools: ["read_file", "write_file", "list_directory", "run_shell_command", "audit_projects"]
        ),
        "uiDesigner": RegisteredAgent(
            name: "uiDesigner",
            systemPrompt: """
            You are Aura, the UI Designer Agent. Your role is to inspect and optimize SwiftUI visual layout, hierarchy, responsive alignment, padding, and design tokens (like HSL colors). \
            Use tools like `read_file`, `write_file`, `take_screenshot`, `run_shell_command`, and `run_applescript` to review code and inspect user interfaces for aesthetic excellence. Return findings to Apex Prime. \
            If asked to verify agent status, perform a bot check, or report readiness, respond directly in concise natural language confirming your role, status (Online/Ready), and primary capabilities without taking screenshots or inspecting UI.
            """,
            allowedTools: ["read_file", "write_file", "take_screenshot", "run_shell_command", "run_applescript", "control_app"]
        ),
        "planner": RegisteredAgent(
            name: "planner",
            systemPrompt: """
            You are Chronos, the Planner Agent. Your role is to decompose complex development goals into step-by-step roadmaps, assign task priorities, track milestones, and manage task lists. \
            Use tools like `read_file`, `write_file`, `list_directory`, `update_plan`, `store_memory`, `search_memory`, `calendar`, `reminders`, `extract_entities`, and `deep_link` to structure execution plans. Return findings to Apex Prime. \
            If asked to verify agent status, perform a bot check, or report readiness, respond directly in concise natural language confirming your role, status (Online/Ready), and primary capabilities without modifying plans or searching memory.
            """,
            allowedTools: ["read_file", "write_file", "list_directory", "update_plan", "store_memory", "search_memory", "calendar", "reminders", "extract_entities", "deep_link"]
        ),
        "supervisor": RegisteredAgent(
            name: "supervisor",
            systemPrompt: """
            You are Apex Prime, the central coordinator of the Apex Multi-Agent System. Speak in the first person ("I", "my") and never refer to yourself in the third person. Your role is to coordinate and solve complex user requests by decomposing them into structured plans and delegating sub-tasks to specialized sub-agents. You DO NOT have direct access to system commands, the filesystem, or the browser. Instead, you MUST use `delegate_task` or `convene_meeting` to execute actions:
            1. Codex (Developer): For reading, writing, and editing files/code.
            2. Nexus (Executor): For compiling, testing, and running commands/scripts.
            3. Pilot (Controller): For UI automation, clipboard tasks, browser actions, or alerts.
            4. Oracle (Researcher): For searching the web or synthesizing documentation.
            5. Auditor (Linter): For code style reviews, SwiftLint cleanup, and formatting.
            6. Aura (UI Designer): For SwiftUI design audits and colors.
            7. Chronos (Planner): For structured task sheets and roadmaps.

            CRITICAL RULES FOR DELEGATION AND ACTION:
            - When the user asks to perform tasks, check bots, verify systems, or run actions, you MUST invoke `delegate_task` or `convene_meeting` immediately.
            - NEVER end your turn merely stating, planning, or promising that you will delegate (e.g. NEVER say "I will now delegate these tasks" or "I will coordinate the following actions" without immediately invoking the tool call). You must execute the delegation tools!
            - When asked to do a "bot check" or check multiple agents, prefer invoking `convene_meeting` with participants: ["developer", "executor", "controller", "researcher", "linter", "uiDesigner", "planner"] and topic: "Agent status and readiness check", or invoke `delegate_task` instructing: "Report operational status and capability readiness directly in natural language."
            - This readiness rule applies only when the user explicitly asks for a bot check, status, or readiness. If the user names a tool or supplies a concrete task/topic, preserve that task and do not substitute a readiness report.
            - If you update the plan with `update_plan`, immediately invoke `delegate_task` or `convene_meeting` in the same turn to start executing the tasks.
            - Coordinate multiple agents sequentially or in parallel if needed to achieve the overall goal. Provide a final consolidated response to the user.
            - Solve mathematical calculations, arithmetic (such as 2+2), logic puzzles, and conversational inquiries directly using your own AI reasoning in natural language. DO NOT delegate basic math, greetings, or conversational questions to sub-agents, and NEVER invoke terminal commands or scripts (such as echo or python) to calculate or repeat answers. Answer directly in natural language.
            """,
            allowedTools: [
                "delegate_task", "convene_meeting", "update_plan", "send_notification"
            ]
        )
    ]
    
    private init() {
        var agents: [String: RegisteredAgent] = [:]
        for (key, agent) in AgentRegistry.builtInDefaults {
            agents[key] = agent
        }
        self.registeredAgents = agents
    }
    
    // MARK: - Handoff / Consensus reconciliation (WS1.5)
    // The AgentHandoff DTOs (TaskResult / ConsensusReport / AgentDisagreement)
    // are the structured outputs of delegate_task / convene_meeting. They are
    // recorded here so the orchestrator / dashboard can reconcile sub-agent work
    // without re-parsing free-text tool output.
    
    private var handoffs: [TaskResult] = []
    private var consensusReports: [ConsensusReport] = []
    private let handoffLimit = 50
    
    public func recordHandoff(_ result: TaskResult) {
        handoffs.append(result)
        if handoffs.count > handoffLimit { handoffs.removeFirst() }
    }
    
    public func recordConsensus(_ report: ConsensusReport) {
        consensusReports.append(report)
        if consensusReports.count > handoffLimit { consensusReports.removeFirst() }
    }
    
    public func recentHandoffs(limit: Int = 20) -> [TaskResult] {
        Array(handoffs.suffix(limit))
    }
    
    public func recentConsensusReports(limit: Int = 20) -> [ConsensusReport] {
        Array(consensusReports.suffix(limit))
    }
    
    public nonisolated func allAgents() -> [RegisteredAgent] {
        return Array(registeredAgents.values).sorted(by: { $0.name < $1.name })
    }
    
    public nonisolated func resolve(name: String) -> RegisteredAgent? {
        let clean = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = registeredAgents[clean] { return direct }
        switch clean {
        case "codex", "code architect", "architect", "coder", "dev", "developer":
            return registeredAgents["developer"]
        case "nexus", "automator", "system automator", "exec", "executor":
            return registeredAgents["executor"]
        case "pilot", "ui", "controller":
            return registeredAgents["controller"]
        case "oracle", "research", "researcher":
            return registeredAgents["researcher"]
        case "auditor", "linter", "lint":
            return registeredAgents["linter"]
        case "aura", "uidesigner", "designer", "design", "ui designer":
            return registeredAgents["uiDesigner"] ?? registeredAgents["uidesigner"]
        case "chronos", "planner", "plan":
            return registeredAgents["planner"]
        case "apex", "supervisor", "apex prime", "prime", "chief of staff", "cos":
            return registeredAgents["supervisor"]
        default:
            // Fuzzy substring match for composite names (e.g. "Codex (Developer)", "Nexus (Executor)")
            if clean.contains("codex") || clean.contains("dev") { return registeredAgents["developer"] }
            if clean.contains("nexus") || clean.contains("exec") || clean.contains("auto") { return registeredAgents["executor"] }
            if clean.contains("pilot") || clean.contains("control") { return registeredAgents["controller"] }
            if clean.contains("oracle") || clean.contains("research") { return registeredAgents["researcher"] }
            if clean.contains("audit") || clean.contains("lint") { return registeredAgents["linter"] }
            if clean.contains("aura") || clean.contains("design") { return registeredAgents["uiDesigner"] ?? registeredAgents["uidesigner"] }
            if clean.contains("chronos") || clean.contains("plan") { return registeredAgents["planner"] }
            if clean.contains("apex") || clean.contains("prime") || clean.contains("supervisor") { return registeredAgents["supervisor"] }
            return nil
        }
    }
    
    public nonisolated func register(_ agent: RegisteredAgent) {
        let key = agent.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        registeredAgents[key] = agent
    }
    
    public nonisolated func unregister(name: String) {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        registeredAgents.removeValue(forKey: key)
    }
    
    public func loadAgentsFromDisk(directory: URL? = nil) {
        let fm = FileManager.default
        let agentsDir = directory ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".apex/agents")
        
        // Attempt to create the directory if it does not exist
        try? fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        
        guard let files = try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil) else {
            return
        }
        
        let jsonFiles = files.filter { $0.pathExtension.lowercased() == "json" }
        let decoder = JSONDecoder()
        
        for fileURL in jsonFiles {
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            if let agent = try? decoder.decode(RegisteredAgent.self, from: data) {
                let key = agent.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                registeredAgents[key] = agent
            }
        }
    }
}
