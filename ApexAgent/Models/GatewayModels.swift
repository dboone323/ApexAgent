import Foundation

public enum CodableMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct CodableToolEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let status: String
    public let riskDescription: String?
    public let arguments: String
    public let result: String?
    public let timestamp: Date
    
    public init(id: UUID = UUID(), toolName: String, status: String, riskDescription: String?, arguments: String, result: String?, timestamp: Date = Date()) {
        self.id = id
        self.toolName = toolName
        self.status = status
        self.riskDescription = riskDescription
        self.arguments = arguments
        self.result = result
        self.timestamp = timestamp
    }
}

public struct CodableChatMessage: Codable, Sendable, Identifiable {
    public let id: UUID
    public let role: CodableMessageRole
    public let content: String
    public let toolEvents: [CodableToolEvent]
    public let timestamp: Date
    public let isStreaming: Bool
    public let attachmentPNGs: [Data]
    
    public init(id: UUID = UUID(), role: CodableMessageRole, content: String, toolEvents: [CodableToolEvent] = [], timestamp: Date = Date(), isStreaming: Bool = false, attachmentPNGs: [Data] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.toolEvents = toolEvents
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.attachmentPNGs = attachmentPNGs
    }
}

public enum GatewayAction: Codable, Sendable {
    // Client to Server requests
    case sendMessage(text: String, attachments: [Data])
    case cancelGeneration
    case resolveConfirmation(id: UUID, approved: Bool)
    
    // Server to Client state streams
    case stateUpdate(messages: [CodableChatMessage], isGenerating: Bool, activeAssistantMessageId: UUID?)
    case terminalResult(message: String, isError: Bool)
    case requestConfirmation(id: UUID, toolName: String, arguments: String, riskDescription: String)
    case logEvent(message: String)
}
