import AppKit
import Foundation
import SharedKit

@MainActor
/// Generates a real daily briefing from the Momentum Ecosystem AppGroup data bus.
struct DailyBriefingTool {
    func run() async throws -> DailyBriefing {
        let bus = await AppGroupDataBus.shared
        let taskData = try await JSONEncoder().encode(await bus.sharedTasks)
        let briefing = DailyBriefing(
            mood: await bus.todayMood,
            budgetAlertStatus: await bus.budgetAlertStatus,
            habitCompletionCount: await bus.habitCompletionCount,
            activePowerUp: await bus.activePowerUp,
            taskTitlesData: taskData
        )
        return briefing
    }

    func formattedSummary() async throws -> String {
        let briefing = try await run()
        return briefing.combinedSummary
    }
}
