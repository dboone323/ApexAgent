import Testing
import Foundation
import FoundationModels
import AppKit
@testable import ApexAgentCore

// MARK: - WS2: Teach-a-task RoutineRecorder (Grok Bot "show a Bot how it's done")

@MainActor
@Suite("RoutineRecorderTests")
struct RoutineRecorderTests {

    @Test func recorderIgnoresCapturesWhenIdle() {
        let recorder = RoutineRecorder()
        recorder.captureShell("echo hi")
        #expect(recorder.steps.isEmpty)
        #expect(!recorder.hasSteps)
    }

    @Test func startStopCapturesTypedSteps() {
        let recorder = RoutineRecorder()
        recorder.start()
        recorder.captureShell("open ~/project")
        recorder.captureAppleScript("tell app \"Safari\" to activate")
        recorder.captureNote("then approve the build")
        let steps = recorder.stop()
        #expect(steps.count == 3)
        #expect(recorder.steps.map(\.action) == ["shell", "applescript", "note"])
        #expect(recorder.isRecording == false)
    }

    @Test func stopKeepsRecordingSessionForReview() {
        let recorder = RoutineRecorder()
        recorder.start()
        recorder.captureShell("ls")
        recorder.stop()
        #expect(recorder.hasSteps)
        #expect(recorder.recipeText().contains("1. [shell] ls"))
    }

    @Test func undoRemovesLastStep() {
        let recorder = RoutineRecorder()
        recorder.start()
        recorder.captureShell("one")
        recorder.captureShell("two")
        recorder.undo()
        #expect(recorder.steps.count == 1)
        #expect(recorder.steps.first?.detail == "one")
    }

    @Test func makeRoutineRendersNumberedRecipe() {
        let recorder = RoutineRecorder()
        recorder.start()
        recorder.captureShell("open ~/project")
        recorder.captureNote("wait for build")
        recorder.stop()
        let routine = recorder.makeRoutine(named: "weekly-report")
        #expect(routine != nil)
        #expect(routine?.descriptionText.contains("1. [shell] open ~/project") == true)
        #expect(routine?.descriptionText.contains("2. [note] wait for build") == true)
    }

    @Test func makeRoutineRoutesToTargetBot() {
        let recorder = RoutineRecorder()
        recorder.start()
        recorder.captureShell("ls")
        recorder.stop()
        let routine = recorder.makeRoutine(named: "r", targetBot: "Ops")
        #expect(routine?.descriptionText.hasPrefix("Ops: ") == true)
    }

    @Test func makeRoutineNilWhenNothingRecorded() {
        let recorder = RoutineRecorder()
        #expect(recorder.makeRoutine(named: "x") == nil)
    }
}

// MARK: - WS6: Group chat takes real work (Grok Bot "group chat that acts")

@MainActor
@Suite("GroupChatActionTests")
struct GroupChatActionTests {

    private func makeGroup() -> GroupChatSession {
        let a = BotProfile(name: "Research")
        let b = BotProfile(name: "Comms")
        return GroupChatSession(name: "Launch", participants: [a, b])
    }

    @Test func allowedToolsArePermitted() {
        let group = makeGroup()
        #expect(group.groupToolPermission(tool: "web_search") == .allowed)
        #expect(group.groupToolPermission(tool: "read_file") == .allowed)
        #expect(group.groupToolPermission(tool: "get_system_info") == .allowed)
    }

    @Test func disallowedToolsAreDenied() {
        let group = makeGroup()
        if case .denied(let reason) = group.groupToolPermission(tool: "run_shell_command") {
            #expect(reason.contains("not an allowed group tool"))
        } else {
            Issue.record("expected shell to be denied in group chat")
        }
    }

    @Test func disablingToolCallsGatesEverything() {
        let group = makeGroup()
        group.toolCallsEnabled = false
        if case .denied(let reason) = group.groupToolPermission(tool: "web_search") {
            #expect(reason.contains("disabled"))
        } else {
            Issue.record("expected group tool calls to be disabled")
        }
    }

    @Test func riskyToolRequiresApprovalEvenWhenAllowed() {
        let group = makeGroup()
        group.allowedGroupTools = ["run_shell_command"]
        #expect(group.groupToolPermission(tool: "run_shell_command") == .needsApproval)
    }

    @Test func approvalDeclinedWithoutOrchestrator() async {
        let group = makeGroup()
        group.allowedGroupTools = ["run_shell_command"]
        let out = try? await group.executeGroupTool(tool: "run_shell_command", arguments: "{}")
        #expect(out?.hasPrefix("DECLINED:") == true)
    }

    @Test func deniedToolNeverReachesOrchestrator() async {
        let group = makeGroup()
        let out = try? await group.executeGroupTool(tool: "write_file", arguments: "{}")
        #expect(out?.hasPrefix("DENIED:") == true)
    }

    @Test func allowedToolWithoutOrchestratorErrorsCleanly() async {
        let group = makeGroup()
        let out = try? await group.executeGroupTool(tool: "web_search", arguments: "{\"query\":\"x\"}")
        #expect(out?.hasPrefix("ERROR:") == true)
    }

    @Test func defaultAllowlistExcludesShellAndWrites() {
        #expect(DefaultGroupToolAllowlist.set.contains("run_shell_command") == false)
        #expect(DefaultGroupToolAllowlist.set.contains("write_file") == false)
        #expect(DefaultGroupToolAllowlist.set.contains("delete_file") == false)
    }
}

// MARK: - Group tool permission badges & allowlist probe

@Suite("GroupToolPermissionTests")
struct GroupToolPermissionTests {
    @Test func groupToolPermissionBadges() {
        #expect(GroupToolPermission.allowed.badge.contains("Allowed"))
        #expect(GroupToolPermission.allowed.isActionable)
        #expect(GroupToolPermission.needsApproval.isActionable)
        if case .denied(let r) = GroupToolPermission.denied(reason: "x") {
            #expect(r == "x")
        } else { Issue.record("expected denied") }
        #expect(!GroupToolPermission.denied(reason: "x").isActionable)
    }

    @Test func groupAllowlistProbe() {
        #expect(DefaultGroupToolAllowlist.isAllowed("web_search"))
        #expect(!DefaultGroupToolAllowlist.isAllowed("run_shell_command"))
    }
}
