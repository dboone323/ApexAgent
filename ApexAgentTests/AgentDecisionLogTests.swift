import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O6: Decision-log rows in AgentAuditLog

@Suite("AgentDecisionLogTests")
struct AgentDecisionLogTests {

    /// Redirect the audit log to an isolated temp file for this test.
    private func isolateLogPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apex-decisions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("audit.jsonl").path
        setenv("APEX_AUDIT_LOG_PATH", path, 1)
        return path
    }

    /// Wait briefly for the audit file to appear (the actor write is async
    /// relative to this test's task).
    private func waitForLog(_ path: String, timeout: TimeInterval = 5) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty {
                return text
            }
            usleep(50_000)
        }
        struct MissingLog: Error {}
        throw MissingLog()
    }

    @Test func decisionRowsCarryAttributionAndRedactSecrets() async throws {
        let path = try isolateLogPath()
        defer { unsetenv("APEX_AUDIT_LOG_PATH") }

        // 1. Auto-approved grant: rule attributed, secret redacted.
        await AgentAuditLog.shared.recordDecision(
            toolName: "run_shell_command",
            arguments: "export MY_API_KEY=supersecretvalue123",
            approved: true,
            source: .alwaysAllow,
            rule: "run_shell_command:git")

        // 2. Guarded denial: names the rule that blocked it.
        await AgentAuditLog.shared.recordDecision(
            toolName: "run_shell_command",
            arguments: "git push --force origin main",
            approved: false,
            source: .destructiveGuard,
            rule: ApprovalPolicy.destructiveGuardRuleName)

        let text = try waitForLog(path)

        #expect(text.contains("always-allow"))
        #expect(text.contains("run_shell_command:git"))
        #expect(text.contains("auto-approved"))
        #expect(text.contains("destructive-guard"))
        #expect(text.contains("denied"))
        // The secret must never reach the log, even though it was in arguments.
        #expect(!text.contains("supersecretvalue123"))
    }
}
