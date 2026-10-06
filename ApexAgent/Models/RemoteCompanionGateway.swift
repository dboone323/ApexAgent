import Foundation
import Network

// MARK: - Companion Protocol Models

public struct CompanionDevice: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let pairedAt: Date
    public var lastSeenAt: Date
    public var isAuthorized: Bool

    public init(id: String, name: String, pairedAt: Date = Date(), lastSeenAt: Date = Date(), isAuthorized: Bool = true) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.isAuthorized = isAuthorized
    }
}

public struct CompanionPairingRequest: Codable, Sendable, Equatable {
    public let deviceId: String
    public let deviceName: String
    public let clientChallenge: String

    public init(deviceId: String, deviceName: String, clientChallenge: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.clientChallenge = clientChallenge
    }
}

public struct CompanionPairingAck: Codable, Sendable, Equatable {
    public let hostId: String
    public let hostName: String
    public let isAuthorized: Bool
    public let sessionToken: String

    public init(hostId: String, hostName: String, isAuthorized: Bool, sessionToken: String) {
        self.hostId = hostId
        self.hostName = hostName
        self.isAuthorized = isAuthorized
        self.sessionToken = sessionToken
    }
}

public struct CompanionApprovalRelayEvent: Codable, Sendable, Equatable {
    public let requestId: String
    public let stageId: String
    public let stageName: String
    public let summary: String
    public let riskLevel: String
    public let timestamp: Date

    public init(
        requestId: String = UUID().uuidString,
        stageId: String,
        stageName: String,
        summary: String,
        riskLevel: String = "medium",
        timestamp: Date = Date()
    ) {
        self.requestId = requestId
        self.stageId = stageId
        self.stageName = stageName
        self.summary = summary
        self.riskLevel = riskLevel
        self.timestamp = timestamp
    }
}

public struct CompanionLiveActivityState: Codable, Sendable, Equatable {
    public let playbookTitle: String
    public let currentStageTitle: String
    public let activeBotName: String
    public let progressFraction: Double // 0.0 to 1.0
    public let pendingApprovalCount: Int
    public let isRunning: Bool
    public let timestamp: Date

    public init(
        playbookTitle: String,
        currentStageTitle: String,
        activeBotName: String,
        progressFraction: Double,
        pendingApprovalCount: Int = 0,
        isRunning: Bool = true,
        timestamp: Date = Date()
    ) {
        self.playbookTitle = playbookTitle
        self.currentStageTitle = currentStageTitle
        self.activeBotName = activeBotName
        self.progressFraction = progressFraction
        self.pendingApprovalCount = pendingApprovalCount
        self.isRunning = isRunning
        self.timestamp = timestamp
    }
}

// MARK: - Typed Message Frames & Sensor Payloads

public enum CompanionMessageType: String, Codable, Sendable {
    case hello = "client_hello"
    case ack = "server_ack"
    case chatSend = "chat_send"
    case chatStream = "chat_stream"
    case approvalPush = "approval_push"
    case approvalDecision = "approval_decision"
    case liveActivitySync = "live_activity_sync"
    case sensorUpload = "sensor_upload"
}

public struct CompanionSensorPayload: Codable, Sendable, Equatable {
    public enum SensorKind: String, Codable, Sendable {
        case cameraPhoto = "camera_photo"
        case voiceAudioChunk = "voice_audio"
        case location = "location"
    }

    public let kind: SensorKind
    public let dataBase64: String
    public let metadata: [String: String]
    public let timestamp: Date

    public init(kind: SensorKind, dataBase64: String, metadata: [String: String] = [:], timestamp: Date = Date()) {
        self.kind = kind
        self.dataBase64 = dataBase64
        self.metadata = metadata
        self.timestamp = timestamp
    }
}

public struct CompanionMessageFrame: Codable, Sendable, Equatable {
    public let id: UUID
    public let type: CompanionMessageType
    public let senderId: String
    public let sessionToken: String?
    public let payloadJSON: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        type: CompanionMessageType,
        senderId: String,
        sessionToken: String? = nil,
        payloadJSON: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.senderId = senderId
        self.sessionToken = sessionToken
        self.payloadJSON = payloadJSON
        self.timestamp = timestamp
    }
}

// MARK: - RemoteCompanionGateway (macOS Host Daemon)

@MainActor
public final class RemoteCompanionGateway: ObservableObject {
    public static let shared = RemoteCompanionGateway()

    public static let bonjourServiceType = "_apexagent._tcp"
    public static let defaultPort: UInt16 = 1338

    @Published public private(set) var isAdvertising: Bool = false
    @Published public private(set) var pairedDevices: [String: CompanionDevice] = [:]
    @Published public private(set) var activeSessionTokens: [String: String] = [:] // sessionToken -> deviceId
    @Published public private(set) var pendingApprovalRelays: [String: CompanionApprovalRelayEvent] = [:]
    @Published public private(set) var currentLiveActivity: CompanionLiveActivityState?
    @Published public private(set) var receivedSensorUploads: [CompanionSensorPayload] = []

