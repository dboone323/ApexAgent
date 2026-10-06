import Testing
import Foundation
@testable import ApexAgentCore

@Suite("SecurityTests", .serialized)
struct SecurityTests {

    // MARK: - WS5.6 Global tool allowlist

    @Test func testToolPolicyDefaultsToAllEnabled() {
        ToolPolicy.shared.reset()
        #expect(ToolPolicy.shared.isGloballyAllowed("run_shell_command"))
        #expect(ToolPolicy.shared.isGloballyAllowed("write_file"))
    }

    @Test func testToolPolicyDisableGatesToolGlobally() {
        ToolPolicy.shared.reset()
        ToolPolicy.shared.setToolEnabled("run_shell_command", enabled: false)
        #expect(!ToolPolicy.shared.isGloballyAllowed("run_shell_command"))
        // Other tools remain allowed.
        #expect(ToolPolicy.shared.isGloballyAllowed("write_file"))

        // Re-enable to leave a clean state.
        ToolPolicy.shared.setToolEnabled("run_shell_command", enabled: true)
        #expect(ToolPolicy.shared.isGloballyAllowed("run_shell_command"))
        ToolPolicy.shared.reset()
    }

    @Test func testToolPolicyDisabledNamesReflectsState() {
        ToolPolicy.shared.reset()
        ToolPolicy.shared.setToolEnabled("delete_file", enabled: false)
        #expect(ToolPolicy.shared.disabledToolNames().contains("delete_file"))
        ToolPolicy.shared.reset()
        #expect(!ToolPolicy.shared.disabledToolNames().contains("delete_file"))
    }

    @MainActor
    @Test func testGlobalDenylistBlocksCentralDispatch() async {
        let policy = ToolPolicy.shared
        let previous = policy.disabledToolNames()
        policy.setToolEnabled("read_file", enabled: false)
        defer {
            policy.setToolEnabled("read_file", enabled: true)
            for name in previous {
                policy.setToolEnabled(name, enabled: false)
            }
        }

        let orchestrator = AgentOrchestrator()
        do {
            _ = try await orchestrator.executeToolByName(
                name: "read_file",
                jsonArguments: "{}"
            )
            Issue.record("A globally denied tool must not execute")
        } catch {
            #expect((error as NSError).domain == "AgentSecurity")
            #expect((error as NSError).code == 403)
        }
    }

    // MARK: - WS5.7 File write rollback

    @Test func testFileRollbackRestoresOverwrittenFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("note.txt").path

        try "original content".write(toFile: file, atomically: true, encoding: .utf8)

        // Snapshot then overwrite.
        let snap = FileRollback.snapshot(path: file)
        #expect(snap != nil)
        #expect(FileRollback.hasSnapshot(path: file))

        try "new content".write(toFile: file, atomically: true, encoding: .utf8)
        #expect((try String(contentsOfFile: file, encoding: .utf8)) == "new content")

        // Roll back.
        let ok = FileRollback.rollback(path: file)
        #expect(ok)
        #expect((try String(contentsOfFile: file, encoding: .utf8)) == "original content")

