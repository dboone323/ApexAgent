import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Watched turn stall detection & watchdog options validation

@Suite("TurnWatchdogGuardTests")
struct TurnWatchdogGuardTests {
    @Test func watchedTurn() {
        let turn = WatchedTurn(threadId: "t1", botId: "b1", startedAt: 100, lastEventAt: 100)
        #expect(turn.isStalled(now: 200, stallSeconds: 60))
        #expect(!turn.isStalled(now: 120, stallSeconds: 60))
        let human = WatchedTurn(threadId: "t2", botId: "b2", startedAt: 100, lastEventAt: 100, waitingOnHuman: true)
        #expect(!human.isStalled(now: 9999, stallSeconds: 60))
        #expect(turn.formatAsMarkdown(now: 160).contains("t1"))
    }

    @Test func watchdogOptions() {
        let bad = TurnWatchdog.Options(stallMs: -1, checkMs: 100, onStall: { _ in })
        #expect(bad.validationError() != nil)
        let inverted = TurnWatchdog.Options(stallMs: 100, checkMs: 500, onStall: { _ in })
        #expect(inverted.validationError() != nil)
        let ok = TurnWatchdog.Options(stallMs: 5000, checkMs: 500, onStall: { _ in })
        #expect(ok.validationError() == nil)
    }
}

@Suite("TurnWatchdogTests")
struct TurnWatchdogTests {

    @Test func stallFiresOnStallExactlyOnce() {
        var time = 0.0
        var stalled: [WatchedTurn] = []
        let watchdog = TurnWatchdog(options: .init(
            stallMs: 1_000, checkMs: 500,
            onStall: { stalled.append($0) },
            now: { time }
        ))
        watchdog.watch(threadId: "t", botId: "b")
        watchdog.touch(threadId: "t")
        watchdog.sweep()
        #expect(stalled.isEmpty) // fresh

        time = 2_000
        watchdog.sweep()
        #expect(stalled.count == 1)
        #expect(stalled[0].threadId == "t")

        watchdog.sweep() // removed → no double fire
        #expect(stalled.count == 1)
        #expect(!watchdog.isWatching(threadId: "t"))
    }

    @Test func touchResetsTheClock() {
        var time = 0.0
        var stalled: [WatchedTurn] = []
        let watchdog = TurnWatchdog(options: .init(
            stallMs: 1_000, checkMs: 500,
            onStall: { stalled.append($0) },
            now: { time }
        ))
        watchdog.watch(threadId: "t", botId: "b")
        time = 900
        watchdog.touch(threadId: "t")
        time = 1_000
        watchdog.sweep()
        #expect(stalled.isEmpty) // activity restarted the clock
    }

    @Test func waitingOnHumanIsExempt() {
        var time = 0.0
        var stalled: [WatchedTurn] = []
        let watchdog = TurnWatchdog(options: .init(
            stallMs: 1_000, checkMs: 500,
            onStall: { stalled.append($0) },
            now: { time }
        ))
        watchdog.watch(threadId: "t", botId: "b")
        watchdog.setWaitingOnHuman(threadId: "t", waiting: true)
        time = 10_000
        watchdog.sweep()
        #expect(stalled.isEmpty)
        #expect(watchdog.isWatching(threadId: "t"))
    }

    @Test func settleStopsWatching() {
        var time = 0.0
        let watchdog = TurnWatchdog(options: .init(
            stallMs: 1_000, checkMs: 500,
            onStall: { _ in },
            now: { time }
        ))
        watchdog.watch(threadId: "t", botId: "b")
        watchdog.settle(threadId: "t")
        time = 2_000
        watchdog.sweep()
        #expect(!watchdog.isWatching(threadId: "t"))
    }
}
