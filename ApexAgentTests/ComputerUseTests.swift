import Testing
import Foundation
@testable import ApexAgentCore

@Suite("ComputerUseTests")
@MainActor
struct ComputerUseTests {

    @Test("ComputerAction humanReadableSummary formats correctly for all action cases")
    func testComputerActionSummaries() {
        #expect(ComputerAction.click(x: 100, y: 200).humanReadableSummary == "click at (100, 200)")
        #expect(ComputerAction.doubleClick(x: 50, y: 75).humanReadableSummary == "double-click at (50, 75)")
        #expect(ComputerAction.type(text: "Hello World").humanReadableSummary == "type 'Hello World'")
        #expect(ComputerAction.keyCombo(keys: ["command", "shift", "p"]).humanReadableSummary == "key combo: command+shift+p")
        #expect(ComputerAction.scroll(deltaX: 0, deltaY: -10).humanReadableSummary == "scroll by (0, -10)")
        #expect(ComputerAction.openApp(name: "Safari").humanReadableSummary == "open app: Safari")
        #expect(ComputerAction.wait(seconds: 2.5).humanReadableSummary == "wait 2.5s")
        #expect(ComputerAction.finish(result: "Task completed successfully").humanReadableSummary.hasPrefix("finish: Task completed"))
        #expect(ComputerAction.fail(reason: "Element not found on screen").humanReadableSummary.hasPrefix("fail: Element not found"))
    }

    @Test("ComputerUseStep records step properties accurately")
    func testComputerUseStepModel() {
        let action = ComputerAction.click(x: 300, y: 400)
        let step = ComputerUseStep(turn: 2, action: action, observation: "Clicked at (300, 400)")

        #expect(step.turn == 2)
        #expect(step.action == action)
        #expect(step.observation == "Clicked at (300, 400)")
        #expect(step.timestamp.timeIntervalSince1970 > 0)
    }

    @Test("ApprovalPolicy correctly evaluates computer_use actions under localScope")
    func testApprovalPolicyForComputerUse() {
        // Safe actions with autoApprove=true should approve
        let safeVerdict = ApprovalPolicy.verdict(
            tool: "computer_use",
            summary: "click at (100, 200)",
            autoApprove: true,
            localScope: true
        )
        #expect(safeVerdict.approve != nil)

        // Without autoApprove, localScope requires confirmation (verdict.approve == nil)
        let unapprovedVerdict = ApprovalPolicy.verdict(
            tool: "computer_use",
            summary: "click at (100, 200)",
            autoApprove: false,
            localScope: true
        )
        #expect(unapprovedVerdict.approve == nil)

        // Destructive summary must be blocked regardless of autoApprove
        let destructiveVerdict = ApprovalPolicy.verdict(
            tool: "computer_use",
            summary: "rm -rf /",
            autoApprove: true,
            localScope: true
        )
        #expect(destructiveVerdict.approve == nil)
        #expect(destructiveVerdict.source == .destructiveGuard)
    }

    @Test("ComputerUseAgent executes non-destructive wait and finish actions")
    func testExecuteBenignActions() async throws {
        let waitResult = try await ComputerUseAgent.shared.executeAction(.wait(seconds: 0.01))
        #expect(waitResult.contains("0.01"))

        let finishResult = try await ComputerUseAgent.shared.executeAction(.finish(result: "All done"))
        #expect(finishResult == "Finished with result: All done")

        let failResult = try await ComputerUseAgent.shared.executeAction(.fail(reason: "Resource missing"))
        #expect(failResult == "Failed: Resource missing")
    }

    @Test("ComputerUseAgent runLoop completes multi-turn loop with decisionProvider")
    func testRunLoopExecution() async throws {
        var recordedSteps: [ComputerUseStep] = []

        let result = try await ComputerUseAgent.shared.runLoop(
            goal: "Test perception loop",
            decisionProvider: { goal, history in
                if history.isEmpty {
                    return .wait(seconds: 0.01)
                } else {
                    return .finish(result: "Goal accomplished: \(goal)")
                }
            },
            autoApprove: true,
            onUpdate: { step in
                recordedSteps.append(step)
            }
        )

        #expect(result.contains("Goal accomplished"))
        #expect(recordedSteps.count == 2)
        #expect(recordedSteps[0].turn == 0)
        #expect(recordedSteps[1].turn == 1)
        #expect(ComputerUseAgent.shared.history.count == 2)
        #expect(!ComputerUseAgent.shared.isRunning)
    }

    @Test("ComputerUseAgent accessibility permission check returns valid boolean")
    func testAccessibilityPermissionCheck() {
        let trusted = ComputerUseAgent.hasAccessibilityPermission
        // Verify property evaluates cleanly
        #expect(trusted == true || trusted == false)
    }
}

// MARK: - Markdown projection for computer-use steps

@Suite("ComputerUseMarkdownTests")
struct ComputerUseMarkdownTests {
    @Test func computerUseStepMarkdown() {
        let step = ComputerUseStep(turn: 1, action: .click(x: 10, y: 20), observation: "ok")
        let md = step.formatAsMarkdown()
        #expect(md.contains("click at"))
    }
}