    private var hostId: String = UUID().uuidString
    private var sharedSecret: String = "ApexCompanionSecretKey"

    public init() {}

    public func configure(sharedSecret: String) {
        self.sharedSecret = sharedSecret
    }

    // MARK: - Bonjour Service Descriptor

    public func makeBonjourServiceDescriptor() -> (type: String, domain: String, txtRecord: [String: String]) {
        let txt: [String: String] = [
            "name": "ApexAgent Host",
            "version": "1.0",
            "capabilities": "approvals,state_sync,voice_relay,live_activities,sensor_node",
            "hostId": hostId
        ]
        return (type: Self.bonjourServiceType, domain: "local.", txtRecord: txt)
    }

    public func startAdvertising() {
        guard !isAdvertising else { return }
        isAdvertising = true
    }

    public func stopAdvertising() {
        isAdvertising = false
    }

    // MARK: - Pairing Handshake

    public func processPairingRequest(_ request: CompanionPairingRequest, sharedSecretProvided: String) -> CompanionPairingAck {
        let isAuthorized = (sharedSecretProvided == self.sharedSecret)
        let token = isAuthorized ? UUID().uuidString : ""

        if isAuthorized {
            let device = CompanionDevice(id: request.deviceId, name: request.deviceName, isAuthorized: true)
            pairedDevices[request.deviceId] = device
            activeSessionTokens[token] = request.deviceId
        }

        return CompanionPairingAck(
            hostId: hostId,
            hostName: Host.current().localizedName ?? "ApexAgent Host Mac",
            isAuthorized: isAuthorized,
            sessionToken: token
        )
    }

    public func validateSessionToken(_ token: String?, forDeviceId deviceId: String) -> Bool {
        guard let token, !token.isEmpty else { return false }
        guard let tokenOwner = activeSessionTokens[token], tokenOwner == deviceId else { return false }
        guard let device = pairedDevices[deviceId], device.isAuthorized else { return false }
        return true
    }

    // MARK: - Approval Card Relay

    public func postApprovalRelay(_ event: CompanionApprovalRelayEvent) {
        pendingApprovalRelays[event.requestId] = event
    }

    public func resolveApprovalRelay(
        requestId: String,
        allow: Bool,
        sessionToken: String? = nil,
        senderId: String? = nil
    ) -> CompanionApprovalRelayEvent? {
        if let senderId {
            guard validateSessionToken(sessionToken, forDeviceId: senderId) else { return nil }
        }
        guard let event = pendingApprovalRelays.removeValue(forKey: requestId) else { return nil }
        if allow {
            _ = EphemeralCapabilityManager.shared.issueToken(for: event.stageName, botName: nil, ttlSeconds: 120.0)
        }
        return event
    }

    // MARK: - Live Activity Dispatch

    public func updateLiveActivity(_ state: CompanionLiveActivityState?) {
        self.currentLiveActivity = state
    }

    // MARK: - Inbound Message Frame Processing

    public func handleInboundFrame(_ frame: CompanionMessageFrame) -> CompanionMessageFrame? {
        switch frame.type {
        case .hello:
            if let req = try? JSONDecoder().decode(CompanionPairingRequest.self, from: Data(frame.payloadJSON.utf8)) {
                let ack = processPairingRequest(req, sharedSecretProvided: self.sharedSecret)
                let ackJSON = (try? String(data: JSONEncoder().encode(ack), encoding: .utf8)) ?? "{}"
                return CompanionMessageFrame(
                    type: .ack,
                    senderId: hostId,
                    sessionToken: ack.sessionToken,
                    payloadJSON: ackJSON
                )
            }
        case .sensorUpload:
            guard validateSessionToken(frame.sessionToken, forDeviceId: frame.senderId) else {
                return nil
            }
            if let sensor = try? JSONDecoder().decode(CompanionSensorPayload.self, from: Data(frame.payloadJSON.utf8)) {
                receivedSensorUploads.append(sensor)
                return CompanionMessageFrame(
                    type: .ack,
                    senderId: hostId,
                    sessionToken: frame.sessionToken,
                    payloadJSON: "{\"status\": \"ingested\", \"kind\": \"\(sensor.kind.rawValue)\"}"
                )
            }
        case .approvalDecision:
            guard validateSessionToken(frame.sessionToken, forDeviceId: frame.senderId) else {
                return nil
            }
            if let data = frame.payloadJSON.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let reqId = json["requestId"] as? String,
               let allow = json["allow"] as? Bool {
                _ = resolveApprovalRelay(requestId: reqId, allow: allow, sessionToken: frame.sessionToken, senderId: frame.senderId)
                return CompanionMessageFrame(
                    type: .ack,
                    senderId: hostId,
                    sessionToken: frame.sessionToken,
                    payloadJSON: "{\"status\": \"resolved\", \"requestId\": \"\(reqId)\"}"
                )
            }
        default:
            break
        }
        return nil
    }
}

