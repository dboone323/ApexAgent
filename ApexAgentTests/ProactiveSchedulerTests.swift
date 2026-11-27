import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Markdown projection for proactive findings

@Suite("ProactiveFindingMarkdownTests")
struct ProactiveFindingMarkdownTests {
    @Test @MainActor func proactiveFindingMarkdown() {
        let f = ProactiveScheduler.ProactiveFinding(title: "T", detail: "D", severity: .warning)
        let md = f.formatAsMarkdown()
        #expect(md.contains("Warning"))
    }

    @Test @MainActor func testDismissedFailedHandoffDoesNotResurfaceOnEvaluateNow() async {
        let failedHandoff = TaskResult(
            taskId: "handoff-empty-afm-\(UUID().uuidString)",
            status: "failed",
            resultSummary: "All available providers failed.",
            errorDetails: "Apple Intelligence (AFM 3 On-Device) produced an empty response."
        )
        let scheduler = ProactiveScheduler(handoffsProvider: { [failedHandoff] })

        let firstFindings = await scheduler.evaluateNow()
        #expect(firstFindings.count == 1)
        #expect(firstFindings.first?.title == "Agent Task Failed")
        #expect(firstFindings.first?.severity == .critical)

        if let findingId = firstFindings.first?.id {
            scheduler.dismissFinding(id: findingId)
        }
        #expect(scheduler.activeFindings.isEmpty)
        #expect(scheduler.formatFindingsAsMarkdown().contains("All agent operations are healthy"))

        let secondFindings = await scheduler.evaluateNow()
        #expect(secondFindings.isEmpty)
        #expect(scheduler.activeFindings.isEmpty)
    }

    @Test @MainActor func testAddFindingFormatsMarkdownAndDismissByIdRestoresHealthyState() {
        let scheduler = ProactiveScheduler(handoffsProvider: { [] })
        let finding = ProactiveScheduler.ProactiveFinding(
            title: "Queue Backpressure",
            detail: "Pending work items exceeded threshold",
            severity: .warning,
            targetBotName: "executor"
        )

        scheduler.addFinding(finding)
        #expect(scheduler.activeFindings.count == 1)

        let activeMd = scheduler.formatFindingsAsMarkdown()
        #expect(activeMd.contains("Queue Backpressure"))
        #expect(activeMd.contains("Pending work items exceeded threshold"))
        #expect(activeMd.contains("`@executor`"))

        scheduler.dismissFinding(id: finding.id)
        #expect(scheduler.activeFindings.isEmpty)
        #expect(scheduler.formatFindingsAsMarkdown().contains("All agent operations are healthy"))
    }

    @Test @MainActor func testClearAllFindingsResetsActiveAndManualFindings() async {
        let failedHandoff = TaskResult(
            taskId: "handoff-clear-guard-\(UUID().uuidString)",
            status: "failed",
            resultSummary: "Provider timeout",
            errorDetails: "Request timed out"
        )
        let scheduler = ProactiveScheduler(handoffsProvider: { [failedHandoff] })
        _ = await scheduler.evaluateNow()

        let manual = ProactiveScheduler.ProactiveFinding(
            title: "Manual Alert",
            detail: "Operator flagged check",
            severity: .info
        )
        scheduler.addFinding(manual)
        #expect(scheduler.activeFindings.count == 2)

        scheduler.clearAllFindings()
        #expect(scheduler.activeFindings.isEmpty)
        #expect(scheduler.formatFindingsAsMarkdown().contains("All agent operations are healthy"))

        let afterClear = await scheduler.evaluateNow()
        #expect(afterClear.isEmpty)
        #expect(scheduler.activeFindings.isEmpty)
    }
}
