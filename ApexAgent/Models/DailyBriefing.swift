import Foundation
import AppKit
import SharedKit
import SwiftData

/// Email preview from a browser/session outlook mail view.
struct EmailPreview: Identifiable, Codable, Sendable {
    let id: UUID
    let from: String
    let subject: String
    let snippet: String
    let receivedAt: Date
}

/// App-sync topic summary from system signals.
struct AppSyncTopic: Identifiable, Codable, Sendable {
    let id: UUID
    let appName: String
    let topic: String
    let updatedAt: Date
}

/// Shared Outlook Inbox preview reference.
struct OutlookInboxReference: Codable, Sendable {
    let lastRefreshed: Date
    let previews: [EmailPreview]
}

/// Unified daily briefing model for ApexAgent.
@Model
final class DailyBriefing: Identifiable {
    @Attribute(.unique) var id: UUID
    var createdAt: Date = Date()
    var source: String = "apex_agent"

    var mood: String?
    var budgetAlertStatus: String?
    var habitCompletionCount: Int = 0
    var activePowerUp: Bool = false
    var taskTitlesData: Data?
    var outlookData: Data?
    var appSyncData: Data?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: String = "apex_agent",
        mood: String? = nil,
        budgetAlertStatus: String? = nil,
        habitCompletionCount: Int = 0,
        activePowerUp: Bool = false,
        taskTitlesData: Data? = nil,
        outlookData: Data? = nil,
        appSyncData: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.mood = mood
        self.budgetAlertStatus = budgetAlertStatus
        self.habitCompletionCount = habitCompletionCount
        self.activePowerUp = activePowerUp
        self.taskTitlesData = taskTitlesData
        self.outlookData = outlookData
        self.appSyncData = appSyncData
    }

    var recentSharedTasks: [SharedTask] {
        get {
            (try? JSONDecoder().decode([SharedTask].self, from: taskTitlesData ?? Data())) ?? []
        }
        set {
            taskTitlesData = try? JSONEncoder().encode(newValue)
        }
    }

    var outlookInbox: OutlookInboxReference? {
        get {
            (try? JSONDecoder().decode(OutlookInboxReference.self, from: outlookData ?? Data()))
        }
        set {
            outlookData = try? JSONEncoder().encode(newValue)
        }
    }

    var appSyncTopics: [AppSyncTopic] {
        get {
            (try? JSONDecoder().decode([AppSyncTopic].self, from: appSyncData ?? Data())) ?? []
        }
        set {
            appSyncData = try? JSONEncoder().encode(newValue)
        }
    }

    var combinedSummary: String {
        var parts: [String] = []
        if let mood, !mood.isEmpty { parts.append("Mood: \(mood).") }
        if let budgetAlertStatus, !budgetAlertStatus.isEmpty {
            parts.append("Budget status: \(budgetAlertStatus).")
        } else {
            parts.append("No active budget alerts reported.")
        }
        parts.append("Habits completed today: \(habitCompletionCount).")
        parts.append(activePowerUp ? "Power-up active." : "Power-up not active.")

        let taskCount = recentSharedTasks.count
        if taskCount > 0 {
            let topTitles = recentSharedTasks.prefix(5).map { $0.title }.joined(separator: "; ")
            parts.append("Recent tasks at a glance: \(topTitles).")
        }

        let previews = outlookInbox?.previews ?? []
        if previews.isEmpty == false {
            parts.append("\(previews.count) recent Outlook preview available.")
        }

        if appSyncTopics.isEmpty == false {
            parts.append("\(appSyncTopics.count) live app topics detected.")
        }

        return parts.joined(separator: " ")
    }
}

extension DailyBriefing {
    static func liveSnapshot(
        mood: String? = nil,
        budgetAlertStatus: String? = nil,
        habitCompletionCount: Int = 0,
        activePowerUp: Bool = false,
        recentSharedTasks: [SharedTask] = [],
        outlookInbox: OutlookInboxReference? = nil,
        appSyncTopics: [AppSyncTopic] = []
    ) -> DailyBriefing {
        let model = DailyBriefing()
        model.mood = mood
        model.budgetAlertStatus = budgetAlertStatus
        model.habitCompletionCount = habitCompletionCount
        model.activePowerUp = activePowerUp
        model.recentSharedTasks = recentSharedTasks
        model.outlookInbox = outlookInbox
        model.appSyncTopics = appSyncTopics
        return model
    }
}


extension DailyBriefing {
    public func formatAsMarkdown() -> String {
        var md = "# ☀️ Daily Executive Briefing\n\n"
        md += "- **Generated At**: `\(createdAt)`\n"
        if let mood {
            md += "- **Daily Mood**: \(mood)\n"
        }
        if let alert = budgetAlertStatus {
            md += "- **Budget Status**: \(alert)\n"
        }
        md += "- **Habits Completed**: `\(habitCompletionCount)`\n"
        md += "- **Focus Power-Up**: \(activePowerUp ? "⚡️ Active" : "⚪️ Inactive")\n\n"

        let tasks = recentSharedTasks
        if !tasks.isEmpty {
            md += "### 📋 Priority Tasks (\(tasks.count) items)\n\n"
            md += "| Task Title | Status |\n"
            md += "|---|---|\n"
            for t in tasks.prefix(10) {
                let statusBadge = (t.status.lowercased() == "completed" || t.status.lowercased() == "done") ? "✅ Completed" : "⏳ Pending"
                let safeTitle = t.title.replacingOccurrences(of: "|", with: "\\|")
                md += "| \(safeTitle) | \(statusBadge) |\n"
            }
            md += "\n"
        }

        if let previews = outlookInbox?.previews, !previews.isEmpty {
            md += "### 📬 Outlook Inbox Highlights\n\n"
            md += "| From | Subject | Received At |\n"
            md += "|---|---|---|\n"
            for p in previews.prefix(5) {
                let safeFrom = p.from.replacingOccurrences(of: "|", with: "\\|")
                let safeSub = p.subject.replacingOccurrences(of: "|", with: "\\|")
                md += "| \(safeFrom) | \(safeSub) | `\(p.receivedAt)` |\n"
            }
            md += "\n"
        }

        if !appSyncTopics.isEmpty {
            md += "### 🔄 System App Sync Topics\n\n"
            md += "| Application | Active Topic | Updated At |\n"
            md += "|---|---|---|\n"
            for topic in appSyncTopics.prefix(5) {
                let safeApp = topic.appName.replacingOccurrences(of: "|", with: "\\|")
                let safeTopic = topic.topic.replacingOccurrences(of: "|", with: "\\|")
                md += "| **\(safeApp)** | \(safeTopic) | `\(topic.updatedAt)` |\n"
            }
            md += "\n"
        }

        return md
    }
}
