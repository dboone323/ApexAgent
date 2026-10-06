import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("DurableAutomationReceiptTests")
struct DurableAutomationReceiptTests {

    @Test func routineStableUUIDDeterministic() {
        let routine1 = Routine(name: "Nightly Audit", descriptionText: "audit codebase")
        let routine2 = Routine(name: "Nightly Audit", descriptionText: "different prompt")
        let routine3 = Routine(name: "Morning Brief", descriptionText: "morning summary")

        #expect(routine1.stableUUID == routine2.stableUUID)
        #expect(routine1.stableUUID != routine3.stableUUID)
    }

    @Test func routineRunDurationFormatting() {
        let now = Date()
        var run = RoutineRun(
            routineId: UUID(),
            routineName: "Test Run",
            prompt: "do work",
            status: .running,
            startedAt: now
        )
        #expect(run.formattedDuration == "Running...")

        // Subsecond duration
        run.finishedAt = now.addingTimeInterval(0.35)
        #expect(run.formattedDuration == "350 ms")

        // Multi-second duration
        run.finishedAt = now.addingTimeInterval(12.4)
        #expect(run.formattedDuration == "12.4 s")

        // Multi-minute duration
        run.finishedAt = now.addingTimeInterval(135.0)
        #expect(run.formattedDuration == "2m 15s")
    }

    @Test func routineManagerRecordsAndFiltersReceipts() {
        let manager = RoutineManager.shared
        manager.clearRuns()
        #expect(manager.recentRuns.isEmpty)

        let routineId1 = UUID()
        let routineId2 = UUID()

        let run1 = RoutineRun(
            routineId: routineId1,
            routineName: "Build Check",
            prompt: "check build",
            status: .completed,
            startedAt: Date().addingTimeInterval(-10),
            finishedAt: Date(),
            output: "Build clean: 0 warnings"
        )
        let run2 = RoutineRun(
            routineId: routineId2,
            routineName: "Lint Code",
            prompt: "lint code",
            status: .failed,
            startedAt: Date().addingTimeInterval(-5),
            finishedAt: Date(),
            output: nil,
            error: "2 lint violations found"
        )

        manager.recordRun(run1)
        manager.recordRun(run2)

        #expect(manager.recentRuns.count == 2)
        #expect(manager.runReceipts(for: routineId1).count == 1)
        #expect(manager.runReceipts(for: routineId1).first?.routineName == "Build Check")
        #expect(manager.runReceipts(for: routineId2).count == 1)
        #expect(manager.runReceipts(for: routineId2).first?.error == "2 lint violations found")

        // Updating an existing run replaces in place
        var updatedRun2 = run2
        updatedRun2.status = .completed
        updatedRun2.output = "Violations fixed"
        updatedRun2.error = nil
        manager.recordRun(updatedRun2)

        #expect(manager.recentRuns.count == 2)
        #expect(manager.runReceipts(for: routineId2).first?.status == .completed)
        #expect(manager.runReceipts(for: routineId2).first?.output == "Violations fixed")

        // Cleanup
        manager.clearRuns()
        #expect(manager.recentRuns.isEmpty)
    }
}
