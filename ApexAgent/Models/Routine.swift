import Foundation
import SwiftData

// MARK: - Routine: A persisted, named routine (visible in Settings + executable by RoutineManager)

/// A Routine is a named, reusable automation that the user can trigger manually,
/// on a time interval, or as a reaction to a chat outcome (build failure, tool
/// success, etc.).  Unlike Skills (which are shell scripts with JSON schemas),
/// a Routine is a *prompt + routing instruction* executed by a Bot through the
/// shared AgentOrchestrator — the same path a normal chat message takes.
///
/// Stored in SwiftData so it persists across launches and shows up in Settings
/// alongside Skills.
@Model
final class Routine {
    @Attribute(.unique) var name: String
    var descriptionText: String        // the prompt/signature of the routine
    var trigger: RoutineTrigger
    var scheduledMinutes: Int          // used when trigger == .timeInterval
    var cronExpression: String?        // used when trigger == .cron
    var messageFilter: String?   // used when trigger == .onMessage (match filter)
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        descriptionText: String,
        trigger: RoutineTrigger = .manual,
        scheduledMinutes: Int = 0,
        cronExpression: String? = nil,
        messageFilter: String? = nil,
        enabled: Bool = true
    ) {
        self.name = name
        self.descriptionText = descriptionText
        self.trigger = trigger
        self.scheduledMinutes = scheduledMinutes
        self.cronExpression = cronExpression
        self.messageFilter = messageFilter
        self.enabled = enabled
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    var effectiveScheduleDescription: String {
        if trigger == .cron, let cron = cronExpression {
            return (try? CronSchedule(expression: cron).humanReadableDescription) ?? trigger.rawValue
        } else if trigger == .timeInterval {
            return "Every \(scheduledMinutes) min"
        } else if trigger == .onMessage {
            if let filter = messageFilter, !filter.isEmpty {
                return "On message: \"\(filter)\""
            } else {
                return "On any message"
            }
        }
        return trigger.rawValue
    }

    var stableUUID: UUID {
        if let data = name.data(using: .utf8) {
            var hash = [UInt8](repeating: 0, count: 16)
            data.withUnsafeBytes { buffer in
                for (i, byte) in buffer.enumerated() {
                    hash[i % 16] ^= byte
                }
            }
            return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
        }
        return UUID()
    }
}

// MARK: - RoutineTrigger: when a Routine fires

public enum RoutineTrigger: String, Codable, CaseIterable, Sendable {
    case manual              = "Manual"                  // user presses "Run now"
    case timeInterval        = "Every N minutes"         // Timer-based; scheduledMinutes > 0
    case cron                = "Cron expression"         // cron-based trigger
    case onError             = "When build/tool fails"   // reaction to a failure signal
    case onSuccess           = "When build/tool succeeds"// reaction to a success signal
    case onMessage           = "On specific message"     // reaction to incoming chat message
    case webhook             = "Webhook"                 // triggered by an external POST
    case fileChange          = "On file change"          // triggered by filesystem change
    case mailArrival         = "On mail arrival"         // triggered by incoming mail
    case calendarEvent       = "On calendar event"       // triggered by upcoming calendar event
    case lanPeer             = "On LAN peer message"     // triggered by LAN peer packet
}

extension RoutineTrigger {
    public var badge: String {
        switch self {
        case .manual: return "👆 Manual"
        case .timeInterval: return "⏱️ Interval"
        case .cron: return "📅 Cron"
        case .onError: return "🔥 On Error"
        case .onSuccess: return "🎉 On Success"
        case .onMessage: return "💬 On Message"
        case .webhook: return "🪝 Webhook"
        case .fileChange: return "📁 File Change"
        case .mailArrival: return "✉️ Mail Arrival"
        case .calendarEvent: return "🗓️ Calendar Event"
        case .lanPeer: return "📡 LAN Peer"
        }
    }

    /// Fields required for this trigger to be runnable.
    public var requiresSchedule: Bool {
        switch self {
        case .timeInterval, .cron: return true
        case .manual, .onError, .onSuccess, .onMessage, .webhook, .fileChange, .mailArrival, .calendarEvent, .lanPeer: return false
        }
    }
}

extension Routine {
    /// Validates trigger configuration. Nil = runnable.
    public func configurationError() -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Routine name must not be empty." }
        switch trigger {
        case .timeInterval:
            if scheduledMinutes <= 0 { return "Interval routines require scheduledMinutes > 0." }
            if scheduledMinutes > 525_600 { return "Interval exceeds one year; likely misconfigured." }
        case .cron:
            guard let expr = cronExpression, !expr.isEmpty else {
                return "Cron routines require a cronExpression."
            }
            if (try? CronSchedule(expression: expr)) == nil {
                return "Invalid cronExpression: '\(expr)'."
            }
        case .onMessage:
            if let f = messageFilter, f.count > 500 {
                return "messageFilter exceeds 500 characters."
            }
        case .manual, .onError, .onSuccess, .webhook, .fileChange, .mailArrival, .calendarEvent, .lanPeer:
            break
        }
        return nil
    }

    public var isRunnable: Bool { configurationError() == nil }

    public func formatAsMarkdown() -> String {
        var md = "### 🔁 Routine: `\(name)` — \(trigger.badge)\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Trigger | \(trigger.badge) |\n"
        md += "| Schedule | \(effectiveScheduleDescription) |\n"
        md += "| Status | \(enabled ? "🟢 Enabled" : "⚪️ Disabled") |\n"
        md += "| Valid | \(configurationError() == nil ? "✅ Runnable" : "❌ \(configurationError() ?? "")") |\n"
        return md
    }
}
