import Foundation

// MARK: - Batch 29: Background Scheduling Efficiency (PollPolicy + TickerScheduler)

/// Classification of Timer / Task.sleep sites across ApexAgent.
public enum TimerSiteCategory: String, Codable, Sendable, CaseIterable {
    case periodicHeartbeat
    case adaptivePoll
    case uiRefresh
    case timeoutGuard
    case retryBackoff
    case animationDelay
}

/// Inventory entry describing a Timer or sleep site in the codebase.
public struct TimerSiteDescriptor: Codable, Sendable, Equatable {
    public let owner: String
    public let file: String
    public let category: TimerSiteCategory
    public let baseIntervalSeconds: TimeInterval
    public let isCoalescable: Bool

    public init(
        owner: String,
        file: String,
        category: TimerSiteCategory,
        baseIntervalSeconds: TimeInterval,
        isCoalescable: Bool
    ) {
        self.owner = owner
        self.file = file
        self.category = category
        self.baseIntervalSeconds = baseIntervalSeconds
        self.isCoalescable = isCoalescable
    }
}

/// Pure adaptive polling and wake-up coalescing policy.
public struct PollPolicy: Codable, Sendable, Equatable {
    public var baseInterval: TimeInterval
    public var minInterval: TimeInterval
    public var maxInterval: TimeInterval
    public var idleBackoffFactor: Double
    public var coalesceToleranceFraction: Double

    public init(
        baseInterval: TimeInterval,
        minInterval: TimeInterval? = nil,
        maxInterval: TimeInterval? = nil,
        idleBackoffFactor: Double = 2.0,
        coalesceToleranceFraction: Double = 0.20
    ) {
        let safeBase = max(0.05, baseInterval)
        let safeMin = max(0.01, minInterval ?? safeBase)
        let safeMax = max(safeMin, maxInterval ?? (safeBase * 8.0))
        self.baseInterval = safeBase
        self.minInterval = min(safeMin, safeBase)
        self.maxInterval = safeMax
        self.idleBackoffFactor = max(1.0, idleBackoffFactor)
        self.coalesceToleranceFraction = max(0.0, min(1.0, coalesceToleranceFraction))
    }

    /// Computes the next poll interval given the number of consecutive idle polls and recent activity flag.
    public func nextInterval(consecutiveIdlePolls: Int, hasRecentActivity: Bool) -> TimeInterval {
        if hasRecentActivity || consecutiveIdlePolls <= 0 {
            return min(maxInterval, max(minInterval, baseInterval))
        }
        let exponent = min(20, consecutiveIdlePolls)
        let scaled = baseInterval * pow(idleBackoffFactor, Double(exponent))
        return min(maxInterval, max(minInterval, scaled))
    }

    /// Tolerance window in seconds for coalescing nearby wake-ups.
    public var coalesceWindowSeconds: TimeInterval {
        baseInterval * coalesceToleranceFraction
    }

    /// Returns `true` when `candidateWakeAt` is close enough to `anchorWakeAt` to fire in the same wake-up.
    public func shouldCoalesce(candidateWakeAt: TimeInterval, anchorWakeAt: TimeInterval) -> Bool {
        abs(candidateWakeAt - anchorWakeAt) <= coalesceWindowSeconds
    }

    /// Compares legacy fixed-interval wake-up counts against adaptive backoff wake-up counts over `windowSeconds`.
    public func compareWakeupCounts(
        windowSeconds: TimeInterval,
        idlePollStreak: Bool = true
    ) -> (legacyWakeups: Int, adaptiveWakeups: Int) {
        guard windowSeconds > 0 else { return (0, 0) }
        let legacy = max(1, Int(floor(windowSeconds / baseInterval)))
        if !idlePollStreak {
            return (legacy, legacy)
        }
        var elapsed: TimeInterval = 0
        var adaptive = 0
        var streak = 0
        while elapsed < windowSeconds {
            let interval = nextInterval(consecutiveIdlePolls: streak, hasRecentActivity: false)
            elapsed += interval
            if elapsed <= windowSeconds + 1e-9 {
                adaptive += 1
            }
            streak += 1
        }
        return (legacy, max(1, adaptive))
    }
}

