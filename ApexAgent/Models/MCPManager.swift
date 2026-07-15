import Foundation
import Observation
import SharedKit
import AI

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
    var modelRouter: ModelRouter { ModelRouter.shared }
    
    var servers: [MCPServerConfig] = []
    private var clients: [UUID: MCPClient] = [:]
    private var eventLogger: ToolEventLogger?
    
    private var _orchestrator: AgentOrchestrator?
    var orchestrator: AgentOrchestrator {
        get {
            if let o = _orchestrator {
                return o
            }
            let fallback = AgentOrchestrator()
            _orchestrator = fallback
            return fallback
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
        
        let defaultPath = "/Users/danielstevens/Developer/ApexAgent"
        let finalPath = FileManager.default.fileExists(atPath: defaultPath) ? defaultPath : FileManager.default.currentDirectoryPath
        
        if !loadedServers.contains(where: { $0.name == "Filesystem MCP" }) {
            loadedServers.append(MCPServerConfig(
                name: "Filesystem MCP",
                command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-filesystem", finalPath]
            ))
        }
        
        // Clean up legacy npx-based Git MCP config
        loadedServers.removeAll(where: { $0.name == "Git MCP" && $0.command == "npx" })
        
        if !loadedServers.contains(where: { $0.name == "Git MCP" }) {
            loadedServers.append(MCPServerConfig(
                name: "Git MCP",
                command: "/Users/danielstevens/.local/bin/python3.11",
                arguments: ["-m", "mcp_server_git", "--repository", finalPath]
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
