import Foundation
import FoundationModels
import Observation
import SharedKit

struct MCPServerConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var arguments: [String]
    var transport: String = "stdio"
    var endpointURL: String?
}

@Observable
@MainActor
final class MCPManager: OrchestratorProvider {
    static let shared = MCPManager()
    
    var dataBus: AppGroupDataBus { AppGroupDataBus.shared }
    
    var servers: [MCPServerConfig] = []
    private var clients: [UUID: MCPClient] = [:]
    private var eventLogger: ToolEventLogger?
    
    private var _orchestrator: AgentOrchestrator?
    private let persistsConfigs: Bool
    var orchestrator: AgentOrchestrator {
        get {
            if let o = _orchestrator { return o }
            let o = AppDelegate.sharedOrchestrator
            _orchestrator = o
            return o
        }
        set {
            _orchestrator = newValue
        }
    }
    
    init(persistsConfigs: Bool = true) {
        self.persistsConfigs = persistsConfigs
        if persistsConfigs {
            loadConfigs()
        }
    }
    
    func setEventLogger(_ logger: ToolEventLogger) {
        self.eventLogger = logger
    }
    
    func loadConfigs() {
        var loadedServers: [MCPServerConfig] = []
        if let data = UserDefaults.standard.data(forKey: "apex.mcpServers"),
           let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            loadedServers = decoded
        }
        
        // Derive the default workspace without hardcoding any developer path.
        // Priority: configured setting → user's home directory → cwd.
        let finalPath = Self.defaultWorkspacePath()

        if !loadedServers.contains(where: { $0.name == "Filesystem MCP" }) {
            loadedServers.append(MCPServerConfig(
                name: "Filesystem MCP",
                command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-filesystem", finalPath]
            ))
        }
        
        // Remove any previously-saved Git MCP configs (from older app versions
        // that auto-loaded it) so they cannot bypass the opt-in gate below.
        loadedServers.removeAll(where: { $0.name == "Git MCP" })
        
        // Git MCP requires the python module and a real repo path; only load
        // it when explicitly enabled so beta/CI runs don't spam stderr.
        if ProcessInfo.processInfo.environment["APEX_ENABLE_GIT_MCP"] == "1",
           !loadedServers.contains(where: { $0.name == "Git MCP" }) {
            loadedServers.append(MCPServerConfig(
                name: "Git MCP",
                command: "/usr/bin/env",
                arguments: ["python3", "-m", "mcp_server_git", "--repository", finalPath]
            ))
        }
        
        // Auto-seed Xcode 27 MCP servers if their binaries exist on disk.
        let xcodeBuildMCPPath = "/Users/danielstevens/.local/bin/xcodebuildmcp"
        let resolvedXcodeBuildMCPPath = FileManager.default.fileExists(atPath: xcodeBuildMCPPath)
            ? xcodeBuildMCPPath
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/xcodebuildmcp").path
        if FileManager.default.fileExists(atPath: resolvedXcodeBuildMCPPath),
           !loadedServers.contains(where: { $0.name == "xcodebuildmcp" }) {
            loadedServers.append(MCPServerConfig(
                name: "xcodebuildmcp",
                command: resolvedXcodeBuildMCPPath,
                arguments: ["mcp"]
            ))
        }
        
        if let mcpBridgeCommand = Self.resolveXcodeMCPBridgeCommand() {
            loadedServers.removeAll(where: { $0.name == "xcode-native" })
            loadedServers.append(MCPServerConfig(
                name: "xcode-native",
                command: mcpBridgeCommand.command,
                arguments: mcpBridgeCommand.arguments
            ))
        } else {
            loadedServers.removeAll(where: { $0.name == "xcode-native" })
        }
        
