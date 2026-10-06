import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("GroupChatEngineRoutingTests")
struct GroupChatEngineRoutingTests {

    @Test func groupChatSessionCreatesWithParticipants() {
        let bot1 = BotProfile(name: "Alice", title: "Researcher")
        let bot2 = BotProfile(name: "Bob", title: "Developer")
        let group = GroupChatSession(name: "Research Team", participants: [bot1, bot2])
        #expect(group.participants.count == 2)
        #expect(group.generationOrder.count == 2)
        #expect(group.name == "Research Team")
    }

    @Test func groupToolPermissionAllowsWhitelistedTools() {
        let group = GroupChatSession(
            name: "Test",
            participants: [BotProfile(name: "A"), BotProfile(name: "B")]
        )
        #expect(group.groupToolPermission(tool: "web_search") == .allowed)
        #expect(group.groupToolPermission(tool: "read_file") == .allowed)
        #expect(group.groupToolPermission(tool: "list_directory") == .allowed)
    }

    @Test func groupToolPermissionDeniesUnlistedTools() {
        let group = GroupChatSession(
            name: "Test",
            participants: [BotProfile(name: "A"), BotProfile(name: "B")]
        )
        let permission = group.groupToolPermission(tool: "run_shell_command")
        #expect(permission != .allowed)
    }

    @Test func groupToolPermissionDeniesWhenDisabled() {
        let group = GroupChatSession(
            name: "Test",
            participants: [BotProfile(name: "A"), BotProfile(name: "B")]
        )
        group.toolCallsEnabled = false
        if case .denied(let reason) = group.groupToolPermission(tool: "web_search") {
            #expect(reason.contains("disabled"))
        } else {
            Issue.record("Expected denied when tools disabled")
        }
    }
}
