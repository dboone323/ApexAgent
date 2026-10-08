import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 28 — Persistence Corruption Recovery Tests", .serialized)
struct ResilientJSONStoreTests {

    private struct SamplePayload: Codable, Equatable {
        let id: String
        let count: Int
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgentResilientJSONTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Truncated, invalid, and schema-mismatched JSON files are quarantined with exact original bytes and recover cleanly")
    func corruptFilesQuarantinedBytePreservingAndRecover() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ResilientJSONStore(maxEvents: 50)
        let fixedDate = Date(timeIntervalSince1970: 1_791_380_000.123) // 1791380000123 ms

        // 1. Truncated JSON
        let truncatedURL = tempDir.appendingPathComponent("truncated.json")
        let truncatedBytes = Data("{\"id\":\"abc\",\"count\":".utf8)
        try truncatedBytes.write(to: truncatedURL)

        let recoveredTruncated = store.load(
            [SamplePayload].self,
            from: truncatedURL,
            subsystem: "unit_truncated",
            default: [],
            now: { fixedDate }
        )
        #expect(recoveredTruncated.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: truncatedURL.path))

        let expectedTruncatedBackup = tempDir.appendingPathComponent("truncated.json.corrupt-1791380000123")
        #expect(FileManager.default.fileExists(atPath: expectedTruncatedBackup.path))
        let backupTruncatedBytes = try Data(contentsOf: expectedTruncatedBackup)
        #expect(backupTruncatedBytes == truncatedBytes)

        // 2. Invalid JSON syntax
        let invalidURL = tempDir.appendingPathComponent("invalid.json")
        let invalidBytes = Data("<<<NOT_JSON_AT_ALL>>>\0\n".utf8)
        try invalidBytes.write(to: invalidURL)

        let recoveredInvalid = store.load(
            SamplePayload.self,
            from: invalidURL,
            subsystem: "unit_invalid",
            default: SamplePayload(id: "fallback", count: 0),
            now: { fixedDate }
        )
        #expect(recoveredInvalid == SamplePayload(id: "fallback", count: 0))
        #expect(!FileManager.default.fileExists(atPath: invalidURL.path))

        let expectedInvalidBackup = tempDir.appendingPathComponent("invalid.json.corrupt-1791380000123")
        #expect(FileManager.default.fileExists(atPath: expectedInvalidBackup.path))
        #expect(try Data(contentsOf: expectedInvalidBackup) == invalidBytes)

        // 3. Schema-mismatched valid JSON (wrong types for fields)
        let mismatchURL = tempDir.appendingPathComponent("mismatch.json")
        let mismatchBytes = Data("{\"id\":99999,\"count\":\"not_an_int\"}".utf8)
        try mismatchBytes.write(to: mismatchURL)

        let recoveredMismatch = store.load(
            SamplePayload.self,
            from: mismatchURL,
            subsystem: "unit_mismatch",
            default: SamplePayload(id: "default", count: 42),
            now: { fixedDate }
        )
        #expect(recoveredMismatch == SamplePayload(id: "default", count: 42))
        let expectedMismatchBackup = tempDir.appendingPathComponent("mismatch.json.corrupt-1791380000123")
        #expect(try Data(contentsOf: expectedMismatchBackup) == mismatchBytes)

        // Verify all 3 recovery events were recorded with accurate metadata
        let events = store.recentRecoveryEvents()
        #expect(events.count == 3)
        #expect(events.map(\.subsystem) == ["unit_truncated", "unit_invalid", "unit_mismatch"])
        #expect(events[0].byteCount == truncatedBytes.count)
        #expect(events[0].backupPath == expectedTruncatedBackup.path)
        #expect(events[1].byteCount == invalidBytes.count)
        #expect(events[2].byteCount == mismatchBytes.count)

        // Verify subsequent atomic save and load succeeds at the original URL
        let validPayload = SamplePayload(id: "restored", count: 7)
        try store.save(validPayload, to: truncatedURL, prettyPrinted: true)
        let reloaded = store.load(
            SamplePayload.self,
            from: truncatedURL,
            subsystem: "unit_truncated",
            default: SamplePayload(id: "none", count: -1)
        )
        #expect(reloaded == validPayload)
    }

