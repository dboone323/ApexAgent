import Foundation

/// Protocol for logging tool events from external components (e.g., MCPClient).
/// This replaces the direct coupling of MCPClient to AgentOrchestrator.shared.
@MainActor
public protocol ToolEventLogger: Sendable {
    func logToolStart(name: String, arguments: String)
    func logToolEnd(name: String, result: String, status: ToolStatus)
    func logToolEvent(_ event: ToolEvent)
    func updateToolStatus(name: String, status: ToolStatus)
    func shouldConfirmTool(name: String) -> Bool
    func requestConfirmation(
        toolName: String,
        arguments: String,
        riskDescription: String,
        oldContent: String?,
        newContent: String?,
        filePath: String?
    ) async -> Bool
    func resolveConfirmation(approved: Bool)
}

/// No-op implementation for testing / fallback when no orchestrator is available.
final class ToolEventLoggerImpl: ToolEventLogger {
    public func logToolStart(name: String, arguments: String) {}
    public func logToolEnd(name: String, result: String, status: ToolStatus) {}
    public func logToolEvent(_ event: ToolEvent) {}
    public func updateToolStatus(name: String, status: ToolStatus) {}
    public func shouldConfirmTool(name: String) -> Bool { false }
    public func requestConfirmation(
        toolName: String,
        arguments: String,
        riskDescription: String,
        oldContent: String?,
        newContent: String?,
        filePath: String?
    ) async -> Bool { true }
    public func resolveConfirmation(approved: Bool) {}
}

public enum ToolStatus: Sendable {
    case running
    case success
    case failed(String)
    case awaitingConfirmation
    case denied
}

public struct ToolEvent: Identifiable, Sendable {
    public let id = UUID()
    public let toolName: String
    public let arguments: String
    public var result: String?
    public var status: ToolStatus
    public let timestamp: Date
    
    public init(toolName: String, arguments: String) {
        self.toolName = toolName
        self.arguments = arguments
        self.status = .running
        self.timestamp = Date()
    }
}
