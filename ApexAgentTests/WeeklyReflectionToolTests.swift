import XCTest
@testable import ApexAgent
import SharedKit

final class WeeklyReflectionToolTests: XCTestCase {

    func testDailyBriefingUsesAppGroupBus() throws {
        // Integration: existing tool keeps AppGroup-backed behavior
        let bus = AppGroupDataBus.shared
        let tool = DailyBriefingTool()
        let briefing = try await tool.run()
        XCTAssertNotNil(briefing)
    }

    func testPersonalContextLive() {
        let ctx = ApexAgentPersonalContext.live
        XCTAssertNotNil(ctx)
    }

    func testWeeklyReflectionCreation() {
        let reflection = WeeklyReflection.snapshot(text: "Achieved weekly goals")
        XCTAssertEqual(reflection.text, "Achieved weekly goals")
        XCTAssertNotNil(reflection.id)
        XCTAssertNotNil(reflection.weekStartDate)
        XCTAssertNotNil(reflection.createdAt)
    }

    @MainActor
    func testWeeklyReflectionPersistence() async throws {
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, WeeklyReflection.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)

        let tool = WeeklyReflectionTool(modelContext: ModelContext(container))
        let reflection = WeeklyReflection.snapshot(text: "Persistence test")
        try tool.save(reflection: reflection)

        let recent = await tool.recent()
        XCTAssertTrue(recent.contains { $0.text == "Persistence test" })
    }
}
