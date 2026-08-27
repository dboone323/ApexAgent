import Foundation

// MARK: - TurnWatchdog: activity-based stall detection (O4, port of OpenMausBot turn-watchdog.ts)
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

public final class TurnWatchdog {

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
        guard timer == nil else { return }
        let timer = Timer(timeInterval: options.checkMs / 1000.0, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        turns.removeAll()
    }

    // MARK: Events

    /// A turn was dispatched on this thread.
    public func watch(threadId: String, botId: String) {
        let at = now()
        turns[threadId] = WatchedTurn(threadId: threadId, botId: botId, startedAt: at, lastEventAt: at, waitingOnHuman: false)
    }

    /// Any event for the thread proves the turn is alive.
    public func touch(threadId: String) {
        guard var turn = turns[threadId] else { return }
        turn.lastEventAt = now()
        turns[threadId] = turn
    }

    /// request.opened → true (a human is deciding; not a stall however long they
    /// take); request.resolved → false (the clock restarts).
    public func setWaitingOnHuman(threadId: String, waiting: Bool) {
        guard var turn = turns[threadId] else { return }
        turn.waitingOnHuman = waiting
        turn.lastEventAt = now()
        turns[threadId] = turn
    }

    /// The turn settled normally — stop watching it.
    public func settle(threadId: String) {
        turns.removeValue(forKey: threadId)
    }

    public func isWatching(threadId: String) -> Bool {
        turns[threadId] != nil
    }

    // MARK: Sweep

    /// Visible for tests; the timer calls this on its interval.
    public func sweep() {
        let at = now()
        for turn in turns.values where !turn.waitingOnHuman {
            if at - turn.lastEventAt < options.stallMs { continue }
            turns.removeValue(forKey: turn.threadId)
            options.onStall(turn)
        }
    }
}