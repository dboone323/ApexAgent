import XCTest
@testable import ApexAgentCore
import SwiftData

@MainActor
final class BotSecurityRBACPermissionTests: XCTestCase {

    func testPerBotLeastPrivilegeToolAllowlistEnforcement() async throws {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)

        // 1. Create a Researcher bot restricted only to read and web search
        let researcher = botManager.createBot(
            name: "Restricted Researcher",
            title: "Research Specialist",
            descriptionText: "Perform web search and documentation lookups."
        )
        researcher.allowedToolNames = ["web_search", "read_file", "list_directory"]

        let researcherSession = botManager.session(for: researcher)

        // 2. Attempt to execute an unauthorized tool (e.g. run_shell_command)
        let unauthorizedResult = try await researcherSession.executeTool(
            name: "run_shell_command",
            arguments: "{\"command\": \"ls -la\"}"
        )
        XCTAssertTrue(unauthorizedResult.contains("ERROR: Tool 'run_shell_command' is not permitted for bot 'Restricted Researcher' under least-privilege security policy."))

        // 3. Create an Automator bot with system automation tools allowed
        let automator = botManager.createBot(
            name: "System Automator",
            title: "Automator",
            descriptionText: "Automate desktop actions."
        )
        automator.allowedToolNames = ["notification_tool", "system_info", "take_screenshot"]
        let automatorSession = botManager.session(for: automator)

        // Attempting an unauthorized file modification tool on automator fails
        let automatorUnauthorized = try await automatorSession.executeTool(
            name: "delete_file",
            arguments: "{\"path\": \"/tmp/test.txt\"}"
        )
        XCTAssertTrue(automatorUnauthorized.contains("ERROR: Tool 'delete_file' is not permitted for bot 'System Automator' under least-privilege security policy."))
    }
}
