import Testing
import Foundation
import FoundationModels
import AppKit
@testable import ApexAgentCore

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

    @Test func turnProgressMarkdownReportsParticipantsAndIdleState() {
        let group = makeGroup()
        let md = group.turnProgressMarkdown()
        #expect(md.contains("Group Chat `Launch`"))
        #expect(md.contains("| Participants | `2` |"))
        #expect(md.contains("Idle"))
    }
}
