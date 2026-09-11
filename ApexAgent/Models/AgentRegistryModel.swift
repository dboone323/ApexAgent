import Foundation

// MARK: - Agent Registry Model (Discord coordination agents)
//
// Persisted to UserDefaults key "apex.agentRegistry" as JSON.
// Stores the list of known Discord bot agents, their bot IDs, transport
// type, and the coordination channel ID.  Accessible from any thread.
//
// This is a separate model from the existing AgentRegistry.swift
// (which stores internal AFM session profiles like developer/executor).
// AgentRegistryModel is for Discord bot identity / coordination only.

enum AgentTransport: String, Codable, Sendable {
    case ws   // WebSocket / Discord Gateway (real-time push)
    case poll // REST polling via DiscordMessagePoller
}

// MARK: - Agent Entry

struct AgentEntry: Codable, Identifiable, Sendable, Equatable {
    var id: String { botId }
    let name: String
    let botId: String
    let botTokenRef: String       // key ref into .env / keychain (not the token itself)
    let transport: AgentTransport
    let channels: [String]
    let capabilities: [String]

    init(name: String, botId: String, botTokenRef: String,
         transport: AgentTransport, channels: [String] = [],
         capabilities: [String] = []) {
        self.name = name
        self.botId = botId
        self.botTokenRef = botTokenRef
        self.transport = transport
        self.channels = channels
        self.capabilities = capabilities
    }
}

// MARK: - Agent Registry Model

final class AgentRegistryModel: @unchecked Sendable {

    static let userDefaultsKey = "apex.agentRegistry"

    private let lock = NSLock()

    var agents: [AgentEntry] = []
    var coordinationChannelId: String = "1537911274804088832"
    var updatedAt: Date = Date()

    static let shared = AgentRegistryModel()

    private init() {
        load()
    }

    // MARK: - Load / Save

    func load() {
        lock.lock()
        defer { lock.unlock() }
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(AgentRegistryModel.self, from: data) {
            self.agents = decoded.agents
            self.coordinationChannelId = decoded.coordinationChannelId
            self.updatedAt = decoded.updatedAt
        } else {
            // Seed defaults
            self.agents = [
                AgentEntry(name: "Clawd", botId: "1445949064465223690",
                           botTokenRef: "clawd", transport: .ws,
                           channels: ["1537911274804088832", "1504543218988220617"],
                           capabilities: ["post", "read", "ws"]),
                AgentEntry(name: "Kodi", botId: "1484763946195095642",
                           botTokenRef: "kodi", transport: .ws,
                           channels: ["1537911274804088832"],
                           capabilities: ["post", "read", "ws"]),
                AgentEntry(name: "ApexAgent", botId: "1537957778998431775",
                           botTokenRef: "apex", transport: .poll,
                           channels: ["1537911274804088832"],
                           capabilities: ["post", "read", "poll"]),
            ]
            self.coordinationChannelId = "1537911274804088832"
            self.updatedAt = Date()
            save()
        }
    }

    func save() {
        lock.lock()
        defer { lock.unlock() }
        updatedAt = Date()
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    // MARK: - Mutations

    func addAgent(_ agent: AgentEntry) {
        lock.lock()
        defer { lock.unlock() }
        if let index = agents.firstIndex(where: { $0.botId == agent.botId }) {
            agents[index] = agent
        } else {
            agents.append(agent)
        }
        save()
    }

    func removeAgent(botId: String) {
        lock.lock()
        defer { lock.unlock() }
        agents.removeAll { $0.botId == botId }
        save()
    }

    // MARK: - Lookups

    func agent(byBotId botId: String) -> AgentEntry? {
        lock.lock()
        defer { lock.unlock() }
        return agents.first { $0.botId == botId }
    }

    func agent(byName name: String) -> AgentEntry? {
        lock.lock()
        defer { lock.unlock() }
        return agents.first { $0.name.lowercased() == name.lowercased() }
    }

    func agent(byTokenRef ref: String) -> AgentEntry? {
        lock.lock()
        defer { lock.unlock() }
        return agents.first { $0.botTokenRef == ref }
    }

    // MARK: - Convenience

    var allBotIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return agents.map { $0.botId }
    }

    var allNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return agents.map { $0.name }
    }
}

// MARK: - Codable (for JSON persistence)

extension AgentRegistryModel: Codable {
    enum CodingKeys: String, CodingKey {
        case agents
        case coordinationChannelId
        case updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agents, forKey: .agents)
        try container.encode(coordinationChannelId, forKey: .coordinationChannelId)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    convenience init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decode([AgentEntry].self, forKey: .agents)
        coordinationChannelId = try container.decode(String.self, forKey: .coordinationChannelId)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