/// Coalesced, activity-aware background ticker scheduler using the `TurnWatchdog` injectable `now:` clock pattern.
public final class TickerScheduler: @unchecked Sendable {
    public static let shared = TickerScheduler()

    public struct RegisteredTicker: Sendable {
        public let id: String
        public var policy: PollPolicy
        public var consecutiveIdlePolls: Int
        public var hasRecentActivity: Bool
        public var lastFiredAt: TimeInterval
        public var nextFireAt: TimeInterval
        public var fireCount: Int
    }

    private struct Entry {
        var state: RegisteredTicker
        var handler: () -> Bool
    }

    private let nowProvider: () -> TimeInterval
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var timer: Timer?
    private var totalCoalescedWakeups: Int = 0
    private var totalSweepWakeups: Int = 0

    /// Canonical inventory of classified timer and sleep sites across ApexAgent.
    public static let siteInventory: [TimerSiteDescriptor] = [
        TimerSiteDescriptor(owner: "RoutineManager", file: "Models/RoutineManager.swift", category: .periodicHeartbeat, baseIntervalSeconds: 60.0, isCoalescable: true),
        TimerSiteDescriptor(owner: "ProactiveScheduler", file: "Models/ProactiveScheduler.swift", category: .periodicHeartbeat, baseIntervalSeconds: 60.0, isCoalescable: true),
        TimerSiteDescriptor(owner: "DiscordMessagePoller", file: "Models/DiscordMessagePoller.swift", category: .adaptivePoll, baseIntervalSeconds: 15.0, isCoalescable: true),
        TimerSiteDescriptor(owner: "VisualPerceptionObserver", file: "Models/VisualPerceptionObserver.swift", category: .adaptivePoll, baseIntervalSeconds: 3.0, isCoalescable: true),
        TimerSiteDescriptor(owner: "AgentOrchestrator.proactiveAudit", file: "AgentOrchestrator.swift", category: .periodicHeartbeat, baseIntervalSeconds: 300.0, isCoalescable: true),
        TimerSiteDescriptor(owner: "DiagnosticsView.recentLogs", file: "UI/DiagnosticsView.swift", category: .uiRefresh, baseIntervalSeconds: 2.0, isCoalescable: false),
        TimerSiteDescriptor(owner: "SettingsView.a2aPeers", file: "UI/SettingsView.swift", category: .uiRefresh, baseIntervalSeconds: 2.0, isCoalescable: false),
        TimerSiteDescriptor(owner: "RoutineRecordingSheet", file: "UI/RoutineRecordingSheet.swift", category: .uiRefresh, baseIntervalSeconds: 1.0, isCoalescable: false),
        TimerSiteDescriptor(owner: "TurnWatchdog", file: "Models/TurnWatchdog.swift", category: .timeoutGuard, baseIntervalSeconds: 5.0, isCoalescable: true),
        TimerSiteDescriptor(owner: "ShellTool.timeout", file: "Tools/ShellTool.swift", category: .timeoutGuard, baseIntervalSeconds: 30.0, isCoalescable: false),
        TimerSiteDescriptor(owner: "WebSearchTool.backoff", file: "Tools/WebSearchTool.swift", category: .retryBackoff, baseIntervalSeconds: 1.0, isCoalescable: false),
        TimerSiteDescriptor(owner: "GhostCursorOverlay", file: "UI/GhostCursorOverlay.swift", category: .animationDelay, baseIntervalSeconds: 0.5, isCoalescable: false)
    ]

    public init(now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.nowProvider = now
    }

