import Foundation

// MARK: - Personal Context Toggle Store (Issue #85)

/// Thread-safe toggle store for personal context sources.
/// Allows enabling or disabling each source independently.
public final class PersonalContextToggleStore: @unchecked Sendable {
    public static let shared = PersonalContextToggleStore()

    private let lock = NSLock()
    private let userDefaults: UserDefaults?
    private var inMemoryToggles: [PersonalContextSource: Bool]

    private static let keyPrefix = "apex.personalContext.toggle."

    public init(userDefaults: UserDefaults? = .standard, inMemory: Bool = false) {
        if inMemory {
            self.userDefaults = nil
        } else {
            self.userDefaults = userDefaults
        }

        var initial: [PersonalContextSource: Bool] = [:]
        for source in PersonalContextSource.allCases {
            if let ud = self.userDefaults, ud.object(forKey: Self.keyPrefix + source.rawValue) != nil {
                initial[source] = ud.bool(forKey: Self.keyPrefix + source.rawValue)
            } else {
                // Default: all sources are enabled by default
                initial[source] = true
            }
        }
        self.inMemoryToggles = initial
    }

    /// Whether the specified source is enabled in the toggle store.
    public func isEnabled(source: PersonalContextSource) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inMemoryToggles[source] ?? true
    }

    /// Set whether the specified source is enabled.
    public func setEnabled(source: PersonalContextSource, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        inMemoryToggles[source] = enabled
        userDefaults?.set(enabled, forKey: Self.keyPrefix + source.rawValue)
    }

    /// Returns a dictionary of all source toggles.
    public func allToggles() -> [PersonalContextSource: Bool] {
        lock.lock()
        defer { lock.unlock() }
        return inMemoryToggles
    }

    /// Resets all toggles to the default state (all enabled).
    public func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        for source in PersonalContextSource.allCases {
            inMemoryToggles[source] = true
            userDefaults?.removeObject(forKey: Self.keyPrefix + source.rawValue)
        }
    }
}
