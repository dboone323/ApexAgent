import Testing
import Foundation
@testable import ApexAgentCore
import SharedModels

@Suite("Batch 2: AppGroupDataBus Tests")
@MainActor
struct AppGroupDataBusTests {

    private func resetDataBus() {
        let defaults = UserDefaults(suiteName: AppGroupDataBus.appGroupIdentifier) ?? .standard
        defaults.removeObject(forKey: "apex.databus.sharedTasks")
        defaults.removeObject(forKey: "apex.databus.todayMood")
        defaults.removeObject(forKey: "apex.databus.budgetAlertStatus")
        defaults.removeObject(forKey: "apex.databus.habitCompletionCount")
        defaults.removeObject(forKey: "apex.databus.activePowerUp")
    }

    @Test("App group identifier constant is group.com.apexagent")
    func testAppGroupIdentifierConstant() {
        #expect(AppGroupDataBus.appGroupIdentifier == "group.com.apexagent")
    }

    @Test("Fallback behavior when App Group entitlement is absent")
    func testFallbackToStandardDefaults() {
        resetDataBus()
        defer { resetDataBus() }

        let bus = AppGroupDataBus.shared
        #expect(bus.sharedTasks.isEmpty)
        #expect(bus.todayMood == nil)
        #expect(bus.budgetAlertStatus == nil)
        #expect(bus.habitCompletionCount == 0)
        #expect(bus.activePowerUp == false)
    }

    @Test("Shared tasks array JSON serialization roundtrip")
    func testSharedTasksRoundtrip() {
        resetDataBus()
        defer { resetDataBus() }

        let bus = AppGroupDataBus.shared
        let task1 = SharedTask(
            id: UUID(),
            title: "Security Boundary Audit",
            detail: "Verify strict isolation",
            status: "in_progress",
            priority: "high"
        )
        let task2 = SharedTask(
            id: UUID(),
            title: "Memory Compaction",
            detail: "Archive inactive turns",
            status: "pending",
            priority: "normal"
        )

        bus.update(tasks: [task1, task2])

        let fetched = bus.sharedTasks
        #expect(fetched.count == 2)
        #expect(fetched[0] == task1)
        #expect(fetched[1] == task2)
    }

    @Test("Individual field updates update backing store correctly")
    func testIndividualFieldUpdates() {
        resetDataBus()
        defer { resetDataBus() }

        let bus = AppGroupDataBus.shared

        bus.update(mood: "energized")
        #expect(bus.todayMood == "energized")

        bus.update(budgetAlertStatus: "threshold_85_percent")
        #expect(bus.budgetAlertStatus == "threshold_85_percent")

        bus.update(habitCompletionCount: 4)
        #expect(bus.habitCompletionCount == 4)

        bus.update(activePowerUp: true)
        #expect(bus.activePowerUp == true)
    }

    @Test("Bulk update updates all fields simultaneously")
    func testBulkUpdate() {
        resetDataBus()
        defer { resetDataBus() }

        let bus = AppGroupDataBus.shared
        let sampleTask = SharedTask(
            id: UUID(),
            title: "Doctor Expansion",
            detail: "Verify 12 checks",
            status: "completed",
            priority: "urgent"
        )

        bus.update(
            tasks: [sampleTask],
            mood: "focused",
            budgetAlertStatus: "nominal",
            habitCompletionCount: 12,
            activePowerUp: true
        )

        #expect(bus.sharedTasks == [sampleTask])
        #expect(bus.todayMood == "focused")
        #expect(bus.budgetAlertStatus == "nominal")
        #expect(bus.habitCompletionCount == 12)
        #expect(bus.activePowerUp == true)
    }

    @Test("Clean state isolation verifies reset removes all values")
    func testCleanStateIsolation() {
        resetDataBus()
        let bus = AppGroupDataBus.shared
        bus.update(mood: "temporary")
        bus.update(habitCompletionCount: 99)
        #expect(bus.todayMood == "temporary")
        #expect(bus.habitCompletionCount == 99)

        resetDataBus()
        #expect(bus.todayMood == nil)
        #expect(bus.habitCompletionCount == 0)
    }
}