    /// Registers or replaces a periodic/adaptive ticker.
    /// - Parameters:
    ///   - id: Unique identifier for the ticker owner.
    ///   - policy: `PollPolicy` governing interval scaling and coalescing window.
    ///   - handler: Closure invoked when the ticker fires; returns `true` if meaningful activity occurred, or `false` if the poll was idle.
    public func register(
        id: String,
        policy: PollPolicy,
        handler: @escaping () -> Bool
    ) {
        let current = nowProvider()
        lock.lock()
        defer { lock.unlock() }

        let initialInterval = policy.nextInterval(consecutiveIdlePolls: 0, hasRecentActivity: true)
        var targetNext = current + initialInterval

        // Align with an existing ticker's nextFireAt if within coalescing tolerance.
        for existing in entries.values {
            if policy.shouldCoalesce(candidateWakeAt: targetNext, anchorWakeAt: existing.state.nextFireAt) {
                targetNext = existing.state.nextFireAt
                break
            }
        }

        let state = RegisteredTicker(
            id: id,
            policy: policy,
            consecutiveIdlePolls: 0,
            hasRecentActivity: false,
            lastFiredAt: current,
            nextFireAt: targetNext,
            fireCount: 0
        )
        entries[id] = Entry(state: state, handler: handler)
    }

    public func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: id)
    }

    /// Signals external activity for `id`, resetting its idle backoff streak and pulling its next fire time to `now + baseInterval` if currently further out.
    public func recordActivity(id: String) {
        let current = nowProvider()
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[id] else { return }
        entry.state.consecutiveIdlePolls = 0
        entry.state.hasRecentActivity = true
        let activeTarget = current + entry.state.policy.baseInterval
        if entry.state.nextFireAt > activeTarget {
            entry.state.nextFireAt = activeTarget
        }
        entries[id] = entry
    }

    public func tickerState(for id: String) -> RegisteredTicker? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.state
    }

    public var registeredIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.sorted()
    }

    public var coalescedWakeupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCoalescedWakeups
    }

    public var sweepWakeupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalSweepWakeups
    }

    /// Evaluates due tickers at `now()`, coalescing any tickers whose `nextFireAt` falls within their policy's coalesce window.
    /// Returns the IDs of tickers that fired during this sweep.
    @discardableResult
    public func sweep() -> [String] {
        let current = nowProvider()
        var dueEntries: [(String, () -> Bool)] = []

        lock.lock()
        let sortedKeys = entries.keys.sorted()
        let anyStrictlyDue = sortedKeys.contains { key in
            guard let entry = entries[key] else { return false }
            return current >= entry.state.nextFireAt - 1e-6
        }

        if anyStrictlyDue {
            for key in sortedKeys {
                guard let entry = entries[key] else { continue }
                let isDue = current >= entry.state.nextFireAt - 1e-6
                let canCoalesce = entry.state.policy.shouldCoalesce(
                    candidateWakeAt: entry.state.nextFireAt,
                    anchorWakeAt: current
                )
                if isDue || canCoalesce {
                    dueEntries.append((key, entry.handler))
                }
            }
            if !dueEntries.isEmpty {
                totalSweepWakeups += 1
                if dueEntries.count > 1 {
                    totalCoalescedWakeups += (dueEntries.count - 1)
                }
            }
        }
        lock.unlock()

        guard !dueEntries.isEmpty else { return [] }

        var firedIds: [String] = []
        for (id, handler) in dueEntries {
            let hadActivity = handler()
            firedIds.append(id)

            lock.lock()
            if var entry = entries[id] {
                let effectiveActivity = hadActivity || entry.state.hasRecentActivity
                if effectiveActivity {
                    entry.state.consecutiveIdlePolls = 0
                } else {
                    entry.state.consecutiveIdlePolls += 1
                }
                entry.state.hasRecentActivity = false
                entry.state.lastFiredAt = current
                entry.state.fireCount += 1
                let nextDelta = entry.state.policy.nextInterval(
                    consecutiveIdlePolls: entry.state.consecutiveIdlePolls,
                    hasRecentActivity: effectiveActivity
                )
                entry.state.nextFireAt = current + nextDelta
                entries[id] = entry
            }
            lock.unlock()
        }

        return firedIds
    }

    /// Starts a single shared RunLoop timer with power-friendly tolerance.
    public func start(checkIntervalSeconds: TimeInterval = 5.0) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let interval = max(0.1, checkIntervalSeconds)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            _ = self?.sweep()
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.invalidate()
        timer = nil
    }
}
