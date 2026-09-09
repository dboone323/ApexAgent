import XCTest
@testable import ApexAgentCore

final class AgentAuditLoggerTests: XCTestCase {

    func testCryptographicAuditChainAndTamperVerification() async {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_audit_\(UUID().uuidString).jsonl")
        let logger = AgentAuditLogger(customFileURL: tempURL)

        // 1. Log sequential events
        let r1 = await logger.logEvent(
            botId: "bot_chief_01",
            botName: "Chief of Staff",
            eventType: "peer_delegation",
            actionName: "ask_bot",
            payloadSummary: "Delegated code review to Code Architect",
            status: "success"
        )
        XCTAssertEqual(r1.sequenceNumber, 1)
        XCTAssertEqual(r1.previousHash, "GENESIS_HASH_APEX_AGENT_0000")
        XCTAssertFalse(r1.recordHash.isEmpty)

        let r2 = await logger.logEvent(
            botId: "bot_architect_02",
            botName: "Code Architect",
            eventType: "tool_execution",
            actionName: "write_file",
            payloadSummary: "Modified ApexAgentApp.swift",
            status: "success"
        )
        XCTAssertEqual(r2.sequenceNumber, 2)
        XCTAssertEqual(r2.previousHash, r1.recordHash)

        let r3 = await logger.logEvent(
            botId: "bot_automator_03",
            botName: "Automator",
            eventType: "security_violation",
            actionName: "run_shell_command",
            payloadSummary: "Blocked command rm -rf /",
            status: "denied"
        )
        XCTAssertEqual(r3.sequenceNumber, 3)
        XCTAssertEqual(r3.previousHash, r2.recordHash)

        // 2. Verify chain integrity
        let (isValid, totalCount) = await logger.verifyChainIntegrity()
        XCTAssertTrue(isValid)
        XCTAssertEqual(totalCount, 3)

        // 3. Verify file persistence
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        let content = try? String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content?.contains("bot_chief_01") ?? false)
        XCTAssertTrue(content?.contains("bot_architect_02") ?? false)
        XCTAssertTrue(content?.contains("bot_automator_03") ?? false)

        await logger.reset()
    }
}
