import Foundation

// MARK: - Hardening Loop Batch 16: Trace, Watchdog & Benchmark Reporting
//
// 10 additive formatters/validators. Pure functions only. No behavior changes.

extension TraceEvent {
    public func formatAsMarkdown() -> String {
        var md = "### 🔍 Trace: `\(operation)` from `\(source)`\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Operation | `\(operation)` |\n"
        md += "| Source | `\(source)` |\n"
        if let ms = durationMs {
            md += "| Duration | `\(String(format: "%.1f", ms))ms` |\n"
        }
        if !detail.isEmpty {
            md += "| Detail | \(String(detail.prefix(200)).replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
        return md
    }

    public var isSlow: Bool {
        guard let ms = durationMs else { return false }
        return ms > 1000
    }

    public var isWellFormed: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension WatchedTurn {
    public func formatAsMarkdown(now: TimeInterval = Date().timeIntervalSince1970) -> String {
        let idleSec = max(0, now - lastEventAt)
        var md = "### ⏱️ Watched Turn `\(threadId)`\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Bot | `\(botId)` |\n"
        md += "| Idle | `\(String(format: "%.1fs", idleSec))` |\n"
        md += "| Waiting on Human | \(waitingOnHuman ? "🙋 Yes (exempt)" : "⚪️ No") |\n"
        return md
    }

    /// Stall predicate mirroring TurnWatchdog semantics without a timer.
    public func isStalled(now: TimeInterval, stallSeconds: TimeInterval) -> Bool {
        guard !waitingOnHuman else { return false }
        return (now - lastEventAt) >= stallSeconds
    }
}

extension TurnWatchdog.Options {
    /// Bounds-checks tunables before constructing a watchdog.
    public func validationError() -> String? {
        if stallMs <= 0 { return "stallMs must be positive." }
        if checkMs <= 0 { return "checkMs must be positive." }
        if checkMs > stallMs { return "checkMs should not exceed stallMs." }
        return nil
    }
}

extension BenchmarkTask {
    public func validationError() -> String? {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Task id must not be empty." }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Task title must not be empty." }
        if timeoutSeconds <= 0 { return "timeoutSeconds must be positive." }
        if timeoutSeconds > 3600 { return "timeoutSeconds exceeds 1 hour cap." }
        return nil
    }

    public var isValid: Bool { validationError() == nil }
}

extension BenchmarkResult {
    public func formatAsMarkdownRow() -> String {
        let status = isPassed ? "✅ PASS" : "❌ FAIL"
        let memMb = String(format: "%.1f MB", Double(memoryPeakBytes) / (1024 * 1024))
        return "| `\(taskId)` | \(taskTitle) | \(status) | \(String(format: "%.2fs", duration)) | \(memMb) |"
    }
}
