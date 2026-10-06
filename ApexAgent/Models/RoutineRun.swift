import Foundation
import SwiftData

// MARK: - RoutineRun: a receipt for one execution of a Routine (O5, port of OpenMausBot routines.ts run receipts)
//
// RoutineManager.execute() is fire-and-forget today. A run receipt snapshots
// the work so an edited/deleted definition cannot rewrite history, and lets
// the UI (and, later, webhooks) show queued → running → completed/failed/cancelled
// with the output/error that ended it.

enum RoutineRunStatus: String, Codable, Sendable {
    case queued = "queued"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"

    var isActive: Bool { self == .queued || self == .running }
}

/// A snapshot of one routine execution, keyed independently of the Routine so
/// history survives edits/deletes. Lightweight — not currently backed by
/// SwiftData (kept as a value type so tests and the UI can share it freely).
struct RoutineRun: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let routineId: UUID
    let routineName: String
    /// Snapshot the work so an edited/deleted definition cannot rewrite history.
    let prompt: String
    let botId: UUID?
    let trigger: RoutineTrigger
    var status: RoutineRunStatus
    var startedAt: Date
    var finishedAt: Date?
    var output: String?
    var error: String?

    init(
        id: UUID = UUID(),
        routineId: UUID,
        routineName: String,
        prompt: String,
        botId: UUID? = nil,
        trigger: RoutineTrigger = .manual,
        status: RoutineRunStatus = .queued,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        output: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.routineId = routineId
        self.routineName = routineName
        self.prompt = prompt
        self.botId = botId
        self.trigger = trigger
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.output = output
        self.error = error
    }

    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    var formattedDuration: String {
        guard let duration else { return "Running..." }
        if duration < 1.0 {
            return String(format: "%.0f ms", duration * 1000)
        } else if duration < 60.0 {
            return String(format: "%.1f s", duration)
        } else {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            return "\(mins)m \(secs)s"
        }
    }
}

extension RoutineRunStatus {
    public var badge: String {
        switch self {
        case .queued: return "⏳ Queued"
        case .running: return "⚡️ Running"
        case .completed: return "✅ Completed"
        case .failed: return "❌ Failed"
        case .cancelled: return "🚫 Cancelled"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }
}

extension RoutineRun {
    public func formatAsMarkdown() -> String {
        var md = "### 🔁 Routine Run: `\(routineName)` — \(status.badge)\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Status | \(status.badge) |\n"
        md += "| Trigger | `\(trigger.rawValue)` |\n"
        md += "| Started | `\(startedAt)` |\n"
        md += "| Duration | `\(formattedDuration)` |\n"
        if let out = output, !out.isEmpty {
            md += "| Output | \(String(out.prefix(200)).replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
        if let err = error, !err.isEmpty {
            md += "| Error | \(String(err.prefix(200)).replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
        return md
    }

    /// Terminal-state guard: only terminal runs may carry finishedAt.
    public var isConsistent: Bool {
        if status.isTerminal { return true }
        return finishedAt == nil
    }
}
