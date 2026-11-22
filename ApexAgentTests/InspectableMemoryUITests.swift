import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Inspectable Memory UI Tests (Issue #83)")
struct InspectableMemoryUITests {

    private func createTempWorkspace(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // MARK: - 1. Topic Loading and Grouping

    @Test("Topic loading: extracts facts and groups them into clean topics across tiers")
    @MainActor
    func testInspectableMemoryTopicsLoadingAndGrouping() throws {
        let ws = try createTempWorkspace(prefix: "test-topics-loading")
        defer { try? FileManager.default.removeItem(at: ws) }

        // Seed MEMORY.md
        let curated = """
        # Space Memory
        - [MEMORY.md:2] PostgreSQL cluster active on port 5432 (key: db_port)
        - [MEMORY.md:3] Cache layer backed by Valkey (key: cache_service)
        - [MEMORY.md:4] Secondary replica on port 5433 (key: db_port)
        """
        try curated.write(to: ws.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)

        // Seed Daily Note
        let dailyDir = ws.appendingPathComponent("daily", isDirectory: true)
        try FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let note = """
        # Daily: 2026-11-22
        - [daily/2026-11-22.md:2] Deployed v2.4 to cluster (key: deployment_version)
        """
        try note.write(to: dailyDir.appendingPathComponent("2026-11-22.md"), atomically: true, encoding: .utf8)

        let groups = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: ws.path)
        #expect(groups.count == 3)

        let topicNames = groups.map(\.topic).sorted()
        #expect(topicNames == ["cache_service", "db_port", "deployment_version"])

        let dbPortGroup = groups.first { $0.topic == "db_port" }
        #expect(dbPortGroup != nil)
        #expect(dbPortGroup?.items.count == 2)
        #expect(dbPortGroup?.items.first?.tier == "curated")

        let deployGroup = groups.first { $0.topic == "deployment_version" }
        #expect(deployGroup != nil)
        #expect(deployGroup?.items.first?.tier == "daily")
        #expect(deployGroup?.items.first?.sourceCitation == "[daily/2026-11-22.md:2]")
    }

    // MARK: - 2. Edit Memory Fact

    @Test("Edit fact: updates statement on disk and reflects in hybrid retrieval")
    @MainActor
    func testEditMemoryFactUpdatesDiskAndClearsCache() throws {
        let ws = try createTempWorkspace(prefix: "test-edit-fact")
        defer { try? FileManager.default.removeItem(at: ws) }

        let curated = """
        # Space Memory
        - [MEMORY.md:2] Hostname set to old.gateway.local (key: gateway_host)
        """
        let filePath = ws.appendingPathComponent("MEMORY.md").path
        try curated.write(toFile: filePath, atomically: true, encoding: .utf8)

        let groups = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: ws.path)
        guard let item = groups.first?.items.first else {
            Issue.record("Expected to load initial item")
            return
        }

        try SpaceMemoryInspectorManager.shared.editItem(
            item,
            newKey: "gateway_host",
            newStatement: "Hostname migrated to new.gateway.prod for high availability",
            workspacePath: ws.path
        )

        let updatedContent = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(updatedContent.contains("new.gateway.prod"))
        #expect(!updatedContent.contains("old.gateway.local"))

        let searchResults = HybridMemoryRetriever.shared.search(
            query: "new gateway prod",
            workspacePath: ws.path,
            limit: 5
        )
        #expect(!searchResults.isEmpty)
        #expect(searchResults.first?.content.contains("new.gateway.prod") == true)
    }

    // MARK: - 3. Delete Memory Fact and Topic

    @Test("Delete fact & topic: removes items and entire topic groups cleanly from disk")
    @MainActor
    func testDeleteMemoryFactAndTopicRemovesFromDisk() throws {
        let ws = try createTempWorkspace(prefix: "test-delete-fact")
        defer { try? FileManager.default.removeItem(at: ws) }

        let curated = """
        # Space Memory
        - [MEMORY.md:2] Keep this entry forever (key: keep_me)
        - [MEMORY.md:3] Delete this single entry (key: delete_me)
        - [MEMORY.md:4] Another fact under delete topic (key: delete_topic)
        """
        let filePath = ws.appendingPathComponent("MEMORY.md").path
        try curated.write(toFile: filePath, atomically: true, encoding: .utf8)

        var groups = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: ws.path)
        guard let deleteItem = groups.first(where: { $0.topic == "delete_me" })?.items.first else {
            Issue.record("Expected to find item under delete_me")
            return
        }

        // Delete single item
        try SpaceMemoryInspectorManager.shared.deleteItem(deleteItem, workspacePath: ws.path)
        groups = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: ws.path)
        #expect(groups.first(where: { $0.topic == "delete_me" }) == nil)
        #expect(groups.first(where: { $0.topic == "keep_me" }) != nil)

        // Delete entire topic
        try SpaceMemoryInspectorManager.shared.deleteTopic("delete_topic", workspacePath: ws.path)
        groups = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: ws.path)
        #expect(groups.first(where: { $0.topic == "delete_topic" }) == nil)
        #expect(groups.count == 1)
        #expect(groups.first?.topic == "keep_me")
    }

    // MARK: - 4. Pause / Resume Topic Excludes from Retrieval

    @Test("Pause topic: excludes matching memories from retrieval until resumed")
    @MainActor
    func testPauseTopicExcludesFromRetrievalAndResumeRestores() throws {
        let ws = try createTempWorkspace(prefix: "test-pause-retrieval")
        defer { try? FileManager.default.removeItem(at: ws) }

        let curated = """
        # Space Memory

        ## Telemetry Section
        - [MEMORY.md:4] Apollo telemetry service runs on port 9090 (key: telemetry_apollo)

        ## Core API Section
        - [MEMORY.md:7] Core API server runs on port 8080 (key: core_api)
        """
        try curated.write(to: ws.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)

        // 1. Initial retrieval finds both
        let initialResults = HybridMemoryRetriever.shared.search(
            query: "apollo telemetry",
            workspacePath: ws.path,
            limit: 5
        )
        #expect(!initialResults.isEmpty)
        #expect(initialResults.first?.content.contains("9090") == true)

        // 2. Pause topic
        SpaceMemoryInspectorManager.shared.pauseTopic("telemetry_apollo", workspacePath: ws.path)
        #expect(SpaceMemoryInspectorManager.shared.isTopicPaused("telemetry_apollo", workspacePath: ws.path) == true)

        // 3. Retrieval while paused excludes it
        let pausedResults = HybridMemoryRetriever.shared.search(
            query: "apollo telemetry",
            workspacePath: ws.path,
            limit: 5
        )
        let containsPaused = pausedResults.contains { $0.content.contains("telemetry_apollo") }
        #expect(!containsPaused)

        // Unpaused core_api should still be searchable
        let coreResults = HybridMemoryRetriever.shared.search(
            query: "core api",
            workspacePath: ws.path,
            limit: 5
        )
        #expect(!coreResults.isEmpty)

        // 4. Resume topic restores retrieval
        SpaceMemoryInspectorManager.shared.resumeTopic("telemetry_apollo", workspacePath: ws.path)
        #expect(SpaceMemoryInspectorManager.shared.isTopicPaused("telemetry_apollo", workspacePath: ws.path) == false)

        let resumedResults = HybridMemoryRetriever.shared.search(
            query: "apollo telemetry",
            workspacePath: ws.path,
            limit: 5
        )
        #expect(!resumedResults.isEmpty)
        #expect(resumedResults.first?.content.contains("9090") == true)
    }

    // MARK: - 5. Source Panel Provenance

    @Test("Source panel provenance: provides exact file:line citations and verbatim provenance")
    @MainActor
    func testSourcePanelProvenanceCitationCorrectness() throws {
        let ws = try createTempWorkspace(prefix: "test-provenance")
        defer { try? FileManager.default.removeItem(at: ws) }

        let dailyDir = ws.appendingPathComponent("daily", isDirectory: true)
        try FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let note = """
        # Daily: 2026-11-22
        - [daily/2026-11-22.md:2] Code audit passed with zero security defects (key: security_audit)
        """
        try note.write(to: dailyDir.appendingPathComponent("2026-11-22.md"), atomically: true, encoding: .utf8)

        let groups = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: ws.path)
        guard let item = groups.first?.items.first else {
            Issue.record("Expected to load security_audit fact")
            return
        }

        let provenance = SpaceMemoryInspectorManager.shared.provenance(for: item)
        #expect(provenance.key == "security_audit")
        #expect(provenance.sourceCitation == "[daily/2026-11-22.md:2]")
        #expect(provenance.relativePath == "daily/2026-11-22.md")
        #expect(provenance.lineRange == "Line 2")
        #expect(provenance.tier == "daily")
        #expect(provenance.verbatimSourceSnippet.contains("Code audit passed with zero security defects"))
        #expect(provenance.provenanceAnswer.contains("The agent holds this belief because it was explicitly recorded in daily/2026-11-22.md"))
    }

    // MARK: - 6. No-Memory Session Protection

    @Test("No-memory session: flushSession writes nothing to disk when no-memory mode is active")
    @MainActor
    func testNoMemorySessionModeWritesNothingToDisk() throws {
        let ws = try createTempWorkspace(prefix: "test-nomemory-mode")
        defer { try? FileManager.default.removeItem(at: ws) }

        let curated = """
        # Space Memory
        - [MEMORY.md:2] Initial persistent knowledge (key: init_fact)
        """
        let curatedPath = ws.appendingPathComponent("MEMORY.md").path
        try curated.write(toFile: curatedPath, atomically: true, encoding: .utf8)

        let initialSize = try Data(contentsOf: URL(fileURLWithPath: curatedPath)).count

        // Activate No-Memory mode
        SpaceMemoryInspectorManager.shared.setNoMemoryMode(true, workspacePath: ws.path)
        #expect(SpaceMemoryInspectorManager.shared.isNoMemoryModeEnabled(workspacePath: ws.path) == true)

        let flushResult = try SpaceMemoryTierManager.shared.flushSession(
            explicitFacts: ["Confidential turn fact: secret token xyz"],
            workspacePath: ws.path
        )

        #expect(flushResult.factsFlushedCount == 0)
        #expect(flushResult.isIdempotent == true)

        let currentSize = try Data(contentsOf: URL(fileURLWithPath: curatedPath)).count
        #expect(currentSize == initialSize)

        // Deactivate No-Memory mode
        SpaceMemoryInspectorManager.shared.setNoMemoryMode(false, workspacePath: ws.path)
        #expect(SpaceMemoryInspectorManager.shared.isNoMemoryModeEnabled(workspacePath: ws.path) == false)
    }

    // MARK: - 7. Markdown Export / Import Round-Trip

    @Test("Markdown export/import: exports clean markdown and round-trips topics and pause states")
    @MainActor
    func testMarkdownExportAndImportRoundTrip() throws {
        let ws = try createTempWorkspace(prefix: "test-roundtrip")
        defer { try? FileManager.default.removeItem(at: ws) }

        let curated = """
        # Space Memory
        - [MEMORY.md:2] Kubernetes cluster running in us-central1 (key: k8s_region)
        - [MEMORY.md:3] Billing plan configured as enterprise (key: billing_tier)
        """
        try curated.write(to: ws.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)

        // Pause one topic
        SpaceMemoryInspectorManager.shared.pauseTopic("billing_tier", workspacePath: ws.path)

        // Export to Markdown
        let exported = SpaceMemoryInspectorManager.shared.exportMarkdown(workspacePath: ws.path)
        #expect(exported.contains("## Topic: k8s_region (Status: Active)"))
        #expect(exported.contains("## Topic: billing_tier (Status: Paused)"))
        #expect(exported.contains("Kubernetes cluster running in us-central1"))

        // Wipe MEMORY.md and unpause
        try "# Space Memory\n".write(to: ws.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        SpaceMemoryInspectorManager.shared.resumeTopic("billing_tier", workspacePath: ws.path)
        HybridMemoryRetriever.shared.clearCache()

        var groups = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: ws.path)
        #expect(groups.isEmpty)

        // Re-import
        let importResult = try SpaceMemoryInspectorManager.shared.importMarkdown(exported, workspacePath: ws.path)
        #expect(importResult.isSuccess == true)
        #expect(importResult.topicsImported == 2)
        #expect(importResult.factsImported == 2)

        groups = SpaceMemoryInspectorManager.shared.loadTopics(workspacePath: ws.path)
        #expect(groups.count == 2)

        let k8sGroup = groups.first { $0.topic == "k8s_region" }
        #expect(k8sGroup != nil)
        #expect(k8sGroup?.isPaused == false)

        let billingGroup = groups.first { $0.topic == "billing_tier" }
        #expect(billingGroup != nil)
        #expect(billingGroup?.isPaused == true)
    }

    // MARK: - 8. Live Verifier E2E Gate

    @Test("Live Verifier: executes full native check matrix and passes all 5 verdicts")
    @MainActor
    func testInspectableMemoryLiveVerifierPassesAllFiveVerdicts() {
        let result = SpaceMemoryLiveVerifier.runVerification(writeLogTo: "runs/issue83/live-verify.log")
        #expect(result.passed == true)
        #expect(result.output.contains("VERDICT 1: PASS"))
        #expect(result.output.contains("VERDICT 2: PASS"))
        #expect(result.output.contains("VERDICT 3: PASS"))
        #expect(result.output.contains("VERDICT 4: PASS"))
        #expect(result.output.contains("VERDICT 5: PASS"))
        #expect(result.output.contains("LIVE VERIFICATION RESULT: PASS"))
    }
}
