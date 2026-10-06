import Foundation

// MARK: - Hardening Loop Batch 13: Routine Lifecycle & Config Validation
//
// 10 additive diagnostics/validators for routines, runs, and triggers.
// Pure functions only. No behavior changes.

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
        }
    }

    /// Fields required for this trigger to be runnable.
    public var requiresSchedule: Bool {
        switch self {
        case .timeInterval, .cron: return true
        case .manual, .onError, .onSuccess, .onMessage, .webhook: return false
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
        case .manual, .onError, .onSuccess, .webhook:
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
