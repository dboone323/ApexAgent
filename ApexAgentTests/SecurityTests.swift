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
}
