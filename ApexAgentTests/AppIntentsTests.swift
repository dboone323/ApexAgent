import XCTest
import AppIntents
@testable import ApexAgentCore

@MainActor
final class AppIntentsTests: XCTestCase {

    func testTriggerRoutineIntentValidation() async {
        let emptyIntent = TriggerRoutineIntent(routineName: "   ")
        do {
            _ = try await emptyIntent.perform()
            XCTFail("Empty routine name should throw error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Routine name cannot be empty"))
        }
    }

    func testInspectAgentStatusIntentExecution() async throws {
        let statusIntent = InspectAgentStatusIntent()
        let result = try await statusIntent.perform()
        guard let value = result.value else {
            XCTFail("Missing return value in statusIntent")
            return
        }

        XCTAssertTrue(value.contains("ApexAgent Status: UNAVAILABLE (no bot manager)") || value.contains("ApexAgent Status: ONLINE"), "Status report must indicate availability")
        XCTAssertTrue(value.contains("Active Bots:"), "Status report must include bot count")
        XCTAssertTrue(value.contains("Registered Routines:"), "Status report must include routine count")
    }

    func testExecutePlaybookIntentPresets() async throws {
        let prIntent = ExecutePlaybookIntent(preset: "pr_review")
        XCTAssertEqual(prIntent.preset, "pr_review")

        let issueIntent = ExecutePlaybookIntent(preset: "issue_to_patch")
        XCTAssertEqual(issueIntent.preset, "issue_to_patch")

        let standupIntent = ExecutePlaybookIntent(preset: "standup")
        XCTAssertEqual(standupIntent.preset, "standup")

        // Perform standup intent (non-blocking validation)
        let result = try await standupIntent.perform()
        guard let value = result.value else {
            XCTFail("Missing return value in standupIntent")
            return
        }
        XCTAssertTrue(value.contains("Weekly Standup & Retrospective"), "Result should confirm execution")
    }
}
