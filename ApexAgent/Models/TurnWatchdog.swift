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

struct WatchedTurn: Sendable {
    let threadId: String
    let botId: String
    let startedAt: TimeInterval
    var lastEventAt: TimeInterval
    var waitingOnHuman: Bool
}

final class TurnWatchdog {

    struct Options {
        var stallMs: TimeInterval
        var checkMs: TimeInterval
        /// Called once per stalled turn, after the entry is removed.
        var onStall: (WatchedTurn) -> Void
        var now: () -> TimeInterval
    }

    private let options: Options
    private var turns: [String: WatchedTurn] = [:]
    private var timer: Timer?

    init(options: Options) {
        self.options = options
    }

    private func now() -> TimeInterval {
        options.now()
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: options.checkMs / 1000.0, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        turns.removeAll()
    }

    // MARK: Events

    /// A turn was dispatched on this thread.
    func watch(threadId: String, botId: String) {
        let at = now()
        turns[threadId] = WatchedTurn(threadId: threadId, botId: botId, startedAt: at, lastEventAt: at, waitingOnHuman: false)
    }

    /// Any event for the thread proves the turn is alive.
    func touch(threadId: String) {
        guard var turn = turns[threadId] else { return }
        turn.lastEventAt = now()
        turns[threadId] = turn
    }

    /// request.opened → true (a human is deciding; not a stall however long they
    /// take); request.resolved → false (the clock restarts).
    func setWaitingOnHuman(threadId: String, waiting: Bool) {
        guard var turn = turns[threadId] else { return }
        turn.waitingOnHuman = waiting
        turn.lastEventAt = now()
        turns[threadId] = turn
    }

    /// The turn settled normally — stop watching it.
    func settle(threadId: String) {
        turns.removeValue(forKey: threadId)
    }

    func isWatching(threadId: String) -> Bool {
        turns[threadId] != nil
    }

    // MARK: Sweep

    /// Visible for tests; the timer calls this on its interval.
    func sweep() {
        let at = now()
        for turn in turns.values where !turn.waitingOnHuman {
            if at - turn.lastEventAt < options.stallMs { continue }
            turns.removeValue(forKey: turn.threadId)
            options.onStall(turn)
        }
    }
}