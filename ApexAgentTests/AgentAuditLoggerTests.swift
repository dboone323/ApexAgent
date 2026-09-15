import XCTest
@testable import ApexAgentCore

@MainActor
final class AgentAuditLoggerTests: XCTestCase {

    func testCryptographicAuditChainAndTamperVerification() async throws {
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
        let r2 = await logger.logEvent(
            botId: "bot_architect_02",
            botName: "Code Architect",
            eventType: "tool_execution",
            actionName: "write_file",
            payloadSummary: "Modified ApexAgentApp.swift",
            status: "success"
        )
        let r3 = await logger.logEvent(
            botId: "bot_automator_03",
            botName: "Automator",
            eventType: "security_violation",
            actionName: "run_shell_command",
            payloadSummary: "Blocked command rm -rf /",
            status: "denied"
        )

        let (isValid, totalCount) = await logger.verifyChainIntegrity()
        let fileIntegrity = await logger.verifyFileIntegrity()

        TestActivity.step("1. Verify sequential hash chaining and baseline integrity") { _ in
            XCTAssertEqual(r1.sequenceNumber, 1)
            XCTAssertEqual(r1.previousHash, "GENESIS_HASH_APEX_AGENT_0000")
            XCTAssertFalse(r1.recordHash.isEmpty)

            XCTAssertEqual(r2.sequenceNumber, 2)
            XCTAssertEqual(r2.previousHash, r1.recordHash)

            XCTAssertEqual(r3.sequenceNumber, 3)
            XCTAssertEqual(r3.previousHash, r2.recordHash)

            XCTAssertTrue(isValid, "Initial chain must be cryptographically valid")
            XCTAssertEqual(totalCount, 3)
            XCTAssertTrue(fileIntegrity.isValid, "File on disk must match memory chain validity")
            XCTAssertEqual(fileIntegrity.totalRecords, 3)
            XCTAssertNil(fileIntegrity.tamperedLine)
        }

        // 2. Tamper with disk content
        let rawContent = try String(contentsOf: tempURL, encoding: .utf8)
        var lines = rawContent.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)

        let tamperedLine2 = lines[1].replacingOccurrences(of: "Modified ApexAgentApp.swift", with: "Injected Malicious Payload")
        lines[1] = tamperedLine2
        let tamperedContent = lines.joined(separator: "\n") + "\n"
        try tamperedContent.write(to: tempURL, atomically: true, encoding: .utf8)

        let tamperedCheck = await logger.verifyFileIntegrity()

        TestActivity.step("2. Assert file tampering detection on disk") { _ in
            XCTAssertFalse(tamperedCheck.isValid, "File integrity must fail when payload is tampered")
            XCTAssertEqual(tamperedCheck.tamperedLine, 1, "Must pinpoint tampered record at line index 1")
        }

        // 3. Broken hash linkage check
        let forgedRecord = AgentAuditRecord(
            sequenceNumber: 2,
            botId: "bot_forged",
            botName: "Attacker",
            eventType: "hijack",
            actionName: "exec",
            payloadSummary: "Attack",
            status: "ok",
            previousHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        let forgedData = try JSONEncoder().encode(forgedRecord)
        lines[1] = String(data: forgedData, encoding: .utf8)!
        let forgedContent = lines.joined(separator: "\n") + "\n"
        try forgedContent.write(to: tempURL, atomically: true, encoding: .utf8)

        let forgedCheck = await logger.verifyFileIntegrity()

        TestActivity.step("3. Assert broken sequence linkage detection") { _ in
            XCTAssertFalse(forgedCheck.isValid, "File integrity must fail on broken hash linkage")
            XCTAssertEqual(forgedCheck.tamperedLine, 1)
        }

        await logger.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path), "Reset must remove log file")
    }
}
