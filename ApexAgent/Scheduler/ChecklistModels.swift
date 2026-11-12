import Foundation

public enum ChecklistItemStatus: String, Codable, Sendable {
    case pending = "pending"
    case passed = "passed"
    case failed = "failed"
    case skipped = "skipped"
}

public enum ChecklistRule: Sendable {
    case command(cmd: String, expectedExit: Int32 = 0)
    case fileExists(path: String)
    case fileNotExists(path: String)
    case fileContains(path: String, substring: String)
    case diskFree(minPercent: Double, mount: String)
    case lockNotStale(path: String, maxAgeSeconds: TimeInterval)
    case manual
}

public struct ChecklistItem: Sendable, Identifiable {
    public let id: String
    public let lineNumber: Int
    public var rawLine: String
    public var title: String
    public var status: ChecklistItemStatus
    public var rule: ChecklistRule?
    public var outcomeReason: String?
    public var evaluatedAt: Date?
    public var duration: TimeInterval?

    public init(
        id: String = UUID().uuidString,
        lineNumber: Int,
        rawLine: String,
        title: String,
        status: ChecklistItemStatus,
        rule: ChecklistRule? = nil,
        outcomeReason: String? = nil,
        evaluatedAt: Date? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.rawLine = rawLine
        self.title = title
        self.status = status
        self.rule = rule
        self.outcomeReason = outcomeReason
        self.evaluatedAt = evaluatedAt
        self.duration = duration
    }
}

public struct JudgementItemResult: Codable, Sendable {
    public let id: String
    public let lineNumber: Int
    public let title: String
    public let passed: Bool
    public let status: ChecklistItemStatus
    public let reason: String
    public let duration: TimeInterval

    public init(
        id: String,
        lineNumber: Int,
        title: String,
        passed: Bool,
        status: ChecklistItemStatus,
        reason: String,
        duration: TimeInterval
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.title = title
        self.passed = passed
        self.status = status
        self.reason = reason
        self.duration = duration
    }
}

public struct JudgementPassReport: Codable, Sendable {
    public let id: UUID
    public let checklistPath: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let totalItems: Int
    public let passedCount: Int
    public let failedCount: Int
    public let skippedCount: Int
    public let items: [JudgementItemResult]

    public init(
        id: UUID = UUID(),
        checklistPath: String,
        timestamp: Date = Date(),
        duration: TimeInterval,
        totalItems: Int,
        passedCount: Int,
        failedCount: Int,
        skippedCount: Int,
        items: [JudgementItemResult]
    ) {
        self.id = id
        self.checklistPath = checklistPath
        self.timestamp = timestamp
        self.duration = duration
        self.totalItems = totalItems
        self.passedCount = passedCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.items = items
    }

    public var overallPassed: Bool {
        failedCount == 0 && totalItems > 0
    }

    public func formatAsMarkdown() -> String {
        let formatter = ISO8601DateFormatter()
        let dateStr = formatter.string(from: timestamp)
        let statusBadge = overallPassed ? "✅ ALL PASSED" : (failedCount > 0 ? "❌ FAILED (\(failedCount) failures)" : "⚪️ EMPTY")

        var md = "# 📋 Heartbeat Judgement Pass Report\n\n"
        md += "- **Checklist File:** `\(checklistPath)`\n"
        md += "- **Timestamp:** `\(dateStr)`\n"
        md += "- **Duration:** `\(String(format: "%.3f", duration))s`\n"
        md += "- **Status:** \(statusBadge)\n"
        md += "- **Summary:** \(passedCount) passed / \(failedCount) failed / \(skippedCount) skipped (\(totalItems) total)\n\n"

        md += "## Item Breakdown\n\n"
        md += "| Line | Title | Status | Reason | Time |\n"
        md += "|---|---|---|---|---|\n"

        for item in items {
            let itemBadge: String
            switch item.status {
            case .passed: itemBadge = "✅ Passed"
            case .failed: itemBadge = "❌ Failed"
            case .skipped: itemBadge = "⚪️ Skipped"
            case .pending: itemBadge = "⏳ Pending"
            }
            md += "| L\(item.lineNumber) | \(item.title) | \(itemBadge) | \(item.reason) | \(String(format: "%.3f", item.duration))s |\n"
        }

        return md
    }
}