// MARK: - ApexCompanionMobileClient (iOS Companion Client)

@MainActor
public final class ApexCompanionMobileClient: ObservableObject {
    public let deviceId: String
    public let deviceName: String
    public let hardwareModel: String

    @Published public private(set) var isPaired: Bool = false
    @Published public private(set) var activeSessionToken: String?
    @Published public private(set) var connectedHostId: String?
    @Published public private(set) var connectedHostName: String?
    @Published public private(set) var liveActivityState: CompanionLiveActivityState?
    @Published public private(set) var chatMessages: [String] = []

    public init(
        deviceId: String = "iphone_dan_15_pro_max",
        deviceName: String = "Dan's iPhone 15 Pro Max",
        hardwareModel: String = "iPhone16,2"
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.hardwareModel = hardwareModel
    }

    /// Initiates pairing handshake with the target macOS Host gateway.
    public func pair(with gateway: RemoteCompanionGateway, sharedSecret: String) -> Bool {
        let req = CompanionPairingRequest(
            deviceId: deviceId,
            deviceName: deviceName,
            clientChallenge: UUID().uuidString
        )

        let ack = gateway.processPairingRequest(req, sharedSecretProvided: sharedSecret)
        if ack.isAuthorized {
            self.isPaired = true
            self.activeSessionToken = ack.sessionToken
            self.connectedHostId = ack.hostId
            self.connectedHostName = ack.hostName
            return true
        } else {
            self.isPaired = false
            self.activeSessionToken = nil
            return false
        }
    }

    /// Uploads an iPhone hardware sensor payload (camera photo, voice audio, or location) to the gateway.
    @discardableResult
    public func uploadSensorPayload(
        to gateway: RemoteCompanionGateway,
        kind: CompanionSensorPayload.SensorKind,
        dataBase64: String,
        metadata: [String: String] = [:]
    ) -> Bool {
        guard isPaired else { return false }
        let payload = CompanionSensorPayload(kind: kind, dataBase64: dataBase64, metadata: metadata)
        if let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) {
            let frame = CompanionMessageFrame(
                type: .sensorUpload,
                senderId: deviceId,
                sessionToken: activeSessionToken,
                payloadJSON: json
            )
            let reply = gateway.handleInboundFrame(frame)
            return reply != nil
        }
        return false
    }

    /// Fetches pending approval cards from the host.
    public func fetchPendingApprovals(from gateway: RemoteCompanionGateway) -> [CompanionApprovalRelayEvent] {
        guard isPaired else { return [] }
        return Array(gateway.pendingApprovalRelays.values)
    }

    /// Submits approval or rejection decision to the host gateway.
    public func submitDecision(
        on gateway: RemoteCompanionGateway,
        requestId: String,
        allow: Bool,
        notes: String? = nil
    ) -> Bool {
        guard isPaired else { return false }
        let resolved = gateway.resolveApprovalRelay(requestId: requestId, allow: allow)
        return resolved != nil
    }

    /// Syncs Live Activity state for Dynamic Island display.
    public func syncLiveActivity(from gateway: RemoteCompanionGateway) {
        guard isPaired else { return }
        self.liveActivityState = gateway.currentLiveActivity
    }

    public func unpair() {
        self.isPaired = false
        self.activeSessionToken = nil
        self.connectedHostId = nil
        self.connectedHostName = nil
        self.liveActivityState = nil
        self.chatMessages.removeAll()
    }


}

extension RemoteCompanionGateway {
    // MARK: - Markdown Diagnostics

    public func formatGatewayDiagnosticsMarkdown() -> String {
        var md = "### 📱 Remote Companion Gateway Telemetry\n\n"
        md += "| Metric / Parameter | Value | Description |\n"
        md += "|---|---|---|\n"
        md += "| Host ID | `\(hostId)` | Host node identifier |\n"
        md += "| Bonjour Advertising | \(isAdvertising ? "🟢 Active" : "⚪️ Inactive") | mDNS service broadcasting |\n"
        md += "| Paired Devices | `\(pairedDevices.count)` | Authenticated companion remotes |\n"
        md += "| Active Tokens | `\(activeSessionTokens.count)` | Live session bearer tokens |\n"
        md += "| Pending Relays | `\(pendingApprovalRelays.count)` | Unresolved remote approval cards |\n"
        md += "| Sensor Uploads Ingested | `\(receivedSensorUploads.count)` | Photos and sensor telemetries received |\n"
        return md
    }
}
