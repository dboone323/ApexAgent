import Testing
import Foundation
@testable import ApexAgentCore

@Suite("HardeningLoopBatch13Tests")
struct HardeningLoopBatch13Tests {
    @Test func testRunStatusBadges() {
        #expect(RoutineRunStatus.queued.badge.contains("Queued"))
        #expect(RoutineRunStatus.completed.badge.contains("Completed"))
        #expect(RoutineRunStatus.completed.isTerminal)
        #expect(!RoutineRunStatus.running.isTerminal)
        #expect(RoutineRunStatus.cancelled.isTerminal)
    }

    @Test func testRoutineRunMarkdown() {
        let run = RoutineRun(routineId: UUID(), routineName: "nightly", prompt: "p", status: .completed)
        let md = run.formatAsMarkdown()
        #expect(md.contains("nightly"))
        #expect(md.contains("Completed"))
        var running = RoutineRun(routineId: UUID(), routineName: "r", prompt: "p", status: .running)
        #expect(running.isConsistent)
        running.finishedAt = Date()
        #expect(!running.isConsistent)
    }

    @Test func testTriggerBadges() {
        #expect(RoutineTrigger.cron.badge.contains("Cron"))
        #expect(RoutineTrigger.cron.requiresSchedule)
        #expect(!RoutineTrigger.manual.requiresSchedule)
        #expect(RoutineTrigger.timeInterval.requiresSchedule)
    }

    @Test func testRoutineConfigValidation() {
        let ok = Routine(name: "n", descriptionText: "d", trigger: .manual)
        #expect(ok.configurationError() == nil)
        #expect(ok.isRunnable)
        #expect(ok.formatAsMarkdown().contains("Runnable"))

        let badInterval = Routine(name: "n", descriptionText: "d", trigger: .timeInterval, scheduledMinutes: 0)
        #expect(badInterval.configurationError() != nil)

        let badCron = Routine(name: "n", descriptionText: "d", trigger: .cron, cronExpression: "junk")
        #expect(badCron.configurationError() != nil)
        let goodCron = Routine(name: "n", descriptionText: "d", trigger: .cron, cronExpression: "0 9 * * 1-5")
        #expect(goodCron.configurationError() == nil)

        let empty = Routine(name: "  ", descriptionText: "d")
        #expect(empty.configurationError() != nil)
    }
}
