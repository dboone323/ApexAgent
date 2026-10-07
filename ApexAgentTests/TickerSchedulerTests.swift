import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 29 — Background Scheduling Efficiency Tests", .serialized)
struct TickerSchedulerTests {

    @Test("PollPolicy scales interval exponentially on idle streaks and resets immediately on activity")
    func pollPolicyAdaptiveBackoffAndActivityReset() {
        let policy = PollPolicy(
            baseInterval: 15.0,
            minInterval: 15.0,
            maxInterval: 120.0,
            idleBackoffFactor: 2.0,
            coalesceToleranceFraction: 0.20
        )

        #expect(policy.nextInterval(consecutiveIdlePolls: 0, hasRecentActivity: true) == 15.0)
        #expect(policy.nextInterval(consecutiveIdlePolls: 1, hasRecentActivity: false) == 30.0)
        #expect(policy.nextInterval(consecutiveIdlePolls: 2, hasRecentActivity: false) == 60.0)
        #expect(policy.nextInterval(consecutiveIdlePolls: 3, hasRecentActivity: false) == 120.0)
        // Clamped at maxInterval (120s)
        #expect(policy.nextInterval(consecutiveIdlePolls: 6, hasRecentActivity: false) == 120.0)
        // Activity immediately resets to baseInterval
        #expect(policy.nextInterval(consecutiveIdlePolls: 6, hasRecentActivity: true) == 15.0)
    }

    @Test("TickerScheduler coalesces nearby ticker deadlines and eliminates duplicate wake-ups using injectable clock")
    func tickerSchedulerCoalescesWakeupsWithInjectableClock() {
        var fakeNow: TimeInterval = 1_000.0
        let scheduler = TickerScheduler(now: { fakeNow })

        var routineFires = 0
        var proactiveFires = 0

        let policy60 = PollPolicy(
            baseInterval: 60.0,
            minInterval: 60.0,
            maxInterval: 240.0,
            idleBackoffFactor: 2.0,
            coalesceToleranceFraction: 0.20 // 12s window
        )

        // Register RoutineManager at t = 1000 (nextFireAt = 1060)
        scheduler.register(id: "RoutineManager.heartbeat", policy: policy60) {
            routineFires += 1
            return false // idle
        }

        // Register ProactiveScheduler 5 seconds later at t = 1005 (candidate 1065 is within 12s of 1060 -> coalesced to 1060)
        fakeNow = 1_005.0
        scheduler.register(id: "ProactiveScheduler.heartbeat", policy: policy60) {
            proactiveFires += 1
            return false // idle
        }

        let routineState = scheduler.tickerState(for: "RoutineManager.heartbeat")
        let proactiveState = scheduler.tickerState(for: "ProactiveScheduler.heartbeat")
        #expect(routineState?.nextFireAt == 1_060.0)
        #expect(proactiveState?.nextFireAt == 1_060.0)

        // Before deadline at t = 1050: nothing fires
        fakeNow = 1_050.0
        let earlyFired = scheduler.sweep()
        #expect(earlyFired.isEmpty)
        #expect(routineFires == 0)
        #expect(proactiveFires == 0)

        // At t = 1060: both fire in a single coalesced sweep!
        fakeNow = 1_060.0
        let fired = scheduler.sweep()
        #expect(fired == ["ProactiveScheduler.heartbeat", "RoutineManager.heartbeat"])
        #expect(routineFires == 1)
        #expect(proactiveFires == 1)
        #expect(scheduler.sweepWakeupCount == 1)
        #expect(scheduler.coalescedWakeupCount == 1)

        // Because both returned false (idle), consecutiveIdlePolls == 1 -> nextFireAt backed off to 1060 + 120 = 1180
        #expect(scheduler.tickerState(for: "RoutineManager.heartbeat")?.nextFireAt == 1_180.0)
        #expect(scheduler.tickerState(for: "ProactiveScheduler.heartbeat")?.nextFireAt == 1_180.0)
    }

    @Test("External activity via recordActivity resets idle backoff without stalling")
    func recordActivityPullsDeadlineForwardWithoutStalling() {
        var fakeNow: TimeInterval = 5_000.0
        let scheduler = TickerScheduler(now: { fakeNow })

        let policy = PollPolicy(baseInterval: 15.0, minInterval: 15.0, maxInterval: 120.0)
        var pollCount = 0

        scheduler.register(id: "DiscordMessagePoller", policy: policy) {
            pollCount += 1
            return false // idle poll
        }

        // First fire at 5015 -> backs off to 5015 + 30 = 5045
        fakeNow = 5_015.0
        #expect(scheduler.sweep() == ["DiscordMessagePoller"])
        #expect(pollCount == 1)
        #expect(scheduler.tickerState(for: "DiscordMessagePoller")?.nextFireAt == 5_045.0)

        // Second idle fire at 5045 -> backs off to 5045 + 60 = 5105
        fakeNow = 5_045.0
        #expect(scheduler.sweep() == ["DiscordMessagePoller"])
        #expect(pollCount == 2)
        #expect(scheduler.tickerState(for: "DiscordMessagePoller")?.nextFireAt == 5_105.0)

        // At t = 5050, user/webhook activity arrives -> deadline pulled forward to 5050 + 15 = 5065
        fakeNow = 5_050.0
        scheduler.recordActivity(id: "DiscordMessagePoller")
        let updated = scheduler.tickerState(for: "DiscordMessagePoller")
        #expect(updated?.consecutiveIdlePolls == 0)
        #expect(updated?.nextFireAt == 5_065.0)

        // Fires promptly at 5065 without waiting until 5105
        fakeNow = 5_065.0
        #expect(scheduler.sweep() == ["DiscordMessagePoller"])
        #expect(pollCount == 3)
    }

    @Test("Before/after wake-up count evidence and timer site inventory completeness")
    func beforeAfterWakeupReductionAndInventory() {
        let discordPolicy = PollPolicy(baseInterval: 15.0, minInterval: 15.0, maxInterval: 120.0)
        // Over a 10-minute (600s) idle window:
        // Legacy fixed 15s poller wakes up 40 times.
        // Adaptive poller (15 + 30 + 60 + 120 + 120 + 120 + 120 = 585s) wakes up only 7 times (>80% reduction).
        let comparison = discordPolicy.compareWakeupCounts(windowSeconds: 600.0, idlePollStreak: true)
        #expect(comparison.legacyWakeups == 40)
        #expect(comparison.adaptiveWakeups == 7)
        #expect(comparison.adaptiveWakeups < comparison.legacyWakeups / 4)

        // Verify classified site inventory covers all TimerSiteCategory cases
        let categoriesCovered = Set(TickerScheduler.siteInventory.map(\.category))
        for category in TimerSiteCategory.allCases {
            #expect(categoriesCovered.contains(category))
        }
    }
}
