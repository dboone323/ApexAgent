import Testing
import Foundation
@testable import ApexAgentCore

@Suite("RoutineCronModelTests")
struct RoutineCronModelTests {
    @Test("Routine model initialization with .cron trigger and cronExpression")
    func testRoutineCronModel() {
        let routine = Routine(
            name: "Daily Sync",
            descriptionText: "Sync git repo daily",
            trigger: .cron,
            cronExpression: "0 12 * * *"
        )
        
        #expect(routine.trigger == .cron)
        #expect(routine.cronExpression == "0 12 * * *")
    }
    
    @Test("routine.effectiveScheduleDescription returns the cron description")
    func testEffectiveScheduleDescription() {
        let routine = Routine(
            name: "Nightly Build",
            descriptionText: "Run nightly build",
            trigger: .cron,
            cronExpression: "0 0 * * *"
        )
        
        #expect(routine.effectiveScheduleDescription.contains("0 0 * * *") || routine.effectiveScheduleDescription.contains("midnight") || routine.effectiveScheduleDescription.contains("Cron"))
    }
}
