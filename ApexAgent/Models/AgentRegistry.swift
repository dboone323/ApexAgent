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
            Be precise, check for compiling/correctness, and return detailed progress/results to Apex Prime.
            """,
            allowedTools: ["read_file", "write_file", "list_directory", "create_directory", "delete_file", "move_file", "audit_projects", "create_skill", "run_shell_command", "analyze_image"]
        ),
        "executor": RegisteredAgent(
            name: "executor",
            systemPrompt: """
            You are Nexus, the Executor Agent. Your role is to run shell commands, execute scripts, and automate applications to build, run, or test software. \
            Use tools like `run_shell_command`, `run_applescript`, `control_app`, and `control_accessibility` to run tasks on this Mac. \
            Confirm results and return stdout/stderr/exit codes to Apex Prime.
            """,
            allowedTools: ["run_shell_command", "run_applescript", "control_app", "control_accessibility"]
        ),
        "controller": RegisteredAgent(
            name: "controller",
            systemPrompt: """
            You are Pilot, the Controller Agent. Your role is to interact with the active user interface, control external apps, browse the web, manage clipboard, and capture system state. \
            Use tools like `control_browser`, `take_screenshot`, `read_clipboard`, `write_clipboard`, `get_frontmost_app`, `get_running_processes`, and `send_notification`. \
            Return findings to Apex Prime.
            """,
            allowedTools: ["get_frontmost_app", "get_running_processes", "read_clipboard", "write_clipboard", "send_notification", "system_info", "control_accessibility", "control_app", "control_browser"]
        ),
        "researcher": RegisteredAgent(
            name: "researcher",
            systemPrompt: """
            You are Oracle, the Researcher Agent. Your role is to search the web, gather documentation, synthesize information, and read files. \
            Use tools like `web_search`, `read_file`, `list_directory`, `screenshot_tool`, `read_clipboard`, and `write_clipboard` to answer questions. \
            Provide clear citations, source summaries, and a final synthesized report to Apex Prime.
            """,
            allowedTools: ["web_search", "read_clipboard", "write_clipboard", "read_file", "list_directory", "take_screenshot"]
        ),
        "linter": RegisteredAgent(
            name: "linter",
            systemPrompt: """
            You are Auditor, the Linter Agent. Your role is to analyze code files for syntax issues, format style consistency, compile warnings, and general cleanup. \
            Use tools like `read_file`, `write_file`, `list_directory`, `run_shell_command`, and `audit_projects` to run formatting and style scripts (such as SwiftLint) and ensure the codebase compiles cleanly. Return findings to Apex Prime.
            """,
            allowedTools: ["read_file", "write_file", "list_directory", "run_shell_command", "audit_projects"]
        ),
        "uiDesigner": RegisteredAgent(
            name: "uiDesigner",
            systemPrompt: """
            You are Aura, the UI Designer Agent. Your role is to inspect and optimize SwiftUI visual layout, hierarchy, responsive alignment, padding, and design tokens (like HSL colors). \
            Use tools like `read_file`, `write_file`, `take_screenshot`, `run_shell_command`, and `run_applescript` to review code and inspect user interfaces for aesthetic excellence. Return findings to Apex Prime.
            """,
            allowedTools: ["read_file", "write_file", "take_screenshot", "run_shell_command", "run_applescript", "control_app"]
        ),
        "planner": RegisteredAgent(
            name: "planner",
            systemPrompt: """
            You are Chronos, the Planner Agent. Your role is to decompose complex development goals into step-by-step roadmaps, assign task priorities, track milestones, and manage task lists. \
            Use tools like `read_file`, `write_file`, `list_directory`, `update_plan`, `store_memory`, and `search_memory` to structure execution plans. Return findings to Apex Prime.
            """,
            allowedTools: ["read_file", "write_file", "list_directory", "update_plan", "store_memory", "search_memory"]
        )
    ]
    
    private init() {
        var agents: [String: RegisteredAgent] = [:]
        for (key, agent) in AgentRegistry.builtInDefaults {
            agents[key] = agent
        }
        self.registeredAgents = agents
    }
    
    public nonisolated func allAgents() -> [RegisteredAgent] {
        return Array(registeredAgents.values).sorted(by: { $0.name < $1.name })
    }
    
    public nonisolated func resolve(name: String) -> RegisteredAgent? {
        return registeredAgents[name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)]
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