    @Test("CognitiveMemoryEngine recovers from corrupt episodes JSON, preserves backup bytes, and persists new episodes")
    func cognitiveMemoryEngineRecoversFromCorruptJSON() async throws {
        let botId = UUID()
        let botMemoryDir = ApexAgentStoragePaths.directory("memory")
            .appendingPathComponent(botId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: botMemoryDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: botMemoryDir) }

        let episodesURL = botMemoryDir.appendingPathComponent("episodes.json")
        let corruptBytes = Data("[{\"id\": \"not-a-uuid\", \"eventType\": \"broken\"".utf8)
        try corruptBytes.write(to: episodesURL)

        let beforeCount = ResilientJSONStore.shared.recoveryCount
        let episodes = await CognitiveMemoryEngine.shared.allEpisodes(forBotId: botId)
        #expect(episodes.isEmpty)
        #expect(ResilientJSONStore.shared.recoveryCount == beforeCount + 1)

        let latestEvent = try #require(ResilientJSONStore.shared.recentRecoveryEvents(limit: 1).first)
        #expect(latestEvent.subsystem == "CognitiveMemoryEngine")
        #expect(latestEvent.originalPath == episodesURL.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: latestEvent.backupPath)) == corruptBytes)

        // Record a real episode and confirm it round-trips cleanly
        let entry = CognitiveMemoryEngine.EpisodicEntry(
            botId: botId,
            eventType: "recovery_verified",
            summary: "Persisted after corruption recovery"
        )
        await CognitiveMemoryEngine.shared.recordEpisode(entry)
        let reloaded = await CognitiveMemoryEngine.shared.allEpisodes(forBotId: botId)
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.eventType == "recovery_verified")
    }

    @Test("RoutineRecorder, DemoRecorder, and TraceBus recover from corrupt persistence files and preserve corrupt backups")
    @MainActor
    func routineDemoAndTraceBusRecoverFromCorruption() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. RoutineRecorder
        let corruptRoutineURL = tempDir.appendingPathComponent("bad_routine_steps.json")
        let corruptRoutineBytes = Data("[{\"action\":\"click\",\"detail\":12345".utf8)
        try corruptRoutineBytes.write(to: corruptRoutineURL)

        let loadedSteps = RoutineRecorder.shared.loadSteps(from: corruptRoutineURL)
        #expect(loadedSteps.isEmpty)
        let routineBackups = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasPrefix("bad_routine_steps.json.corrupt-") }
        #expect(routineBackups.count == 1)
        let routineBackupURL = tempDir.appendingPathComponent(routineBackups[0])
        #expect(try Data(contentsOf: routineBackupURL) == corruptRoutineBytes)

        // 2. DemoRecorder
        let corruptDemoURL = tempDir.appendingPathComponent("bad_demo_actions.json")
        let corruptDemoBytes = Data("{corrupt-demo-payload".utf8)
        try corruptDemoBytes.write(to: corruptDemoURL)

        let demoRecorder = DemoRecorder()
        let loadedActions = demoRecorder.loadActions(from: corruptDemoURL)
        #expect(loadedActions.isEmpty)
        let demoBackups = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasPrefix("bad_demo_actions.json.corrupt-") }
        #expect(demoBackups.count == 1)
        let demoBackupURL = tempDir.appendingPathComponent(demoBackups[0])
        #expect(try Data(contentsOf: demoBackupURL) == corruptDemoBytes)

        // 3. TraceBus persistence
        let traceURL = tempDir.appendingPathComponent("traces.json")
        let corruptTraceBytes = Data("[{\"traceId\":\"oops\"".utf8)
        try corruptTraceBytes.write(to: traceURL)

        let loadedTraces = TraceBus.shared.loadSnapshot(from: traceURL)
        #expect(loadedTraces.isEmpty)
        let traceBackups = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasPrefix("traces.json.corrupt-") }
        #expect(traceBackups.count == 1)
        let traceBackupURL = tempDir.appendingPathComponent(traceBackups[0])
        #expect(try Data(contentsOf: traceBackupURL) == corruptTraceBytes)
    }
}
