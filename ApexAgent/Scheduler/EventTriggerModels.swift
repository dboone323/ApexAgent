import Foundation

public enum EventTriggerKind: String, Codable, Sendable, CaseIterable {
    case file = "file"
    case webhook = "webhook"
    case lanPeer = "lanPeer"
    case mail = "mail"
    case calendar = "calendar"
}

public struct EventTriggerConfig: Sendable {
    public let kind: EventTriggerKind
    public let identifier: String
    public let targetPath: String?
    public let port: UInt16?
    public let secretToken: String?
    public let pollIntervalSeconds: TimeInterval

    public init(
        kind: EventTriggerKind,
        identifier: String,
        targetPath: String? = nil,
        port: UInt16? = nil,
        secretToken: String? = nil,
        pollIntervalSeconds: TimeInterval = 1.0
    ) {
        self.kind = kind
        self.identifier = identifier
        self.targetPath = targetPath
        self.port = port
        self.secretToken = secretToken
        self.pollIntervalSeconds = pollIntervalSeconds
    }
}

public struct EventTriggerPayload: Sendable, Codable {
    public let triggerType: String
    public let identifier: String
    public let firedAt: Date
    public let metadata: [String: String]
    public let dataPayload: Data?

    public init(
        triggerType: String,
        identifier: String,
        firedAt: Date = Date(),
        metadata: [String: String] = [:],
        dataPayload: Data? = nil
    ) {
        self.triggerType = triggerType
        self.identifier = identifier
        self.firedAt = firedAt
        self.metadata = metadata
        self.dataPayload = dataPayload
    }

    public var summary: String {
        "[\(triggerType.uppercased())] \(identifier) at \(firedAt)"
    }
}

public struct TriggerStats: Sendable, Codable {
    public let kind: EventTriggerKind
    public let identifier: String
    public var fireCount: Int
    public var lastFiredAt: Date?
    public var isLiveVerified: Bool
    public var lastError: String?

    public init(
        kind: EventTriggerKind,
        identifier: String,
        fireCount: Int = 0,
        lastFiredAt: Date? = nil,
        isLiveVerified: Bool = false,
        lastError: String? = nil
    ) {
        self.kind = kind
        self.identifier = identifier
        self.fireCount = fireCount
        self.lastFiredAt = lastFiredAt
        self.isLiveVerified = isLiveVerified
        self.lastError = lastError
    }
}
