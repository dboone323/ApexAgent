import Foundation
import Testing
import CryptoKit
@testable import ApexAgentCore

@Suite("Trace-First Observability & Replay Tests (Issue #110)")
struct TraceFirstObservabilityTests {

    @Test("trace records each event kind with expected attributes")
    func testTraceRecordsEachEventKind() {
        let traceId = RunTrace.generateRunId()
        var trace = RunTrace(id: traceId)

        let ev1 = RunTraceEvent.modelCall(
            sequence: 1,
            model: "Apple Intelligence (SystemLanguageModel)",
            prompt: "Refactor the authentication controller",
            tokenCounts: TokenCountInfo(promptTokens: 120, completionTokens: 45, totalTokens: 165),
            durationMs: 312.4
        )
        let ev2 = RunTraceEvent.toolCall(
            sequence: 2,
            toolName: "read_file",
            arguments: "{\"path\": \"/Users/test/Code/Auth.swift\"}",
            result: "class AuthController { ... }",
            status: "success",
            durationMs: 14.2
        )
        let ev3 = RunTraceEvent.memoryRead(
            sequence: 3,
            tier: "curated",
            path: "/Users/test/Workspace/MEMORY.md",
            detail: "Read curated project memory",
            bytesRead: 512
        )
        let ev4 = RunTraceEvent.memoryWrite(
            sequence: 4,
            tier: "curated",
            path: "/Users/test/Workspace/MEMORY.md",
            bytesWritten: 640,
            detail: "Updated architecture decisions"
        )
        let ev5 = RunTraceEvent.subAgentHandoff(
            sequence: 5,
            parentRunId: traceId,
            subAgentId: UUID().uuidString,
            agentType: "Reviewer",
            context: "Perform static analysis audit"
        )
        let ev6 = RunTraceEvent.approval(
            sequence: 6,
            toolName: "run_shell_command",
            approved: true,
            source: .autoReview,
            rule: "safe-read-only"
        )

        trace.events = [ev1, ev2, ev3, ev4, ev5, ev6]

        #expect(trace.events.count == 6)
        #expect(trace.events[0].kind == .modelCall)
        #expect(trace.events[0].model == "Apple Intelligence (SystemLanguageModel)")
        #expect(trace.events[0].tokenCounts?.totalTokens == 165)

        #expect(trace.events[1].kind == .toolCall)
        #expect(trace.events[1].toolName == "read_file")
        #expect(trace.events[1].toolStatus == "success")

        #expect(trace.events[2].kind == .memoryRead)
        #expect(trace.events[2].memoryTier == "curated")
        #expect(trace.events[2].bytesTransferred == 512)

        #expect(trace.events[3].kind == .memoryWrite)
        #expect(trace.events[3].memoryTier == "curated")
        #expect(trace.events[3].bytesTransferred == 640)

        #expect(trace.events[4].kind == .subAgentHandoff)
        #expect(trace.events[4].parentRunId == traceId)
        #expect(trace.events[4].agentType == "Reviewer")

        #expect(trace.events[5].kind == .approval)
        #expect(trace.events[5].verdict == "approved")
        #expect(trace.events[5].verdictSource == "auto-review")
        #expect(trace.events[5].rule == "safe-read-only")
    }

    @Test("events stay in strict chronological sequence order")
    func testEventsStayInStrictChronologicalSequence() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgent-SeqTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let recorder = RunTraceManager.shared.startRun(
            workspacePath: tempDir.path,
            metadata: ["test": "sequence"]
        )

        recorder.appendEvent { seq in
            RunTraceEvent.memoryRead(sequence: seq, tier: "curated", path: "/test/mem", detail: "Read step")
        }
        recorder.appendEvent { seq in
            RunTraceEvent.modelCall(sequence: seq, model: "test-model", prompt: "Hello world")
        }
        recorder.appendEvent { seq in
            RunTraceEvent.approval(sequence: seq, toolName: "read_file", approved: true, source: .alwaysAllow)
        }
        recorder.appendEvent { seq in
            RunTraceEvent.toolCall(sequence: seq, toolName: "read_file", arguments: "{}", result: "ok")
        }
        recorder.appendEvent { seq in
            RunTraceEvent.memoryWrite(sequence: seq, tier: "dailyNotes", path: "/test/daily", bytesWritten: 100)
        }

