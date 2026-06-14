import AppKit
import Foundation
import SharedKit

/// Generates a real daily briefing from the Momentum Ecosystem AppGroup data bus.
struct DailyBriefingTool {
    func run() async throws -> DailyBriefing {
        let bus = AppGroupDataBus.shared
        let taskData = try? JSONEncoder().encode(bus.sharedTasks)
        let briefing = DailyBriefing(
            mood: bus.todayMood,
            budgetAlertStatus: bus.budgetAlertStatus,
            habitCompletionCount: bus.habitCompletionCount,
            activePowerUp: bus.activePowerUp,
            taskTitlesData: taskData
        )
        return briefing
    }

    func formattedSummary() async throws -> String {
        let briefing = try await run()
        return briefing.combinedSummary
    }
}
