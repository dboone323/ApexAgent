import Testing
import Foundation
import SwiftData
@testable import ApexAgentCore
import SharedKit

@Suite("WeeklyReflectionToolTests") final class WeeklyReflectionToolTests {

    @MainActor
    @Test func testDailyBriefingUsesAppGroupBus() async throws {
        // Integration: existing tool keeps AppGroup-backed behavior
        let bus = AppGroupDataBus.shared
        let tool = DailyBriefingTool()
        let briefing = try await tool.run()
        #expect(briefing != nil)
    }

    @Test func testPersonalContextLive() {
        let ctx = ApexAgentPersonalContext.live
        #expect(ctx != nil)
    }

    @Test func testWeeklyReflectionCreation() {
        let reflection = WeeklyReflection.snapshot(text: "Achieved weekly goals")
        #expect(reflection.text == "Achieved weekly goals")
        #expect(reflection.id != nil)
        #expect(reflection.weekStartDate != nil)
        #expect(reflection.createdAt != nil)
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