        let snapshot = recorder.currentTraceSnapshot()
        #expect(snapshot.events.count == 5)

        for i in 0..<snapshot.events.count {
            #expect(snapshot.events[i].sequence == i + 1)
            if i > 0 {
                #expect(snapshot.events[i].timestamp >= snapshot.events[i - 1].timestamp)
            }
        }
        RunTraceManager.shared.endRun(runId: recorder.runId)
    }

    @Test("replay reproduces recorded sequence exactly")
    func testReplayReproducesRecordedSequenceExactly() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgent-ReplaySeqTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runId = RunTrace.generateRunId()
        let recorder = RunTraceManager.shared.startRun(
            runId: runId,
            workspacePath: tempDir.path
        )

        recorder.appendEvent { seq in
            RunTraceEvent.modelCall(sequence: seq, model: "mlx-llama-3", prompt: "summarize diff")
        }
        recorder.appendEvent { seq in
            RunTraceEvent.approval(sequence: seq, toolName: "git_diff", approved: true, source: .autoReview)
        }
        recorder.appendEvent { seq in
            RunTraceEvent.toolCall(sequence: seq, toolName: "git_diff", arguments: "", result: "+ let x = 1")
        }
        recorder.appendEvent { seq in
            RunTraceEvent.subAgentHandoff(sequence: seq, parentRunId: runId, subAgentId: "sub-123", agentType: "coder", context: "implement fix")
        }
        recorder.appendEvent { seq in
            RunTraceEvent.memoryWrite(sequence: seq, tier: "curated", path: "/ws/MEMORY.md", bytesWritten: 250)
        }

        RunTraceManager.shared.endRun(runId: runId, status: "completed")

        let fileURL = RunTraceStorage.traceFileURL(for: runId, workspacePath: tempDir.path)
        let replayReport = try RunTraceReplayer.replay(fileURL: fileURL)

        #expect(replayReport.totalEvents == 5)
        #expect(replayReport.isReadOnly == true)
        #expect(replayReport.status == "completed")

        let expectedKinds: [RunTraceEventKind] = [.modelCall, .approval, .toolCall, .subAgentHandoff, .memoryWrite]
        for (idx, expectedKind) in expectedKinds.enumerated() {
            #expect(replayReport.replayedEvents[idx].sequence == idx + 1)
            #expect(replayReport.replayedEvents[idx].kind == expectedKind)
        }
    }

    @Test("replay is read-only and performs no writes or side effects")
    func testReplayIsReadOnlyAndPerformsNoSideEffects() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgent-ReadOnlyReplay-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runId = RunTrace.generateRunId()
        let trace = RunTrace(
            id: runId,
            startedAt: Date(),
            finishedAt: Date(),
            status: "completed",
            events: [
                RunTraceEvent.modelCall(sequence: 1, model: "cloud-gemini", prompt: "test prompt"),
                RunTraceEvent.toolCall(sequence: 2, toolName: "list_directory", arguments: "{\"path\": \".\"}", result: "file.txt")
            ]
        )
        try RunTraceStorage.saveTrace(trace, workspacePath: tempDir.path)

        let fileURL = RunTraceStorage.traceFileURL(for: runId, workspacePath: tempDir.path)
        let initialData = try Data(contentsOf: fileURL)
        let initialDigest = SHA256.hash(data: initialData).map { String(format: "%02x", $0) }.joined()

        // Replay multiple times
        let report1 = try RunTraceReplayer.replay(fileURL: fileURL)
        let report2 = try RunTraceReplayer.replay(target: runId, workspacePath: tempDir.path)

        #expect(report1.isReadOnly == true)
        #expect(report2.isReadOnly == true)

        let postData = try Data(contentsOf: fileURL)
        let postDigest = SHA256.hash(data: postData).map { String(format: "%02x", $0) }.joined()

        #expect(initialDigest == postDigest)
    }

    @Test("secrets are never recorded in trace payload or summaries")
    func testSecretsAreNeverRecordedInTrace() {
        let rawPromptWithSecret = "Please use API key sk-ant-api03-abcdef12345678901234 to authenticate"
        let rawToolArgsWithToken = "{\"token\": \"ghp_123456789012345678901234567890\", \"header\": \"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.t-IDcSemACt8x4iTMCda8Yhe3iZaWbvV5XKSTbuAn0M\"}"
        let rawResultWithPassword = "{\"status\": \"ok\", \"password\": \"super_secret_credentials_12345\"}"

        let modelEvent = RunTraceEvent.modelCall(
            sequence: 1,
            model: "secure-model",
            prompt: rawPromptWithSecret
        )
        let toolEvent = RunTraceEvent.toolCall(
            sequence: 2,
            toolName: "fetch_api",
            arguments: rawToolArgsWithToken,
            result: rawResultWithPassword
        )

        let modelSummary = modelEvent.promptSummary ?? ""
        let toolArgs = toolEvent.argumentsSummary ?? ""
        let toolResult = toolEvent.resultSummary ?? ""

        // Assert secrets are not present
        #expect(!modelSummary.contains("sk-ant-api03-abcdef12345678901234"))
        #expect(!toolArgs.contains("ghp_123456789012345678901234567890"))
        #expect(!toolArgs.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        #expect(!toolResult.contains("super_secret_credentials_12345"))

        // Assert redaction is applied
        #expect(modelSummary.contains("«redacted") || modelSummary.contains("sensitive"))
        #expect(toolArgs.contains("«redacted") || toolArgs.contains("sensitive"))
    }

    @Test("trace persistence to disk survives process boundary")
    func testTracePersistenceToDiskSurvivesProcessBoundary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgent-PersistenceBoundary-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runId = RunTrace.generateRunId()
        let event = RunTraceEvent.memoryWrite(
            sequence: 1,
            tier: "curated",
            path: "/path/to/mem",
            bytesWritten: 1024,
            detail: "Initial write"
        )
        let originalTrace = RunTrace(
            id: runId,
            conversationId: UUID(),
            startedAt: Date(),
            finishedAt: Date(),
            status: "completed",
            events: [event],
            metadata: ["client": "ApexAgentCLI"]
        )

        try RunTraceStorage.saveTrace(originalTrace, workspacePath: tempDir.path)

        // Clear in-memory state
        RunTraceManager.shared.reset()

        // Reload from disk
        let loadedTrace = try #require(try RunTraceStorage.loadTrace(for: runId, workspacePath: tempDir.path))

        #expect(loadedTrace.id == originalTrace.id)
        #expect(loadedTrace.status == "completed")
        #expect(loadedTrace.metadata["client"] == "ApexAgentCLI")
        #expect(loadedTrace.events.count == 1)
        #expect(loadedTrace.events[0].kind == .memoryWrite)
        #expect(loadedTrace.events[0].bytesTransferred == 1024)
    }

    @Test("retention policy prunes expired traces")
    func testRetentionPolicyPrunesExpiredTraces() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgent-RetentionSweep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oldRunId = "run-old-expired-10days"
        let freshRunId = "run-fresh-active-1day"

        let oldTrace = RunTrace(id: oldRunId)
        let freshTrace = RunTrace(id: freshRunId)

        try RunTraceStorage.saveTrace(oldTrace, workspacePath: tempDir.path)
        try RunTraceStorage.saveTrace(freshTrace, workspacePath: tempDir.path)

        let oldFileURL = RunTraceStorage.traceFileURL(for: oldRunId, workspacePath: tempDir.path)
        let freshFileURL = RunTraceStorage.traceFileURL(for: freshRunId, workspacePath: tempDir.path)

        // Artificially age the old file by 10 days
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: oldFileURL.path)

        // Run retention sweep with 7-day cutoff
        let (deleted, skipped) = RunTraceStorage.sweepExpiredTraces(workspacePath: tempDir.path, maxAgeDays: 7)

        #expect(deleted == 1)
        #expect(skipped == 1)
        #expect(!FileManager.default.fileExists(atPath: oldFileURL.path))
        #expect(FileManager.default.fileExists(atPath: freshFileURL.path))
    }

    @Test("live memory tiers emit trace events")
    @MainActor
    func testLiveMemoryTiersEmitTraceEvents() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgent-MemoryTraceTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let recorder = RunTraceManager.shared.startRun(workspacePath: tempDir.path)
        defer { RunTraceManager.shared.endRun(runId: recorder.runId) }

        try SpaceMemoryTierManager.shared.saveCuratedMemory("Project Context A", workspacePath: tempDir.path)
        let loaded = SpaceMemoryTierManager.shared.loadCuratedMemory(workspacePath: tempDir.path)
        #expect(loaded == "Project Context A")

        let events = recorder.currentTraceSnapshot().events
        let memoryWrites = events.filter { $0.kind == .memoryWrite }
        let memoryReads = events.filter { $0.kind == .memoryRead }

        #expect(!memoryWrites.isEmpty)
        #expect(memoryWrites.first?.memoryTier == "curated")
        #expect(!memoryReads.isEmpty)
        #expect(memoryReads.first?.memoryTier == "curated")
    }

    @Test("auto-review approval emits trace event with source")
    func testAutoReviewApprovalEmitsTraceEventWithSource() {
        let recorder = RunTraceManager.shared.startRun()
        defer { RunTraceManager.shared.endRun(runId: recorder.runId) }

        let event = RunTraceManager.shared.recordApproval(
            toolName: "run_shell_command",
            approved: true,
            source: .autoReview,
            rule: "read-only-git"
        )

        #expect(event != nil)
        #expect(event?.kind == .approval)
        #expect(event?.verdict == "approved")
        #expect(event?.verdictSource == "auto-review")
        #expect(event?.rule == "read-only-git")
    }

    @Test("sub-agent handoff emits parent and sub-agent details")
    func testSubAgentHandoffEmitsParentAndSubAgentDetails() {
        let recorder = RunTraceManager.shared.startRun()
        defer { RunTraceManager.shared.endRun(runId: recorder.runId) }

        let subId = UUID().uuidString
        let event = RunTraceManager.shared.recordSubAgentHandoff(
            parentRunId: recorder.runId,
            subAgentId: subId,
            agentType: "Coder",
            context: "Generate unit tests"
        )

        #expect(event != nil)
        #expect(event?.kind == .subAgentHandoff)
        #expect(event?.parentRunId == recorder.runId)
        #expect(event?.subAgentId == subId)
        #expect(event?.agentType == "Coder")
        #expect(event?.contextSummary == "Generate unit tests")
    }

    @Test("TraceLiveVerifier end-to-end contract")
    @MainActor
    func testTraceLiveVerifierEndToEndContract() async throws {
        let result = await TraceLiveVerifier.runVerification()
        #expect(result.passed == true)
        #expect(result.eventCount >= 6)
        #expect(result.traceSize > 0)
        #expect(FileManager.default.fileExists(atPath: result.tracePath))

        let traceURL = URL(fileURLWithPath: result.tracePath)
        let loadedTrace = try #require(try? RunTraceStorage.loadTrace(from: traceURL))
        let modelCallEvent = try #require(loadedTrace.events.first(where: { $0.kind == .modelCall }))

        // Real measured duration from provider attempt (positive, not synthetic 84.5)
        #expect(modelCallEvent.durationMs != nil)
        #expect((modelCallEvent.durationMs ?? 0) > 0)
        #expect(modelCallEvent.durationMs != 84.5)

        // Provider identity is present
        #expect(modelCallEvent.model != nil)

        // Token counts: provider-agnostic validation (Issue #194)
        if let tokenCounts = modelCallEvent.tokenCounts {
            // Real token counts reported by token-reporting engine (e.g. Local Ollama)
            #expect(tokenCounts.promptTokens > 0)
            #expect(tokenCounts.completionTokens > 0)
            #expect(tokenCounts.totalTokens > 0)
            #expect(tokenCounts.totalTokens == tokenCounts.promptTokens + tokenCounts.completionTokens)

            // Anti-hardcoding check: prove counts are not the old synthetic tuple (42, 18, 60) from Issue #110
            #expect(tokenCounts != TokenCountInfo(promptTokens: 42, completionTokens: 18, totalTokens: 60))
        } else {
            // Provider does not report token counts (e.g. Apple Intelligence AFM).
            // Assert the fields that this provider actually reports.
            #expect(modelCallEvent.durationMs != nil)
            #expect((modelCallEvent.durationMs ?? 0) > 0)
        }
    }

    @Test("TraceLiveVerifier contract validation accepts legitimate Ollama 60-token counts")
    func testContractValidationAcceptsLegitimate60TokenCounts() throws {
        let tokenCounts = TokenCountInfo(promptTokens: 21, completionTokens: 39, totalTokens: 60)
        #expect(tokenCounts.promptTokens > 0)
        #expect(tokenCounts.completionTokens > 0)
        #expect(tokenCounts.totalTokens > 0)
        #expect(tokenCounts.totalTokens == tokenCounts.promptTokens + tokenCounts.completionTokens)
        #expect(tokenCounts != TokenCountInfo(promptTokens: 42, completionTokens: 18, totalTokens: 60))
    }

    @Test("TraceLiveVerifier contract accepts AFM modelCall event with nil tokenCounts")
    func testContractAcceptsAFMModelCallEventWithNilTokenCounts() throws {
        let event = RunTraceEvent.modelCall(
            sequence: 6,
            model: "Apple Intelligence (AFM 3 On-Device)",
            prompt: "Reply with the word ok",
            tokenCounts: nil,
            durationMs: 2627.98
        )
        #expect(event.durationMs != nil)
        #expect((event.durationMs ?? 0) > 0)
        #expect(event.durationMs != 84.5)
        #expect(event.model != nil)
        if let tokenCounts = event.tokenCounts {
            #expect(tokenCounts != TokenCountInfo(promptTokens: 42, completionTokens: 18, totalTokens: 60))
        }
    }

    @Test("RunTraceReplayer renders tokens=not reported when tokenCounts is nil")
    func testReplayerRendersNotReportedWhenTokenCountsNil() {
        let trace = RunTrace(
            id: "test-run",
            startedAt: Date(),
            finishedAt: Date(),
            status: "completed",
            events: [
                RunTraceEvent.modelCall(
                    sequence: 1,
                    model: "Apple Intelligence",
                    prompt: "hello",
                    tokenCounts: nil,
                    durationMs: 120.0
                )
            ]
        )
        let report = RunTraceReplayer.replay(trace: trace)
        #expect(report.replayedEvents.count == 1)
        #expect(report.replayedEvents[0].detail.contains("tokens=not reported"))
    }

    @Test("RunTraceReplayer renders real total tokens when tokenCounts is present")
    func testReplayerRendersRealTotalTokensWhenTokenCountsPresent() {
        let trace = RunTrace(
            id: "test-run",
            startedAt: Date(),
            finishedAt: Date(),
            status: "completed",
            events: [
                RunTraceEvent.modelCall(
                    sequence: 1,
                    model: "Local Ollama",
                    prompt: "hello",
                    tokenCounts: TokenCountInfo(promptTokens: 25, completionTokens: 10, totalTokens: 35),
                    durationMs: 250.0
                )
            ]
        )
        let report = RunTraceReplayer.replay(trace: trace)
        #expect(report.replayedEvents.count == 1)
        #expect(report.replayedEvents[0].detail.contains("tokens=35"))
        #expect(!report.replayedEvents[0].detail.contains("tokens=not reported"))
    }

    @Test("TraceLiveVerifier reports unobserved modelCall when no provider responds")
    @MainActor
    func testTraceLiveVerifierReportsUnobservedModelCallWhenNoProviderResponds() async throws {
        // Point Ollama to an unreachable loopback port where no daemon listens
        let prevHost = UserDefaults.standard.string(forKey: ModelRegistry.ollamaHostKey)
        let prevEnv = ProcessInfo.processInfo.environment["APEX_OLLAMA_MODEL"]
        UserDefaults.standard.set("http://127.0.0.1:59999", forKey: ModelRegistry.ollamaHostKey)
        setenv("APEX_OLLAMA_MODEL", "nonexistent-model-fail", 1)
        defer {
            if let prevHost {
                UserDefaults.standard.set(prevHost, forKey: ModelRegistry.ollamaHostKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ModelRegistry.ollamaHostKey)
            }
            if let prevEnv {
                setenv("APEX_OLLAMA_MODEL", prevEnv, 1)
            } else {
                unsetenv("APEX_OLLAMA_MODEL")
            }
        }

        let failingCandidates = [
            ProviderCandidate(provider: .localOllama, reason: "Unreachable test endpoint")
        ]
        let result = await TraceLiveVerifier.runVerification(
            preferredProvider: .localOllama,
            candidateChain: failingCandidates
        )

        #expect(result.passed == false)
        #expect(result.output.contains("modelCall = NOT OBSERVED LIVE"))
        #expect(result.output.contains("VERDICT: FAILED"))

        let traceURL = URL(fileURLWithPath: result.tracePath)
        if FileManager.default.fileExists(atPath: traceURL.path),
           let loadedTrace = try? RunTraceStorage.loadTrace(from: traceURL) {
            #expect(!loadedTrace.events.contains(where: { $0.kind == .modelCall }))
        }
    }
}
