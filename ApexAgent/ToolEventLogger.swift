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
/// Must be @MainActor: the ToolEventLogger protocol is @MainActor-isolated.
@MainActor
final class ToolEventLoggerImpl: ToolEventLogger {
    public func logToolStart(name: String, arguments: String) {
        AppLog.debug(.toolbox, "Tool '\(name)' started with arguments: \(arguments)")
    }

    public func logToolEnd(name: String, result: String, status: ToolStatus) {
        AppLog.debug(.toolbox, "Tool '\(name)' ended with status: \(status), result: \(result)")
    }

    public func logToolEvent(_ event: ToolEvent) {
        AppLog.debug(.toolbox, "ToolEvent logged: tool=\(event.toolName) status=\(event.status) timestamp=\(event.timestamp)")
    }

    public func updateToolStatus(name: String, status: ToolStatus) {
        AppLog.debug(.toolbox, "Tool '\(name)' status updated to: \(status)")
    }

    public func shouldConfirmTool(name: String) -> Bool { false }

    public func requestConfirmation(
        toolName: String,
        arguments: String,
        riskDescription: String,
        oldContent: String?,
        newContent: String?,
        filePath: String?
    ) async -> Bool {
        // Default: deny dangerous actions when no orchestrator is wired for user confirmation
        AppLog.debug(.toolbox, "Confirmation requested for tool '\(toolName)' without active orchestrator; defaulting to deny.")
        return false
    }

    public func resolveConfirmation(approved: Bool) {
        AppLog.debug(.toolbox, "Confirmation resolved: approved=\(approved)")
    }
}

public enum ToolStatus: Sendable, Equatable {
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


extension ToolEvent {
    // MARK: - Markdown Events Table

    public static func formatEventsTable(_ events: [ToolEvent]) -> String {
        guard !events.isEmpty else {
            return "No tool events logged."
        }

        var md = "### 🛠️ Tool Execution Event Telemetry (\(events.count) events)\n\n"
        md += "| Tool Name | Status | Timestamp | Arguments |\n"
        md += "|---|---|---|---|\n"

        let formatter = ISO8601DateFormatter()
        for evt in events {
            let statusBadge: String
            switch evt.status {
            case .running: statusBadge = "🔵 Running"
            case .success: statusBadge = "🟢 Success"
            case .failed(let err): statusBadge = "🔴 Failed (\(err.replacingOccurrences(of: "|", with: "\\|")))"
            case .awaitingConfirmation: statusBadge = "🟡 Pending Auth"
            case .denied: statusBadge = "⛔️ Denied"
            }

            let safeName = evt.toolName.replacingOccurrences(of: "|", with: "\\|")
            let safeArgs = evt.arguments.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            let ts = formatter.string(from: evt.timestamp)
            md += "| `\(safeName)` | \(statusBadge) | `\(ts)` | `\(safeArgs)` |\n"
        }
        return md
    }
}
