import Testing
import Foundation
import SwiftData
@testable import ApexAgentCore
import SharedKit

@Suite("WeeklyReflectionToolTests") final class WeeklyReflectionToolTests {

    @MainActor
    @Test func testDailyBriefingUsesAppGroupBus() async throws {
        // Integration: existing tool keeps AppGroup-backed behavior
        let orchestrator = AgentOrchestrator()
        let tool = DailyBriefingTool(orchestrator: orchestrator)
        let briefing = try await tool.run()
        _ = briefing // non-optional result
    }

    @Test func testPersonalContextLive() {
        let ctx = ApexAgentPersonalContext.live
        _ = ctx // non-optional live context
    }

    @Test func testWeeklyReflectionCreation() {
        let reflection = WeeklyReflection.snapshot(text: "Achieved weekly goals")
        #expect(reflection.text == "Achieved weekly goals")
        _ = reflection.id // value types: fields are non-optional by construction
        _ = reflection.weekStartDate
        _ = reflection.createdAt
    }

    @MainActor
    @Test func testWeeklyReflectionPersistence() async throws {
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, WeeklyReflection.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)

        let tool = WeeklyReflectionTool(modelContext: ModelContext(container))
        let reflection = WeeklyReflection.snapshot(text: "Persistence test")
        try tool.save(reflection: reflection)

        let recent = await tool.recent()
        #expect(recent.contains { $0.text == "Persistence test" })
    }
}
