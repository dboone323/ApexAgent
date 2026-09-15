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

        let unauthorizedResult = try await researcherSession.executeTool(
            name: "run_shell_command",
            arguments: "{\"command\": \"ls -la\"}"
        )

        // 2. Create an Automator bot with system automation tools allowed
        let automator = botManager.createBot(
            name: "System Automator",
            title: "Automator",
            descriptionText: "Automate desktop actions."
        )
        automator.allowedToolNames = ["notification_tool", "system_info", "take_screenshot"]
        let automatorSession = botManager.session(for: automator)

        let automatorUnauthorized = try await automatorSession.executeTool(
            name: "delete_file",
            arguments: "{\"path\": \"/tmp/test.txt\"}"
        )

        TestActivity.step("Assert unauthorized tool calls are rejected per least-privilege policy") { _ in
            XCTAssertTrue(unauthorizedResult.contains("ERROR: Tool 'run_shell_command' is not permitted for bot 'Restricted Researcher' under least-privilege security policy."))
            XCTAssertTrue(automatorUnauthorized.contains("ERROR: Tool 'delete_file' is not permitted for bot 'System Automator' under least-privilege security policy."))
        }
    }

    func testExplicitQuarantineDeniesAllTools() async throws {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)

        let quarantinedBot = botManager.createBot(
            name: "Quarantined Bot",
            title: "Isolated Sandbox",
            descriptionText: "Zero permissions bot."
        )
        // Explicit non-empty allowlist containing no usable tools
        quarantinedBot.allowedToolNames = ["none"]
        let session = botManager.session(for: quarantinedBot)

        let result = try await session.executeTool(
            name: "read_file",
            arguments: "{\"path\": \"/tmp/safe.txt\"}"
        )

        TestActivity.step("Assert explicitly quarantined bot is denied tool execution") { _ in
            XCTAssertTrue(result.contains("is not permitted for bot 'Quarantined Bot' under least-privilege security policy."))
        }
    }

    func testAuthorizedToolExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)

        let readerBot = botManager.createBot(
            name: "Allowed Reader",
            title: "File Reader",
            descriptionText: "Authorized to read files."
        )
        readerBot.allowedToolNames = ["read_file"]
        let session = botManager.session(for: readerBot)

        let testFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rbac_test_\(UUID().uuidString).txt")
        try "RBAC_AUTHORIZED_CONTENT".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let result = try await session.executeTool(
            name: "read_file",
            arguments: "{\"path\": \"\(testFile.path)\"}"
        )

        TestActivity.step("Assert authorized tool successfully executes and returns content") { _ in
            XCTAssertTrue(result.contains("RBAC_AUTHORIZED_CONTENT"), "Authorized tool must succeed and return content")
        }
    }

    func testConcurrentMultiBotRBACIsolation() async throws {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)

        let botA = botManager.createBot(name: "BotA", title: "A", descriptionText: "A")
        botA.allowedToolNames = ["read_file"]
        let sessionA = botManager.session(for: botA)

        let botB = botManager.createBot(name: "BotB", title: "B", descriptionText: "B")
        botB.allowedToolNames = ["system_info"]
        let sessionB = botManager.session(for: botB)

        async let resultA = sessionA.executeTool(name: "system_info", arguments: "{}")
        async let resultB = sessionB.executeTool(name: "read_file", arguments: "{\"path\": \"/tmp/dummy\"}")

        let (resA, resB) = try await (resultA, resultB)

        TestActivity.step("Assert concurrent requests maintain distinct per-bot RBAC isolation") { _ in
            XCTAssertTrue(resA.contains("ERROR: Tool 'system_info' is not permitted for bot 'BotA'"))
            XCTAssertTrue(resB.contains("ERROR: Tool 'read_file' is not permitted for bot 'BotB'"))
        }
    }
}
