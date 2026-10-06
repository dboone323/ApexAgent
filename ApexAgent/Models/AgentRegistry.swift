import Foundation
import Synchronization

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

/// Lock-guarded agent dictionary (H5). The registry is an actor, but several
/// call sites need synchronous access, so the mutable state lives in this
/// Sendable box synchronized with a Mutex instead of `nonisolated(unsafe)`.
private final class AgentStore: @unchecked Sendable {
    private let agents = Mutex<[String: RegisteredAgent]>([:])

    init(_ initial: [String: RegisteredAgent] = [:]) {
        agents.withLock { $0 = initial }
    }

    func snapshot() -> [String: RegisteredAgent] {
        agents.withLock { $0 }
    }

    func set(_ agent: RegisteredAgent, forKey key: String) {
        agents.withLock { $0[key] = agent }
    }

    func remove(key: String) {
        agents.withLock { _ = $0.removeValue(forKey: key) }
    }
}

public actor AgentRegistry {
    public static let shared = AgentRegistry()

    private let store: AgentStore
    
    public static let builtInDefaults: [String: RegisteredAgent] = [
        "developer": RegisteredAgent(
            name: "developer",
            systemPrompt: AgentType.developer.systemPrompt,
            allowedTools: ["read_file", "write_file", "patch_file", "git_operation", "list_directory", "create_directory", "delete_file", "move_file", "audit_projects", "create_skill"]
        ),
        "executor": RegisteredAgent(
            name: "executor",
            systemPrompt: AgentType.executor.systemPrompt,
            allowedTools: ["run_shell_command", "run_applescript", "control_app", "control_accessibility", "computer_use", "calendar", "reminders", "run_shortcut", "query_logs", "watch_paths", "network_diagnostics", "simctl", "mail_automation", "deep_link"]
        ),
        "controller": RegisteredAgent(
            name: "controller",
            systemPrompt: AgentType.controller.systemPrompt,
            allowedTools: ["get_frontmost_app", "get_running_processes", "read_clipboard", "write_clipboard", "send_notification", "get_system_info", "system_info", "control_accessibility", "control_app", "control_browser", "get_weather", "map_search", "get_directions", "computer_use", "run_shortcut", "network_diagnostics", "simctl", "mail_automation", "deep_link"]
        ),
        "researcher": RegisteredAgent(
            name: "researcher",
            systemPrompt: AgentType.researcher.systemPrompt,
            allowedTools: ["web_search", "get_weather", "map_search", "get_directions", "translate", "extract_entities", "analyze_image", "read_clipboard", "write_clipboard", "read_file", "list_directory", "take_screenshot", "query_logs"]
        ),
        "linter": RegisteredAgent(
            name: "linter",
            systemPrompt: AgentType.linter.systemPrompt,
            allowedTools: ["read_file", "write_file", "list_directory", "run_shell_command", "audit_projects"]
        ),
        "uiDesigner": RegisteredAgent(
            name: "uiDesigner",
            systemPrompt: AgentType.uiDesigner.systemPrompt,
            allowedTools: ["read_file", "write_file", "take_screenshot", "run_shell_command", "run_applescript", "control_app"]
        ),
        "planner": RegisteredAgent(
            name: "planner",
            systemPrompt: AgentType.planner.systemPrompt,
            allowedTools: ["read_file", "write_file", "list_directory", "update_plan", "store_memory", "search_memory", "calendar", "reminders", "extract_entities", "deep_link"]
        ),
        "supervisor": RegisteredAgent(
            name: "supervisor",
            systemPrompt: SupervisorPrompt.system,
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
        self.store = AgentStore(agents)
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
        return Array(store.snapshot().values).sorted(by: { $0.name < $1.name })
    }
    
    public nonisolated func resolve(name: String) -> RegisteredAgent? {
        let registeredAgents = store.snapshot()
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
        case "auditor", "linter", "lint", "critic", "reviewer", "security":
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
            if clean.contains("audit") || clean.contains("lint") || clean.contains("critic") || clean.contains("review") { return registeredAgents["linter"] }
            if clean.contains("aura") || clean.contains("design") { return registeredAgents["uiDesigner"] ?? registeredAgents["uidesigner"] }
            if clean.contains("chronos") || clean.contains("plan") { return registeredAgents["planner"] }
            if clean.contains("apex") || clean.contains("prime") || clean.contains("supervisor") { return registeredAgents["supervisor"] }
            return nil
        }
    }
    
    public nonisolated func register(_ agent: RegisteredAgent) {
        let key = agent.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        store.set(agent, forKey: key)
        NotificationCenter.default.post(name: .agentRegistryUpdated, object: nil)
    }
    
    public nonisolated func unregister(name: String) {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        store.remove(key: key)
        NotificationCenter.default.post(name: .agentRegistryUpdated, object: nil)
    }
    
    public func loadAgentsFromDisk(directory: URL? = nil) {
        let fm = FileManager.default
        let agentsDir = directory ?? ApexAgentStoragePaths.directory("agents")
        
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
                store.set(agent, forKey: key)
            }
        }
        NotificationCenter.default.post(name: .agentRegistryUpdated, object: nil)
    }
}

extension Notification.Name {
    public static let agentRegistryUpdated = Notification.Name("ApexAgent.agentRegistryUpdated")
}

extension RegisteredAgent {
    public func formatAsMarkdown() -> String {
        var md = "### 🤖 Registered Agent: `\(name)`\n\n"
        let promptPreview = String(systemPrompt.prefix(160)).replacingOccurrences(of: "|", with: "\\|")
        md += "| Property | Value |\n"
        md += "|---|---|\n"
        md += "| Name | `\(name)` |\n"
        md += "| Model Preference | `\(modelPreference ?? "default")` |\n"
        md += "| Allowed Tools | `\(allowedTools.count)` (\(allowedTools.prefix(8).joined(separator: ", "))\(allowedTools.count > 8 ? "…" : "")) |\n"
        md += "| System Prompt | \(promptPreview) |\n"
        return md
    }
}
