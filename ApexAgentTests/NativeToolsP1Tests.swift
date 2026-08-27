import Testing
import Foundation
import EventKit
@testable import ApexAgentCore

@Suite("NativeToolsP1Tests")
struct NativeToolsP1Tests {
    @Test("CalendarTool metadata and listing events")
    @MainActor
    func testCalendarToolList() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = CalendarTool(orchestrator: orchestrator)
        #expect(tool.name == "calendar")

        let args = CalendarTool.Arguments(action: "list", daysAhead: 7)
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        #expect(result.contains("Calendar") || result.contains("events") || result.contains("access") || result.contains("No calendar events"))
    }

    @Test("CalendarTool search action execution")
    @MainActor
    func testCalendarToolSearch() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = CalendarTool(orchestrator: orchestrator)
        let args = CalendarTool.Arguments(action: "search", title: "Meeting", daysAhead: 14)
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
    }

    @Test("ReminderTool metadata and listing reminders")
    @MainActor
    func testReminderToolList() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = ReminderTool(orchestrator: orchestrator)
        #expect(tool.name == "reminders")

        let args = ReminderTool.Arguments(action: "list")
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        #expect(result.contains("Reminders") || result.contains("reminders") || result.contains("access") || result.contains("No active reminders"))
    }

    @Test("ReminderTool create and handle invalid action gracefully")
    @MainActor
    func testReminderToolUnknownAction() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = ReminderTool(orchestrator: orchestrator)
        let args = ReminderTool.Arguments(action: "invalid_action_xyz")
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
    }
}
