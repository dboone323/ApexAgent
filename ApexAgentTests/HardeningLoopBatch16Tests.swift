import Testing
import Foundation
@testable import ApexAgentCore

@Suite("HardeningLoopBatch16Tests")
struct HardeningLoopBatch16Tests {
    @Test func testTraceEvent() {
        let e = TraceEvent(source: "orchestrator", operation: "tool_call", detail: "ls", durationMs: 50)
        #expect(e.isWellFormed)
        #expect(!e.isSlow)
        #expect(e.formatAsMarkdown().contains("tool_call"))
        let slow = TraceEvent(source: "s", operation: "o", durationMs: 5000)
        #expect(slow.isSlow)
        let bad = TraceEvent(source: "", operation: "")
        #expect(!bad.isWellFormed)
    }

    @Test func testWatchedTurn() {
        let turn = WatchedTurn(threadId: "t1", botId: "b1", startedAt: 100, lastEventAt: 100)
        #expect(turn.isStalled(now: 200, stallSeconds: 60))
        #expect(!turn.isStalled(now: 120, stallSeconds: 60))
        var human = WatchedTurn(threadId: "t2", botId: "b2", startedAt: 100, lastEventAt: 100, waitingOnHuman: true)
        #expect(!human.isStalled(now: 9999, stallSeconds: 60))
        #expect(turn.formatAsMarkdown(now: 160).contains("t1"))
    }

    @Test func testWatchdogOptions() {
        let bad = TurnWatchdog.Options(stallMs: -1, checkMs: 100, onStall: { _ in })
        #expect(bad.validationError() != nil)
        let inverted = TurnWatchdog.Options(stallMs: 100, checkMs: 500, onStall: { _ in })
        #expect(inverted.validationError() != nil)
        let ok = TurnWatchdog.Options(stallMs: 5000, checkMs: 500, onStall: { _ in })
        #expect(ok.validationError() == nil)
    }

    @Test func testBenchmarkValidation() {
        let ok = BenchmarkTask(id: "t1", title: "Title", prompt: "p", verificationCommand: "true")
        #expect(ok.isValid)
        let bad = BenchmarkTask(id: "", title: "", prompt: "p", verificationCommand: "true", timeoutSeconds: -1)
        #expect(!bad.isValid)
        let res = BenchmarkResult(taskId: "t1", taskTitle: "Title", isPassed: true, duration: 1.5, memoryPeakBytes: 1_048_576)
        #expect(res.formatAsMarkdownRow().contains("PASS"))
    }
}
