import Foundation

/// Cross-app data bus backed by real persistent storage.
///
/// Reads/writes go through the App Group container shared with the Momentum
/// Ecosystem apps (`group.com.dboone323.fleet`). Producers in those apps write
/// into the same suite; ApexAgent reads it back for the daily briefing.
///
/// If the App Group is not provisioned (e.g. an unsigned local build), we fall
/// back to `UserDefaults.standard` — still real, persistent storage, never
/// in-memory-only. This keeps the daily briefing reflecting real data in every
/// build configuration.
@MainActor
public final class AppGroupDataBus {
    public static let shared = AppGroupDataBus()

    public static let appGroupIdentifier = "group.com.dboone323.fleet"

    private enum Key {
        static let sharedTasks = "apex.databus.sharedTasks"
        static let todayMood = "apex.databus.todayMood"
        static let budgetAlertStatus = "apex.databus.budgetAlertStatus"
        static let habitCompletionCount = "apex.databus.habitCompletionCount"
        static let activePowerUp = "apex.databus.activePowerUp"
    }

    /// The backing store: the App Group suite when provisioned, otherwise the
    /// standard defaults. `UserDefaults(suiteName:)` returns nil when the app
    /// group entitlement is not present, so this gracefully degrades.
    private let defaults: UserDefaults

    private init() {
        self.defaults = UserDefaults(suiteName: AppGroupDataBus.appGroupIdentifier) ?? .standard
    }

    // MARK: - Reads

    public var sharedTasks: [SharedTask] {
        guard let data = defaults.data(forKey: Key.sharedTasks),
              let decoded = try? JSONDecoder().decode([SharedTask].self, from: data) else {
            return []
        }
        return decoded
    }

    public var todayMood: String? {
        defaults.string(forKey: Key.todayMood)
    }

    public var budgetAlertStatus: String? {
        defaults.string(forKey: Key.budgetAlertStatus)
    }

    public var habitCompletionCount: Int {
        defaults.integer(forKey: Key.habitCompletionCount)
    }

    public var activePowerUp: Bool {
        defaults.bool(forKey: Key.activePowerUp)
    }

    // MARK: - Writes

    public func update(
        tasks: [SharedTask] = [],
        mood: String? = nil,
        budgetAlertStatus: String? = nil,
        habitCompletionCount: Int = 0,
        activePowerUp: Bool = false
    ) {
        update(tasks: tasks)
        if let mood { update(mood: mood) }
        if let budgetAlertStatus { update(budgetAlertStatus: budgetAlertStatus) }
        update(habitCompletionCount: habitCompletionCount)
        update(activePowerUp: activePowerUp)
    }

    public func update(mood: String) {
        defaults.set(mood, forKey: Key.todayMood)
    }

    public func update(budgetAlertStatus: String) {
        defaults.set(budgetAlertStatus, forKey: Key.budgetAlertStatus)
    }

    public func update(habitCompletionCount: Int) {
        defaults.set(habitCompletionCount, forKey: Key.habitCompletionCount)
    }

    public func update(activePowerUp: Bool) {
        defaults.set(activePowerUp, forKey: Key.activePowerUp)
    }

    public func update(tasks: [SharedTask]) {
        if let data = try? JSONEncoder().encode(tasks) {
            defaults.set(data, forKey: Key.sharedTasks)
        }
    }
}
