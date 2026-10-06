import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O5: Routine webhook trigger + run receipts

@Suite("RoutineWebhookAndRunTests")
struct RoutineWebhookAndRunTests {

    @Test func routineTriggerGainsWebhook() {
        #expect(RoutineTrigger.webhook.rawValue == "Webhook")
        #expect(RoutineTrigger.allCases.contains(.webhook))
    }

    @Test func routineRunStatusLifecycle() {
        var run = RoutineRun(routineId: UUID(), routineName: "nightly", prompt: "p")
        #expect(run.status.isActive)
        run.status = .running
        #expect(run.status.isActive)
        run.status = .completed
        #expect(!run.status.isActive)
        run.finishedAt = Date()
        #expect(run.finishedAt != nil)
    }

    @Test func routineRunCodableRoundTrip() throws {
        let run = RoutineRun(
            routineId: UUID(), routineName: "webhook-job", prompt: "p",
            trigger: .webhook, status: .queued
        )
        let data = try JSONEncoder().encode(run)
        let back = try JSONDecoder().decode(RoutineRun.self, from: data)
        #expect(back.routineName == "webhook-job")
        #expect(back.trigger == .webhook)
        #expect(back.status == .queued)
    }

    @Test func routineRunSnapshotsPrompt() {
        let run = RoutineRun(routineId: UUID(), routineName: "r", prompt: "original")
        #expect(run.prompt == "original")
        #expect(run.routineId != run.id)
    }
}
