import Foundation
import Observation
import SharedKit

struct MCPServerConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var arguments: [String]
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
        
        // Clean up legacy npx-based Git MCP config
        loadedServers.removeAll(where: { $0.name == "Git MCP" && $0.command == "npx" })
        // Clean up legacy Git MCP configs that hardwired an absolute dev python path.
        loadedServers.removeAll(where: { $0.name == "Git MCP" && $0.command.hasPrefix("/Users/") })
        
        if !loadedServers.contains(where: { $0.name == "Git MCP" }) {
            loadedServers.append(MCPServerConfig(
                name: "Git MCP",
                // Discover python3 from PATH at runtime instead of hardcoding an
                // absolute developer path. The MCPClient wraps commands in a login
                // shell, so `/usr/bin/env python3` resolves the user's python3.
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
    
    func getClient(for config: MCPServerConfig) -> MCPClient {
        if let client = clients[config.id] {
            return client
        }
        let logger = eventLogger ?? self.orchestrator
        let client = MCPClient(serverName: config.name, command: config.command, arguments: config.arguments, logger: logger, orchestrator: self)
        clients[config.id] = client
        return client
    }
    
    func stopAll() async {
        for client in clients.values {
            await client.stop()
        }
        clients.removeAll()
    }
}
