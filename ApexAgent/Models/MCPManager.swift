import Foundation
import Observation

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
    
    var servers: [MCPServerConfig] = []
    private var clients: [UUID: MCPClient] = [:]
    private var eventLogger: ToolEventLogger?
    
    var orchestrator: AgentOrchestrator { AppDelegate.getSharedOrchestrator()! }
    
    private init() {
        loadConfigs()
    }
    
    func setEventLogger(_ logger: ToolEventLogger) {
        self.eventLogger = logger
    }
    
    func loadConfigs() {
        if let data = UserDefaults.standard.data(forKey: "apex.mcpServers"),
           let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            self.servers = decoded
        } else {
            // Seed a default mock/filesystem server config if empty
            self.servers = [
                MCPServerConfig(
                    name: "Filesystem MCP",
                    command: "npx",
                    arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/danielstevens/Developer/ApexAgent"]
                )
            ]
            saveConfigs()
        }
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
        let logger = eventLogger ?? AppDelegate.getSharedOrchestrator() ?? ToolEventLoggerImpl()
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
