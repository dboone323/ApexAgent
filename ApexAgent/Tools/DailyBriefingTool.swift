import AppKit
import Foundation
import FoundationModels
import SharedKit

// MARK: - Daily Briefing Tool

/// Generates a real daily briefing from the Momentum Ecosystem AppGroup data bus.
struct DailyBriefingTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "daily_briefing"
    let description = """
    Generates the user's daily briefing from the shared Momentum Ecosystem data bus: \
    today's mood, budget alert status, habit completion count, active power-up, and recent shared tasks. \
    Use this when the user asks for their daily briefing, morning summary, or a status overview.
    """

    @Generable
    struct Arguments: Decodable {}

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            return try await self.formattedSummary()
        }
    }

    /// Builds a `DailyBriefing` snapshot from the real AppGroup-backed data bus.
    @MainActor
    func run() async throws -> DailyBriefing {
        let bus = AppGroupDataBus.shared
        let taskData = try JSONEncoder().encode(bus.sharedTasks)
        let briefing = DailyBriefing(
            mood: bus.todayMood,
            budgetAlertStatus: bus.budgetAlertStatus,
            habitCompletionCount: bus.habitCompletionCount,
            activePowerUp: bus.activePowerUp,
            taskTitlesData: taskData
        )
        return briefing
    }

    @MainActor
    func formattedSummary() async throws -> String {
        let briefing = try await run()
        return briefing.combinedSummary
    }
}
