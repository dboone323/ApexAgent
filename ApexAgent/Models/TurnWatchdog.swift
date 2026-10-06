import Foundation

// MARK: - TurnWatchdog: activity-based stall detection
//
// A wedged provider (hung network call, dead MCP child, a model that stops
// streaming without exiting) would otherwise leave a bot "busy" forever —
// composer locked, scheduler blocked. This watchdog watches ACTIVITY, not
// duration: a turn may legitimately run for an hour while events keep
// flowing, but a turn whose thread has emitted nothing at all for `stallMs`
// is wedged. Turns parked on a human approval are exempt — waiting on a
// person is not a stall.

public struct WatchedTurn: Sendable {
    public let threadId: String
    public let botId: String
    public let startedAt: TimeInterval
    public var lastEventAt: TimeInterval
    public var waitingOnHuman: Bool

    public init(threadId: String, botId: String, startedAt: TimeInterval, lastEventAt: TimeInterval, waitingOnHuman: Bool = false) {
        self.threadId = threadId
        self.botId = botId
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.waitingOnHuman = waitingOnHuman
    }
}

public final class TurnWatchdog: @unchecked Sendable {

    public struct Options: @unchecked Sendable {
        public var stallMs: TimeInterval
        public var checkMs: TimeInterval
        /// Called once per stalled turn, after the entry is removed.
        public var onStall: (WatchedTurn) -> Void
        public var now: () -> TimeInterval

        public init(stallMs: TimeInterval, checkMs: TimeInterval, onStall: @escaping (WatchedTurn) -> Void, now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
            self.stallMs = stallMs
            self.checkMs = checkMs
            self.onStall = onStall
            self.now = now
        }
    }

    private let options: Options
    private let lock = NSLock()
    private var turns: [String: WatchedTurn] = [:]
    private var timer: Timer?

    public init(options: Options) {
        self.options = options
    }

    private func now() -> TimeInterval {
        options.now()
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: options.checkMs / 1000.0, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.invalidate()
        timer = nil
        turns.removeAll()
    }

    // MARK: Events

    /// A turn was dispatched on this thread.
    public func watch(threadId: String, botId: String) {
        let at = now()
        lock.lock()
        defer { lock.unlock() }
        turns[threadId] = WatchedTurn(threadId: threadId, botId: botId, startedAt: at, lastEventAt: at, waitingOnHuman: false)
    }

    /// Any event for the thread proves the turn is alive.
    public func touch(threadId: String) {
        let at = now()
        lock.lock()
        defer { lock.unlock() }
        guard var turn = turns[threadId] else { return }
        turn.lastEventAt = at
        turns[threadId] = turn
    }

    /// request.opened → true (a human is deciding; not a stall however long they
    /// take); request.resolved → false (the clock restarts).
    public func setWaitingOnHuman(threadId: String, waiting: Bool) {
        let at = now()
        lock.lock()
        defer { lock.unlock() }
        guard var turn = turns[threadId] else { return }
        turn.waitingOnHuman = waiting
        turn.lastEventAt = at
        turns[threadId] = turn
    }

    /// The turn settled normally — stop watching it.
    public func settle(threadId: String) {
        lock.lock()
        defer { lock.unlock() }
        turns.removeValue(forKey: threadId)
    }

    /// Alias for settle.
    public func unwatch(threadId: String) {
        settle(threadId: threadId)
    }

    public func isWatching(threadId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return turns[threadId] != nil
    }

    public func isWaitingOnHuman(threadId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return turns[threadId]?.waitingOnHuman ?? false
    }

    // MARK: Sweep

    /// Visible for tests; the timer calls this on its interval.
    public func sweep() {
        let at = now()
        var stalledTurns: [WatchedTurn] = []

        lock.lock()
        for turn in turns.values where !turn.waitingOnHuman {
            if at - turn.lastEventAt < options.stallMs { continue }
            turns.removeValue(forKey: turn.threadId)
            stalledTurns.append(turn)
        }
        lock.unlock()

        for turn in stalledTurns {
            options.onStall(turn)
        }
    }

    // MARK: - Markdown Diagnostics

    public func formatWatchdogDiagnosticsMarkdown() -> String {
        lock.lock()
        defer { lock.unlock() }

        var md = "### ⏱️ Turn Stall Watchdog Diagnostics\n\n"
        md += "| Metric / Parameter | Value | Description |\n"
        md += "|---|---|---|\n"
        md += "| Monitored Turns | `\(turns.count)` | Currently active tracked turns |\n"
        let humanCount = turns.values.filter(\.waitingOnHuman).count
        md += "| Human-Gated Turns | `\(humanCount)` | Exempt turns paused on approvals |\n"
        md += "| Stall Threshold | `\(Int(options.stallMs / 1000))s` | Heartbeat silence timeout |\n"
        md += "| Check Interval | `\(Int(options.checkMs / 1000))s` | Sweep timer frequency |\n"
        return md
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
