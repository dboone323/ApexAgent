import Foundation

@MainActor
public final class AppGroupDataBus: Sendable {
    public static let shared = AppGroupDataBus()

    public private(set) var sharedTasks: [SharedTask] = []
    public private(set) var todayMood: String?
    public private(set) var budgetAlertStatus: String?
    public private(set) var habitCompletionCount: Int = 0
    public private(set) var activePowerUp: Bool = false

    private init() {}

    public func update(
        tasks: [SharedTask] = [],
        mood: String? = nil,
        budgetAlertStatus: String? = nil,
        habitCompletionCount: Int = 0,
        activePowerUp: Bool = false
    ) {
        self.sharedTasks = tasks
        if let mood { self.todayMood = mood }
        if let budgetAlertStatus { self.budgetAlertStatus = budgetAlertStatus }
        self.habitCompletionCount = habitCompletionCount
        self.activePowerUp = activePowerUp
    }

    public func update(mood: String) {
        self.todayMood = mood
    }

    public func update(budgetAlertStatus: String) {
        self.budgetAlertStatus = budgetAlertStatus
    }

    public func update(habitCompletionCount: Int) {
        self.habitCompletionCount = habitCompletionCount
    }

    public func update(activePowerUp: Bool) {
        self.activePowerUp = activePowerUp
    }

    public func update(tasks: [SharedTask]) {
        self.sharedTasks = tasks
    }
}
