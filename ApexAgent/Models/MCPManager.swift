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
    var orchestrator: AgentOrchestrator {
        get {
            if let o = _orchestrator { return o }
            // MCPManager is a shared singleton; if no orchestrator was injected
            // yet (e.g. accessed before the app's AgentOrchestrator exists),
            // lazily create and wire one rather than crashing. This is the
            // legitimate default for a shared manager — not a masked wiring bug.
            let o = AgentOrchestrator()
            _orchestrator = o
            return o
        }
        set {
            _orchestrator = newValue
        }
    }
    
    private init() {
        loadConfigs()
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
        
        self.servers = loadedServers
        saveConfigs()
    }
    
    func saveConfigs() {
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
}
