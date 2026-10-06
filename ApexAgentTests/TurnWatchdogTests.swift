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