        try fm.removeItem(at: dir)
    }

    @Test func testFileRollbackRestoresDeletedFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("to-delete.txt").path

        try "do not lose me".write(toFile: file, atomically: true, encoding: .utf8)
        FileRollback.snapshot(path: file)
        try fm.removeItem(atPath: file)
        #expect(!fm.fileExists(atPath: file))

        let ok = FileRollback.rollback(path: file)
        #expect(ok)
        #expect(fm.fileExists(atPath: file))
        #expect((try String(contentsOfFile: file, encoding: .utf8)) == "do not lose me")

        try fm.removeItem(at: dir)
    }

    @Test func testFileRollbackNoSnapshotForMissingFile() {
        let missing = "/tmp/apex-rollback-does-not-exist-\(UUID().uuidString).txt"
        let snap = FileRollback.snapshot(path: missing)
        #expect(snap == nil)
        #expect(!FileRollback.hasSnapshot(path: missing))
        #expect(!FileRollback.rollback(path: missing))
    }

    // MARK: - WS5.5 Keychain Audit Logging Tests

    @Test func testKeychainAuditLoggingRecordsOperations() async throws {
        let logger = KeychainAuditLogger.shared
        await logger.clear()

        await logger.record(operation: "save", key: "test_service_key", success: true, caller: "UnitTests")
        await logger.record(operation: "get", key: "test_service_key", success: true, caller: "UnitTests")
        await logger.record(operation: "delete", key: "test_service_key", success: true, caller: "UnitTests")

        let entries = await logger.recentEntries(limit: 10)
        #expect(entries.count == 3)
        #expect(entries.contains(where: { $0.operation == "save" && $0.key == "test_service_key" }))
        #expect(entries.contains(where: { $0.operation == "get" && $0.key == "test_service_key" }))
        #expect(entries.contains(where: { $0.operation == "delete" && $0.key == "test_service_key" }))

        // Secrecy guarantee: Log entries must never contain secret values
        let logURL = KeychainAuditLogger.logFileURL
        if let rawLog = try? String(contentsOf: logURL, encoding: .utf8) {
            #expect(!rawLog.contains("secret_token"))
            #expect(!rawLog.contains("password"))
        }

        await logger.clear()
        let cleared = await logger.recentEntries(limit: 10)
        #expect(cleared.isEmpty)
    }

    // MARK: - WS5.7 File Rollback UndoLast & RollbackTool Tests

    @Test func testFileRollbackUndoLastRestoresPreviousContent() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("rollback_undo_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let targetFile = tempDir.appendingPathComponent("notes.md").path
        try "# Initial Notes".write(toFile: targetFile, atomically: true, encoding: .utf8)

        FileRollback.snapshot(path: targetFile)
        try "# Overwritten Notes".write(toFile: targetFile, atomically: true, encoding: .utf8)

        let result = FileRollback.rollbackLast()
        #expect(result != nil)
        #expect(result?.success == true)
        #expect(result?.path == targetFile)

        let finalContent = try String(contentsOfFile: targetFile, encoding: .utf8)
        #expect(finalContent == "# Initial Notes")
    }

    @Test @MainActor func testRollbackToolDispatch() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = RollbackTool(orchestrator: orchestrator)

        let listResult = try await tool.call(arguments: .init(action: "list", path: nil))
        #expect(!listResult.isEmpty)

        let unknownResult = try await tool.call(arguments: .init(action: "invalid_action", path: nil))
        #expect(unknownResult.contains("ERROR"))
    }

    @Test @MainActor func testToolPolicyKillSwitchEnforcementInEngine() async throws {
        let engine = ToolDispatchEngine()
        let orchestrator = AgentOrchestrator()
        let allTools = engine.buildAllTools(orchestrator: orchestrator, botManager: nil)

        let testTool = "test_kill_switch_tool"
        ToolPolicy.shared.setToolEnabled(testTool, enabled: false)
        #expect(!ToolPolicy.shared.isGloballyAllowed(testTool))

        var didCatch403 = false
        do {
            _ = try await engine.executeToolByName(
                name: testTool,
                jsonArguments: "{}",
                allTools: allTools
            )
        } catch let nsErr as NSError {
            if nsErr.domain == "AgentSecurity" && nsErr.code == 403 {
                didCatch403 = true
            }
        }
        #expect(didCatch403 == true)

        ToolPolicy.shared.setToolEnabled(testTool, enabled: true)
        #expect(ToolPolicy.shared.isGloballyAllowed(testTool))
        ToolPolicy.shared.reset()
    }

    // MARK: - WS4.6 Tracing Span Emission Tests

    @Test func testTracingSpanEmissionToTraceBus() async {
        let opName: StaticString = "test.security.trace"
        let testSource = "SecurityTests"

        await Tracing.span(opName, source: testSource, metadata: ["batch": "1"]) {
            try? await Task.sleep(nanoseconds: 500_000)
        }

        let traces = Tracing.recentTraces(limit: 20)
        let found = traces.contains { trace in
            trace.source == testSource && trace.operation.contains("test.security.trace")
        }
        #expect(found == true)
    }
}
