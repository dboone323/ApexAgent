import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("EndToEndExecutionVerificationTests")
struct EndToEndExecutionVerificationTests {

    @Test func testVerifyExecutionFileExistsAndContains() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("verify_test_\(UUID().uuidString).txt")
        let testContent = "APEX_AGENT_VERIFICATION_PAYLOAD_12345"

        try testContent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let orchestrator = AgentOrchestrator()
        let tool = VerifyExecutionTool(orchestrator: orchestrator)

        // 1. file_exists check
        let existsResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "file_exists",
            targetPath: testFile.path,
            expectedPattern: nil,
            command: nil
        ))
        #expect(existsResult.hasPrefix("VERIFIED: File exists on disk"))

        // 2. file_contains check
        let containsResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "file_contains",
            targetPath: testFile.path,
            expectedPattern: "VERIFICATION_PAYLOAD_12345",
            command: nil
        ))
        #expect(containsResult.hasPrefix("VERIFIED: File"))

        // 3. file_not_contains check
        let notContainsResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "file_not_contains",
            targetPath: testFile.path,
            expectedPattern: "FORBIDDEN_STRING_99999",
            command: nil
        ))
        #expect(notContainsResult.hasPrefix("VERIFIED: File"))

        // 4. file_contains failure on missing pattern
        let failResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "file_contains",
            targetPath: testFile.path,
            expectedPattern: "NON_EXISTENT_PATTERN",
            command: nil
        ))
        #expect(failResult.hasPrefix("VERIFICATION_FAILED:"))
    }

    @Test func testVerifyExecutionCommandSucceeds() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = VerifyExecutionTool(orchestrator: orchestrator)

        let successResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "command_succeeds",
            targetPath: nil,
            expectedPattern: "verified_output",
            command: "echo 'verified_output'"
        ))
        #expect(successResult.hasPrefix("VERIFIED: Command succeeded"))

        let failResult = try await tool.call(arguments: VerifyExecutionTool.Arguments(
            verificationType: "command_succeeds",
            targetPath: nil,
            expectedPattern: nil,
            command: "exit 1"
        ))
        #expect(failResult.hasPrefix("VERIFICATION_FAILED:"))
    }

    @Test func testFileWriteToolVerifiedPostCondition() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("write_verify_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: testFile) }

        let orchestrator = AgentOrchestrator()
        let writeTool = FileWriteTool(orchestrator: orchestrator)

        let result = try await writeTool.call(arguments: FileWriteTool.Arguments(
            path: testFile.path,
            content: "Verified disk write test content",
            append: false
        ))

        #expect(result.contains("✅ Written"))
        #expect(result.contains("[Verified:"))
        #expect(FileManager.default.fileExists(atPath: testFile.path))
    }
}
