import Testing
import Foundation
import SwiftData
import AppKit
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

    // MARK: - Batch 2 Self-Hardening Tests

    @Test @MainActor func testSpaceManagerMarkdownExport() throws {
        let schema = Schema([SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        let manager = SpaceManager.shared
        manager.modelContext = context

        let space = SpaceModel(name: "Engineering Core", summary: "Cross-functional bot and engineer collaboration")
        let participant = SpaceParticipant(
            displayName: "Alice Dev",
            handle: "alice",
            kind: .humanLocal,
            role: .owner
        )
        space.participants.append(participant)

        let channel = SpaceChannel(
            name: "architecture",
            topic: "System design discussions",
            channelType: .chat
        )
        let message = SpaceMessage(
            senderParticipantId: participant.id,
            senderName: "Alice Dev",
            senderHandle: "alice",
            senderKind: .human,
            content: "Welcome to the architecture channel!"
        )
        channel.messages.append(message)
        space.channels.append(channel)

        let page = SpacePage(
            title: "Roadmap 2026",
            markdownBody: "## Next milestones\n- Complete Batch 2 self-improvement loop",
            lastEditedByName: "Alice Dev"
        )
        space.pages.append(page)

        manager.spaces = [space]

        guard let markdown = manager.exportSpaceAsMarkdown(spaceId: space.id) else {
            Issue.record("Failed to export space as markdown")
            return
        }

        #expect(markdown.contains("# Space: Engineering Core"))
        #expect(markdown.contains("| Name | Handle | Kind | Role | Status |"))
        #expect(markdown.contains("| **Alice Dev** | `@alice` |"))
        #expect(markdown.contains("### #architecture"))
        #expect(markdown.contains("Welcome to the architecture channel!"))
        #expect(markdown.contains("### Page: Roadmap 2026"))
    }

    @Test @MainActor func testPTYSessionSignalControls() async throws {
        let orchestrator = AgentOrchestrator()
        let session = try await PTYSession(orchestrator: orchestrator)

        // Verifying signal calls are safe and non-crashing in all states
        session.sendInterrupt()
        session.sendSignal(15) // SIGTERM
        session.sendEOF()
        session.cleanup()
    }

    @Test func testAgentRegistryNotificationEmission() async {
        var didReceiveNotification = false
        let observer = NotificationCenter.default.addObserver(
            forName: .agentRegistryUpdated,
            object: nil,
            queue: .main
        ) { _ in
            didReceiveNotification = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let testAgent = RegisteredAgent(
            name: "temporary_test_bot_\(UUID().uuidString.prefix(6))",
            systemPrompt: "You are a test agent.",
            allowedTools: ["read_file"]
        )
        AgentRegistry.shared.register(testAgent)

        // Give the notification loop a brief window
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(didReceiveNotification == true)

        AgentRegistry.shared.unregister(name: testAgent.name)
    }

    @Test @MainActor func testDeleteMemoryToolKeyAndCategory() async throws {
        let schema = Schema([AgentMemory.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        let orchestrator = AgentOrchestrator()
        orchestrator.modelContext = context

        // Insert memories
        let mem1 = AgentMemory(key: "test_key_alpha", val: "Alpha Value", category: "test_cat")
        let mem2 = AgentMemory(key: "test_key_beta", val: "Beta Value", category: "test_cat")
        let mem3 = AgentMemory(key: "test_key_gamma", val: "Gamma Value", category: "other_cat")
        context.insert(mem1)
        context.insert(mem2)
        context.insert(mem3)
        try context.save()

        let deleteTool = DeleteMemoryTool(orchestrator: orchestrator)

        // Delete single key
        let res1 = try await deleteTool.call(arguments: .init(key: "test_key_alpha", category: nil))
        #expect(res1.contains("Successfully deleted memory record for key 'test_key_alpha'"))

        let remainingKeys = try context.fetch(FetchDescriptor<AgentMemory>())
        #expect(remainingKeys.count == 2)
        #expect(!remainingKeys.contains(where: { $0.key == "test_key_alpha" }))

        // Delete entire category
        let res2 = try await deleteTool.call(arguments: .init(key: nil, category: "test_cat"))
        #expect(res2.contains("Successfully deleted 1 memory record(s) in category 'test_cat'"))

        let finalRemaining = try context.fetch(FetchDescriptor<AgentMemory>())
        #expect(finalRemaining.count == 1)
        #expect(finalRemaining.first?.key == "test_key_gamma")
    }

    @Test @MainActor func testNetworkDiagnosticsFormattingAndDNS() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = NetworkDiagnosticsTool(orchestrator: orchestrator)

        let statusResult = try await tool.call(arguments: .init(action: "status", host: nil, port: nil, timeoutSeconds: nil))
        #expect(statusResult.contains("### Network Interface Status"))
        #expect(statusResult.contains("| Metric | Value |"))
        #expect(statusResult.contains("|---|---|"))

        let dnsResult = try await tool.call(arguments: .init(action: "dns", host: "127.0.0.1", port: nil, timeoutSeconds: nil))
        #expect(dnsResult.contains("### DNS Resolution for `127.0.0.1`"))
        #expect(dnsResult.contains("| IP Address | Address Family |"))
        #expect(dnsResult.contains("|---|---|"))
    }

    @Test @MainActor func testScreenStreamerIdleTracking() {
        let streamer = ScreenStreamer.shared
        let dummyImage = NSImage(size: NSSize(width: 10, height: 10))

        streamer.recordTestFrame(dummyImage)
        #expect(streamer.getLatestFrame() != nil)
        #expect(streamer.isIdle == false)
    }
}
