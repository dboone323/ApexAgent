import Foundation

// MARK: - Discord Gateway v10 Protocol Models

public enum DiscordOpCode: Int, Codable, Sendable {
    case dispatch = 0
    case heartbeat = 1
    case identify = 2
    case presenceUpdate = 3
    case voiceStateUpdate = 4
    case resume = 6
    case reconnect = 7
    case requestGuildMembers = 8
    case invalidSession = 9
    case hello = 10
    case heartbeatAck = 11
}

public struct DiscordGatewayPayload<T: Codable & Sendable>: Codable, Sendable {
    public let op: Int
    public let d: T?
    public let s: Int?
    public let t: String?

    public init(op: DiscordOpCode, d: T?, s: Int? = nil, t: String? = nil) {
        self.op = op.rawValue
        self.d = d
        self.s = s
        self.t = t
    }
}

public struct DiscordHelloData: Codable, Sendable {
    public let heartbeatInterval: Int

    enum CodingKeys: String, CodingKey {
        case heartbeatInterval = "heartbeat_interval"
    }

    public init(heartbeatInterval: Int) {
        self.heartbeatInterval = heartbeatInterval
    }
}

public struct DiscordIdentifyData: Codable, Sendable {
    public let token: String
    public let intents: Int
    public let properties: Properties

    public struct Properties: Codable, Sendable {
        public let os: String
        public let browser: String
        public let device: String

        public init(os: String = "macOS", browser: String = "ApexAgent", device: String = "Mac") {
            self.os = os
            self.browser = browser
            self.device = device
        }
    }

    public init(token: String, intents: Int = 33280, properties: Properties = Properties()) {
        self.token = token
        self.intents = intents
        self.properties = properties
    }
}

public struct DiscordButtonComponent: Codable, Sendable, Equatable {
    public let type: Int // 2 for button
    public let style: Int // 1 primary, 2 secondary, 3 success, 4 danger
    public let label: String
    public let customId: String

    enum CodingKeys: String, CodingKey {
        case type, style, label
        case customId = "custom_id"
    }

    public init(label: String, customId: String, style: Int = 1) {
        self.type = 2
        self.style = style
        self.label = label
        self.customId = customId
    }

    public static func makeApprovalRow(stageId: String) -> [DiscordButtonComponent] {
        [
            DiscordButtonComponent(label: "Approve", customId: "approve_stage_\(stageId)", style: 3),
            DiscordButtonComponent(label: "Reject", customId: "reject_stage_\(stageId)", style: 4),
            DiscordButtonComponent(label: "Details", customId: "details_stage_\(stageId)", style: 2)
        ]
    }
}

public struct DiscordGatewayMessage: Codable, Sendable, Equatable {
    public let id: String
    public let channelId: String
    public let content: String
    public let authorName: String
    public let isBot: Bool

    public init(id: String, channelId: String, content: String, authorName: String, isBot: Bool = false) {
        self.id = id
        self.channelId = channelId
        self.content = content
        self.authorName = authorName
        self.isBot = isBot
    }
}

// MARK: - DiscordGatewayClient

@MainActor
public final class DiscordGatewayClient: ObservableObject {
    public static let shared = DiscordGatewayClient()

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var lastSequence: Int?
    @Published public private(set) var lastHeartbeatAckReceived: Date?
    @Published public private(set) var receivedMessages: [DiscordGatewayMessage] = []

    private var heartbeatTask: Task<Void, Never>?
    private var token: String?

    public init() {}

    public func configure(botToken: String) {
        self.token = botToken
    }

    public func connect(gatewayUrl: String = "wss://gateway.discord.gg/?v=10&encoding=json") {
        guard !isConnected else { return }
        isConnected = true
    }

    public func disconnect() {
        isConnected = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Handles an incoming Gateway payload packet.
    public func handleIncomingPayload(op: DiscordOpCode, data: Data) -> String? {
        switch op {
        case .hello:
            if let hello = try? JSONDecoder().decode(DiscordHelloData.self, from: data) {
                startHeartbeat(intervalMs: hello.heartbeatInterval)
                return "Configured heartbeat interval: \(hello.heartbeatInterval)ms"
            }
            return nil

        case .heartbeatAck:
            self.lastHeartbeatAckReceived = Date()
            return "Heartbeat ACK recorded"

        case .dispatch:
            if let msg = try? JSONDecoder().decode(DiscordGatewayMessage.self, from: data) {
                receivedMessages.append(msg)
                return "Dispatched message: \(msg.content)"
            }
            return nil

        default:
            return nil
        }
    }

    /// Creates an Identify payload ready for Gateway transmission.
    public func createIdentifyPayload() throws -> Data {
        guard let tok = token, !tok.isEmpty else {
            throw NSError(domain: "DiscordGateway", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing bot token"])
        }
        let payload = DiscordGatewayPayload(op: .identify, d: DiscordIdentifyData(token: tok))
        return try JSONEncoder().encode(payload)
    }

    /// Creates a Heartbeat payload.
    public func createHeartbeatPayload(sequence: Int?) throws -> Data {
        let payload = DiscordGatewayPayload<Int>(op: .heartbeat, d: sequence)
        return try JSONEncoder().encode(payload)
    }

    private func startHeartbeat(intervalMs: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            let intervalNanoseconds = UInt64(intervalMs) * 1_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard let self = self, self.isConnected else { break }
                self.lastSequence = (self.lastSequence ?? 0) + 1
            }
        }
    }

    // MARK: - Markdown Telemetry

    public func formatGatewayStatusMarkdown() -> String {
        var md = "### 💬 Discord Gateway v10 Telemetry\n\n"
        md += "| Metric / Parameter | Value | Description |\n"
        md += "|---|---|---|\n"
        md += "| Connection Status | \(isConnected ? "🟢 Connected" : "⚪️ Disconnected") | WebSocket connection state |\n"
        let tokenStatus = token != nil ? "🟢 Present (Redacted)" : "⚪️ Missing"
        md += "| Bot Token | \(tokenStatus) | Discord developer bot credential |\n"
        let ackStatus = lastHeartbeatAckReceived != nil ? "🟢 Alive" : "⚪️ Pending"
        md += "| Heartbeat ACK | \(ackStatus) | Keep-alive heartbeat acknowledgement |\n"
        md += "| Dispatched Messages | `\(receivedMessages.count)` | Inbound events received |\n"
        return md
    }

}