        self.servers = loadedServers
        saveConfigs()
    }

    private static func resolveXcodeMCPBridgeCommand() -> (command: String, arguments: [String])? {
        let directCandidates = [
            "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/mcpbridge",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge"
        ]
        for candidate in directCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return (candidate, [])
        }
        let xcrunPath = "/usr/bin/xcrun"
        guard FileManager.default.fileExists(atPath: xcrunPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrunPath)
        process.arguments = ["--find", "mcpbridge"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? (xcrunPath, ["mcpbridge"]) : nil
        } catch {
            return nil
        }
    }
    
    func saveConfigs() {
        guard persistsConfigs else { return }
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: "apex.mcpServers")
        }
    }

    /// The default workspace path used to seed MCP filesystem/git servers.
    /// Resolution order (no hardcoded developer paths):
    ///   1. User-configured `apex.workspacePath` in UserDefaults (if it exists).
    ///   2. `APEX_WORKSPACE` environment variable (if set).
    ///   3. The current user's home directory.
    ///   4. The process current working directory.
    static func defaultWorkspacePath() -> String {
        if let configured = UserDefaults.standard.string(forKey: "apex.workspacePath"),
           !configured.isEmpty {
            return configured
        }
        if let envPath = ProcessInfo.processInfo.environment["APEX_WORKSPACE"],
           !envPath.isEmpty {
            return envPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if FileManager.default.fileExists(atPath: home) {
            return home
        }
        return FileManager.default.currentDirectoryPath
    }

    func addServer(_ config: MCPServerConfig) {
        servers.append(config)
        saveConfigs()
    }
    
    func removeServer(id: UUID) {
        if let client = clients[id] {
            Task {
                await client.stop()
            }
        }
        clients.removeValue(forKey: id)
        servers.removeAll(where: { $0.id == id })
        saveConfigs()
    }
    
    func resetClientCircuit(id: UUID) async {
        if let client = clients[id] {
            await client.resetCircuit()
        }
    }

    /// Restart a previously-started MCP server by stopping and re-starting its client.
    func restartServer(id: UUID) async throws {
        guard let server = servers.first(where: { $0.id == id }) else {
            throw MCPError.connectionFailed("No MCP server found for id \(id)")
        }
        if let client = clients[id] {
            await client.stop()
            await client.resetCircuit()
            clients.removeValue(forKey: id)
        }
        // Re-create and start via getClient so it picks up any config changes.
        let newClient = getClient(for: server)
        try await newClient.start()
    }
    
    func getClient(for config: MCPServerConfig) -> MCPClient {
        if let client = clients[config.id] {
            return client
        }
        let logger = eventLogger ?? self.orchestrator
        let client = MCPClient(serverName: config.name, command: config.command, arguments: config.arguments, logger: logger, orchestrator: self, config: .default)
        clients[config.id] = client
        return client
    }
    
    func stopAll() async {
        for client in clients.values {
            await client.stop()
        }
        clients.removeAll()
    }

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
        return orchestrator.sessionForAgent(
            agent: agent,
            preference: preference,
            instructions: instructions,
            allowedTools: allowedTools,
            toolCallingMode: toolCallingMode,
            reasoningLevel: reasoningLevel,
            maxResponseTokens: maxResponseTokens,
            history: history
        )
    }

    // MARK: - Markdown MCP Registry Export

    func exportMCPServersTable() -> String {
        guard !servers.isEmpty else {
            return "No external MCP servers configured."
        }

        var md = "### 🔌 Configured MCP Servers (\(servers.count) servers)\n\n"
        md += "| Server Name | Transport | Command | Arguments | In-Memory Client |\n"
        md += "|---|---|---|---|---|\n"

        for s in servers {
            let active = clients[s.id] != nil ? "🟢 Connected" : "⚪️ Offline"
            let cmd = s.command.isEmpty ? "None" : s.command
            let args = s.arguments.joined(separator: " ").replacingOccurrences(of: "|", with: "\\|")
            let safeName = s.name.replacingOccurrences(of: "|", with: "\\|")
            md += "| **\(safeName)** | `\(s.transport)` | `\(cmd)` | `\(args)` | \(active) |\n"
        }
        return md
    }

}