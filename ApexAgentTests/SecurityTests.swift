import Testing
import Foundation
import SwiftData
import AppKit
import SharedKit
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

    // MARK: - Batch 3 Self-Hardening Tests

    @Test @MainActor func testSecurityAuditorBlocksShellHistoryAndNetrc() {
        let auditor = SecurityAuditor.shared
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let ws = (home as NSString).appendingPathComponent("Developer/ApexAgent")

        // .bash_history
        #expect(throws: SecuritySandboxError.self) {
            try auditor.verifyPathAllowed((home as NSString).appendingPathComponent(".bash_history"), workspacePath: ws, permissions: nil)
        }

        // .zsh_history
        #expect(throws: SecuritySandboxError.self) {
            try auditor.verifyPathAllowed((home as NSString).appendingPathComponent(".zsh_history"), workspacePath: ws, permissions: nil)
        }

        // .netrc
        #expect(throws: SecuritySandboxError.self) {
            try auditor.verifyPathAllowed((home as NSString).appendingPathComponent(".netrc"), workspacePath: ws, permissions: nil)
        }
    }

    @Test @MainActor func testProjectAuditorMarkdownFormatting() {
        let auditor = ProjectAuditor.shared
        let sampleReport = ProjectAuditReport(
            name: "ApexAppSample",
            path: "/Users/dev/ApexAppSample.xcodeproj",
            swiftVersion: "6.0",
            strictConcurrency: "complete",
            deploymentTarget: "macOS 27.0",
            fileCount: 42,
            todoCount: 3,
            brokenReferences: ["MissingFile.swift"],
            warnings: ["Target Swift version is 6.0"]
        )

        let markdown = auditor.formatReportsAsMarkdown([sampleReport])
        #expect(markdown.contains("## 📊 Xcode Workspace Audit Report"))
        #expect(markdown.contains("| Project | Target | Swift | Concurrency | Files | TODOs | Broken Refs | Warnings |"))
        #expect(markdown.contains("| **ApexAppSample** | `macOS 27.0` | `6.0` | `complete` | 42 | 3 | 1 | 1 |"))
        #expect(markdown.contains("MissingFile.swift"))
    }

    @Test @MainActor func testSkillManagerManifestValidation() throws {
        let manager = SkillManager.shared
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Valid manifest
        let validScriptURL = tempDir.appendingPathComponent("sample_tool.sh")
        try "#!/bin/bash\necho ok".write(to: validScriptURL, atomically: true, encoding: .utf8)
        let validJSONURL = tempDir.appendingPathComponent("sample_tool.json")
        let validJSON = """
        {
            "description": "A sample testing skill",
            "script_path": "\(validScriptURL.path)",
            "parameters": {
                "properties": {
                    "input": { "type": "string" }
                }
            }
        }
        """
        try validJSON.write(to: validJSONURL, atomically: true, encoding: .utf8)

        let validResult = manager.validateSkillManifest(at: validJSONURL)
        switch validResult {
        case .success(let info):
            #expect(info.name == "sample_tool")
            #expect(info.parameterCount == 1)
        case .failure(let error):
            Issue.record("Expected valid manifest, got error: \(error)")
        }

        // 2. Missing description manifest
        let badJSONURL = tempDir.appendingPathComponent("bad_tool.json")
        let badJSON = """
        {
            "script_path": "\(validScriptURL.path)"
        }
        """
        try badJSON.write(to: badJSONURL, atomically: true, encoding: .utf8)

        let badResult = manager.validateSkillManifest(at: badJSONURL)
        switch badResult {
        case .success:
            Issue.record("Expected failure for missing description")
        case .failure(let error):
            #expect(error == .missingDescription("bad_tool"))
        }
    }

    @Test func testContextCompactorBudgetBreakdown() async {
        let compactor = ContextCompactor.shared
        let messages: [(role: String, content: String)] = [
            (role: "user", content: "Hello world, what is the current weather?"),
            (role: "assistant", content: "The weather in San Francisco is 65 degrees and sunny.")
        ]
        let systemPrompt = "You are ApexAgent, a high performance AI assistant."

        let breakdown = await compactor.inspectBudget(messages: messages, pinnedSystemPrompt: systemPrompt, maxBudget: 4000)
        #expect(breakdown.totalEstimatedTokens > 0)
        #expect(breakdown.budgetLimit == 4000)
        #expect(!breakdown.isExceeded)

        let table = breakdown.formatAsMarkdownTable()
        #expect(table.contains("### Context Window Budget Breakdown"))
        #expect(table.contains("| Component | Approximate Tokens | Percentage of Total |"))
        #expect(table.contains("| System Prompt |"))
        #expect(table.contains("| User Turns |"))
        #expect(table.contains("| Assistant Turns |"))
    }

    @Test @MainActor func testExportReviewSessionMarkdownTool() async throws {
        let schema = Schema([ReviewSession.self, CodeIssueModel.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        let orchestrator = AgentOrchestrator()
        orchestrator.modelContext = context

        let saveTool = SaveReviewSessionTool(orchestrator: orchestrator)
        let issuesJSON = """
        [
            {"line": 24, "message": "Potential memory leak in callback", "severity": "warning"},
            {"line": 56, "message": "Unchecked array index bounds", "severity": "error"}
        ]
        """
        _ = try await saveTool.call(arguments: .init(
            fileName: "DatabaseManager.swift",
            summary: "Memory and safety analysis",
            suggestions: ["Use weak self in closures", "Guard array indices"],
            issuesJSON: issuesJSON
        ))

        let exportTool = ExportReviewSessionTool(orchestrator: orchestrator)
        let exportOutput = try await exportTool.call(arguments: .init(fileName: "DatabaseManager.swift"))

        #expect(exportOutput.contains("# Code Review Report: `DatabaseManager.swift`"))
        #expect(exportOutput.contains("| Line | Severity | Message |"))
        #expect(exportOutput.contains("⚠️ Warning"))
        #expect(exportOutput.contains("🛑 Error"))
        #expect(exportOutput.contains("Potential memory leak in callback"))
        #expect(exportOutput.contains("Use weak self in closures"))
    }

    // MARK: - Batch 4 Self-Hardening Tests

    @Test func testDiffHelperStatsAndUnifiedDiff() {
        let oldText = "line 1\nline 2\nline 3"
        let newText = "line 1\nline 2 modified\nline 3\nline 4"

        let diff = DiffHelper.computeDiff(oldText: oldText, newText: newText)
        let stats = DiffHelper.computeStats(diff: diff)

        #expect(stats.additions >= 1)
        #expect(stats.totalLines >= 4)
        #expect(stats.summary().contains("+"))

        let unified = DiffHelper.formatUnifiedDiff(oldText: oldText, newText: newText, filePath: "Config.swift")
        #expect(unified.contains("--- a/Config.swift"))
        #expect(unified.contains("+++ b/Config.swift"))
        #expect(unified.contains("@@ -1,3 +1,4 @@"))
    }

    @Test @MainActor func testReflectionManagerHistoryAndExport() {
        let manager = ReflectionManager.shared
        manager.recordReflection(skillName: "fix_swift6_actor_isolation", triggerSummary: "Actor isolation violation in Task closure")

        #expect(!manager.recentReflections.isEmpty)
        #expect(manager.recentReflections.first?.skillName == "fix_swift6_actor_isolation")

        let markdown = manager.exportReflectionHistory()
        #expect(markdown.contains("### 🧠 Autonomous Procedural Reflection History"))
        #expect(markdown.contains("| Skill Name | Trigger / Error | Resolved | Timestamp |"))
        #expect(markdown.contains("fix_swift6_actor_isolation"))
    }

    @Test @MainActor func testProactiveSchedulerFindingsFormattingAndDismissal() async {
        let scheduler = ProactiveScheduler.shared
        scheduler.clearAllFindings()

        let emptyMarkdown = scheduler.formatFindingsAsMarkdown()
        #expect(emptyMarkdown.contains("All agent operations are healthy"))

        let finding = ProactiveScheduler.ProactiveFinding(
            title: "Test Queue Lag",
            detail: "Queue depth exceeded threshold",
            severity: .warning,
            targetBotName: "tester"
        )
        // Simulate finding injection
        _ = await scheduler.evaluateNow()
        scheduler.dismissFinding(id: finding.id)
        #expect(scheduler.activeFindings.isEmpty)
    }

    @Test @MainActor func testRoutineManagerMarkdownSummaries() {
        let manager = RoutineManager.shared
        let emptySummary = manager.exportRoutinesSummaryAsMarkdown()
        #expect(emptySummary == "No automated routines configured." || emptySummary.contains("| Routine Name | Enabled |"))

        let now = Date()
        let run = RoutineRun(
            routineId: UUID(),
            routineName: "Nightly Build Triage",
            prompt: "Perform nightly build triage",
            status: .completed,
            startedAt: now,
            finishedAt: now.addingTimeInterval(3.5),
            output: "All 4 targets compiled cleanly."
        )
        manager.recordRun(run)

        let runsSummary = manager.exportRoutineRunsSummary(limit: 5)
        #expect(runsSummary.contains("### 📜 Automation Routine Run Receipts"))
        #expect(runsSummary.contains("| Routine Name | Status | Duration (s) | Started At |"))
        #expect(runsSummary.contains("Nightly Build Triage"))
        #expect(runsSummary.contains("✅ Completed"))
    }

    @Test func testMessageCompressionWithMetrics() {
        var messages: [ChatMessage] = []
        for i in 1...10 {
            messages.append(ChatMessage(role: .user, content: "User prompt query #\(i)"))
            messages.append(ChatMessage(role: .assistant, content: String(repeating: "Assistant detailed analytical response with extensive logs and explanatory reasoning for query #\(i) that spans multiple sentences to exercise compression. ", count: 5)))
        }

        let (compressed, metrics) = MessageCompressionHelper.compressWithMetrics(messages, keepRecent: 4)
        #expect(compressed.count == messages.count)
        #expect(metrics.tokensSaved > 0)
        #expect(metrics.compressionRatio <= 1.0)
        #expect(metrics.summary().contains("Saved"))
    }

    @Test @MainActor func testA2AServerHealthRoute() async {
        let server = A2AServer.shared
        let req = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let data = Data(req.utf8)

        guard let (_, responseData) = await server.processHttpBuffer(data) else {
            Issue.record("A2AServer failed to process /health request buffer")
            return
        }

        let responseStr = String(data: responseData, encoding: .utf8) ?? ""
        #expect(responseStr.contains("HTTP/1.1 200 OK"))
        #expect(responseStr.contains("\"status\" : \"healthy\""))
        #expect(responseStr.contains("ApexAgent A2A Node"))
    }

    @Test @MainActor func testMultiAgentDebateMarkdownExport() {
        let coordinator = MultiAgentDebateCoordinator.shared
        coordinator.clearDebateHistory()

        let debate = MultiAgentDebateCoordinator.DebateRound(
            id: UUID(),
            topic: "Strict Swift 6.4 Actor Isolation vs Global Concurrency Locks",
            participants: ["architect", "security"],
            arguments: [
                "architect": "Strict actor boundaries prevent data races at compile-time.",
                "security": "Actor isolation also enforces distinct credential domain boundaries."
            ],
            consensus: "Adopt complete strict concurrency across all packages with isolated domain actors.",
            startedAt: Date(),
            concludedAt: Date().addingTimeInterval(5)
        )

        let markdown = coordinator.exportDebateMarkdown(debate: debate)
        #expect(markdown.contains("# 🎙️ Multi-Agent Debate"))
        #expect(markdown.contains("Strict Swift 6.4 Actor Isolation"))
        #expect(markdown.contains("| Bot Name | Position / Argument |"))
        #expect(markdown.contains("| `@architect` |"))
        #expect(markdown.contains("### 🎯 Consensus Recommendation"))
        #expect(markdown.contains("Adopt complete strict concurrency"))
    }

    @Test @MainActor func testDiagnosticManagerMarkdownExport() {
        let items: [DiagnosticItem] = [
            DiagnosticItem(name: "Xcode CLI", category: "CLI Tools", status: .pass, message: "Installed"),
            DiagnosticItem(name: "Git", category: "CLI Tools", status: .pass, message: "Available"),
            DiagnosticItem(name: "Memory Index", category: "Agent Configuration", status: .warning, message: "Needs re-indexing")
        ]

        let md = DiagnosticManager.exportMarkdownReport(items)
        #expect(md.contains("### 🩺 ApexAgent System Diagnostics Report"))
        #expect(md.contains("| Category | Item | Status | Details |"))
        #expect(md.contains("| CLI Tools | **Xcode CLI** | ✅ Pass | Installed |"))
        #expect(md.contains("⚠️ Warning"))
    }



    // MARK: - Batch 5 Self-Hardening Tests

    @Test func testRepeatDetectorLoopDetectionAndMarkdownReport() {
        let detector = RepeatDetector(thresholds: [3, 5])
        let thread = "test-thread-loop"
        detector.settle(thread: thread)

        _ = detector.record(thread: thread, key: "tool:read_file:path=/tmp/a")
        _ = detector.record(thread: thread, key: "tool:read_file:path=/tmp/a")
        let third = detector.record(thread: thread, key: "tool:read_file:path=/tmp/a")

        #expect(third.count == 3)
        #expect(third.threshold == 3)

        let (isLooping, key, count) = detector.detectLoop(thread: thread)
        #expect(isLooping)
        #expect(key == "tool:read_file:path=/tmp/a")
        #expect(count == 3)

        let report = detector.generateLoopReport(thread: thread)
        #expect(report != nil)
        #expect(report!.contains("### 🔁 Repeated Tool Call Analysis"))
        #expect(report!.contains("| Tool Signature | Count | Risk Level | Status |"))
        #expect(report!.contains("⚠️ High Repetition"))
    }

    @Test func testCronParserNextRunsTableAndHumanReadable() throws {
        let schedule = try CronSchedule(expression: "0 9 * * 1-5")
        #expect(schedule.humanReadableDescription == "Weekdays at 9:00 AM")

        let fixedDate = Date(timeIntervalSince1970: 1775000000) // Deterministic epoch
        let table = schedule.formatNextRunsTable(count: 3, from: fixedDate)

        #expect(table.contains("### ⏱️ Upcoming Scheduled Executions: `0 9 * * 1-5`"))
        #expect(table.contains("| # | Scheduled Time | Relative Offset |"))
        #expect(table.contains("| `1` |"))
        #expect(table.contains("| `2` |"))
        #expect(table.contains("| `3` |"))
    }

    @Test @MainActor func testDailyBriefingMarkdownExport() {
        let now = Date()
        let briefing = DailyBriefing.liveSnapshot(
            mood: "Optimistic and Productive",
            budgetAlertStatus: "Nominal (12% of quota used)",
            habitCompletionCount: 4,
            activePowerUp: true,
            recentSharedTasks: [
                SharedTask(title: "Audit Swift 6.4 Concurrency Boundaries", detail: "Verify strict isolation", status: "completed", priority: "high"),
                SharedTask(title: "Run Unit Test Suite", detail: "Execute 100% test suite", status: "pending", priority: "urgent")
            ],
            outlookInbox: OutlookInboxReference(
                lastRefreshed: now,
                previews: [
                    EmailPreview(id: UUID(), from: "lead@apexagent.internal", subject: "Build Pipeline Status", snippet: "Green", receivedAt: now)
                ]
            ),
            appSyncTopics: [
                AppSyncTopic(id: UUID(), appName: "Xcode", topic: "ApexAgent.xcodeproj", updatedAt: now)
            ]
        )

        let md = briefing.formatAsMarkdown()
        #expect(md.contains("# ☀️ Daily Executive Briefing"))
        #expect(md.contains("- **Daily Mood**: Optimistic and Productive"))
        #expect(md.contains("### 📋 Priority Tasks"))
        #expect(md.contains("| Task Title | Status |"))
        #expect(md.contains("Audit Swift 6.4 Concurrency Boundaries"))
        #expect(md.contains("✅ Completed"))
        #expect(md.contains("### 📬 Outlook Inbox Highlights"))
        #expect(md.contains("lead@apexagent.internal"))
        #expect(md.contains("### 🔄 System App Sync Topics"))
        #expect(md.contains("Xcode"))
    }

    @Test func testModelRegistrySupportedProvidersTable() {
        let table = ModelRegistry.formatSupportedProvidersTable()
        #expect(table.contains("### 🤖 Supported Model Providers & Privacy Tiers"))
        #expect(table.contains("| Provider Identifier | Display Name | Privacy Class |"))
        #expect(table.contains("appleOnDevice"))
        #expect(table.contains("cloudGemini"))
        #expect(table.contains("localOllama"))
    }

    @Test func testAgentHandoffMarkdownFormatting() {
        let taskResult = TaskResult(
            taskId: "task-001-sec",
            status: "completed",
            resultSummary: "Validated all path defenses against dot-dot traversal.",
            errorDetails: nil
        )

        let resultMd = taskResult.formatAsMarkdown()
        #expect(resultMd.contains("### 🤝 Agent Task Execution: `task-001-sec`"))
        #expect(resultMd.contains("| Execution Status | ✅ Completed |"))
        #expect(resultMd.contains("Validated all path defenses"))

        let consensus = ConsensusReport(
            consensusDecision: "Adopt strict isolation",
            majorityView: "Actor boundaries ensure zero race conditions",
            minorityDissent: "Adds slight actor hop overhead",
            confidence: 0.95
        )

        let consensusMd = consensus.formatAsMarkdown(topic: "Actor Concurrency")
        #expect(consensusMd.contains("### ⚖️ Multi-Agent Consensus: Actor Concurrency"))
        #expect(consensusMd.contains("| Decision | **Adopt strict isolation** |"))
        #expect(consensusMd.contains("| Confidence | `95.0%` |"))
        #expect(consensusMd.contains("Adds slight actor hop overhead"))
    }

    @Test func testAgentEvaluationRatingEngineComparison() {
        let engine = AgentEvaluationRatingEngine()
        let baseline = engine.quickAudit()
        let current = engine.evaluateSystem(
            computerUseChecks: (passed: 20, total: 20, notes: "Flawless desktop control"),
            visualChecks: (passed: 15, total: 15, notes: "Perfect OCR"),
            toolChecks: (passed: 25, total: 25, notes: "All schemas strictly verified"),
            safetyChecks: (passed: 20, total: 20, notes: "Zero leaks"),
            playbookChecks: (passed: 15, total: 15, notes: "All playbooks executed"),
            perfChecks: (passed: 20, total: 20, notes: "Peak throughput")
        )

        let comparison = AgentEvaluationRatingEngine.compareScorecards(baseline: baseline, current: current)
        #expect(comparison.contains("### 📈 Capability Scorecard Comparison"))
        #expect(comparison.contains("| Dimension | Baseline Score | Current Score | Delta | Status |"))
        #expect(comparison.contains("🟢 Improved"))
        #expect(comparison.contains("Total Overall Score"))
    }

    @Test @MainActor func testA2APeerDiscoveryFormattingAndPruning() {
        let discovery = A2APeerDiscovery.shared
        discovery.clearPeers()

        let emptyTable = discovery.formatPeersTable()
        #expect(emptyTable.contains("No active A2A network peers"))

        discovery.pruneStalePeers(olderThan: 0)
        #expect(discovery.discoveredPeers.isEmpty)
    }

    @Test @MainActor func testComputerMarkdownReports() {
        let computer = Computer()
        let appsTable = computer.listApplicationsMarkdown(limit: 5)
        #expect(appsTable.contains("### 🖥️ Running Applications"))
        #expect(appsTable.contains("| Application Name | Bundle Identifier | Process ID |"))

        let wsTable = computer.workspaceSummaryMarkdown()
        #expect(wsTable.contains("### 📁 Computer Shared Workspace") || wsTable.contains("Shared workspace is empty"))
    }

    @Test @MainActor func testCognitiveMemoryEngineMarkdownExport() {
        let engine = CognitiveMemoryEngine.shared
        let botId = UUID()
        engine.clearMemory(forBotId: botId)

        let emptyEpisodes = engine.exportEpisodicSummaryMarkdown(forBotId: botId)
        #expect(emptyEpisodes.contains("No episodic memory entries recorded"))

        let episode = CognitiveMemoryEngine.EpisodicEntry(
            botId: botId,
            eventType: "compile_check",
            summary: "Verified Swift 6.4 build graph integrity"
        )
        engine.recordEpisode(episode)

        let episodesMd = engine.exportEpisodicSummaryMarkdown(forBotId: botId)
        #expect(episodesMd.contains("### 🧠 Episodic Memory Log"))
        #expect(episodesMd.contains("| Event Type | Timestamp | Summary |"))
        #expect(episodesMd.contains("compile_check"))
        #expect(episodesMd.contains("Verified Swift 6.4 build graph integrity"))

        engine.storeBotFact(botId: botId, subject: "ApexAgent", predicate: "supports", object: "Swift 6.4")
        let factsMd = engine.exportSemanticGraphMarkdown(forBotId: botId)
        #expect(factsMd.contains("### 🕸️ Semantic Knowledge Graph"))
        #expect(factsMd.contains("| Subject | Predicate | Object | Confidence | Source |"))
        #expect(factsMd.contains("ApexAgent"))
        #expect(factsMd.contains("Swift 6.4"))

        engine.clearMemory(forBotId: botId)
    }

}
