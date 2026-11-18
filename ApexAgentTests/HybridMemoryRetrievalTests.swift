import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Hybrid Memory Retrieval Tests (Issue #81)")
struct HybridMemoryRetrievalTests {

    private func createTempWorkspace(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // MARK: - 1. Exact-Range Retrieval Tests (memory_get)

    @Test("Exact-range retrieval: returned span matches source lines exactly")
    @MainActor
    func testExactRangeRetrievalMatchesSourceSpan() throws {
        let ws = try createTempWorkspace(prefix: "test-exact-range")
        defer { try? FileManager.default.removeItem(at: ws) }

        let testContent = """
        Line 1: System initialization preamble
        Line 2: Configuration loader invoked
        Line 3: Database connection pool configured on port 5432
        Line 4: Cache cluster attached with Redis Sentinel
        Line 5: Health checks reporting healthy status
        Line 6: Background worker threads spawned
        Line 7: Web server listening on port 8080
        """
        let filePath = ws.appendingPathComponent("system.md").path
        try testContent.write(toFile: filePath, atomically: true, encoding: .utf8)

        let span = try HybridMemoryRetriever.shared.getExactSpan(
            filePath: filePath,
            startLine: 3,
            endLine: 5,
            workspacePath: ws.path
        )

        let expectedSpan = """
        Line 3: Database connection pool configured on port 5432
        Line 4: Cache cluster attached with Redis Sentinel
        Line 5: Health checks reporting healthy status
        """

        #expect(span.startLine == 3)
        #expect(span.endLine == 5)
        #expect(span.totalLinesInFile == 7)
        #expect(span.content == expectedSpan)
        #expect(span.citation == "[system.md:3-5]")
    }

    @Test("Exact-range retrieval: single line span format and content")
    @MainActor
    func testExactRangeRetrievalSingleLineSpan() throws {
        let ws = try createTempWorkspace(prefix: "test-single-line")
        defer { try? FileManager.default.removeItem(at: ws) }

        let testContent = """
        Line 1: Alpha
        Line 2: Beta
        Line 3: Gamma
        Line 4: Delta
        """
        let filePath = ws.appendingPathComponent("notes.md").path
        try testContent.write(toFile: filePath, atomically: true, encoding: .utf8)

        let span = try HybridMemoryRetriever.shared.getExactSpan(
            filePath: filePath,
            startLine: 2,
            endLine: 2,
            workspacePath: ws.path
        )

        #expect(span.startLine == 2)
        #expect(span.endLine == 2)
        #expect(span.content == "Line 2: Beta")
        #expect(span.citation == "[notes.md:2]")
    }

    @Test("Exact-range retrieval: safe bounds clamping on inverted or out-of-range queries")
    @MainActor
    func testExactRangeRetrievalBoundsClamping() throws {
        let ws = try createTempWorkspace(prefix: "test-bounds-clamping")
        defer { try? FileManager.default.removeItem(at: ws) }

        let testContent = """
        First line
        Second line
        Third line
        """
        let filePath = ws.appendingPathComponent("data.md").path
        try testContent.write(toFile: filePath, atomically: true, encoding: .utf8)

        // Query out-of-range bounds [-10 ... 100] -> should clamp to [1 ... 3]
        let span = try HybridMemoryRetriever.shared.getExactSpan(
            filePath: filePath,
            startLine: -10,
            endLine: 100,
            workspacePath: ws.path
        )

        #expect(span.startLine == 1)
        #expect(span.endLine == 3)
        #expect(span.totalLinesInFile == 3)
        #expect(span.content == testContent)
        #expect(span.citation == "[data.md:1-3]")
    }

    // MARK: - 2. Chunking & Line Number Integrity Tests

    @Test("Chunking: preserves exact line number integrity and paragraph boundaries")
    @MainActor
    func testChunkingPreservesLineNumberIntegrity() throws {
        let markdown = """
        # Architectural Overview
        ApexAgent is a native macOS application written in Swift.
        It uses local SwiftData storage and non-blocking actors.

        ## Memory System
        Memory is organized into files-first tiers.
        Tier 1 is curated MEMORY.md for team knowledge.
        Tier 2 is daily notes indexed by date.

        ## Verification Protocol
        All changes require real functional tests.
        No dummy mocks or skipped assertions.
        """

        let chunks = HybridMemoryRetriever.chunk(
            text: markdown,
            filePath: "/tmp/sample.md",
            relativePath: "sample.md",
            tier: "curated"
        )

        #expect(!chunks.isEmpty)

        let lines = markdown.components(separatedBy: "\n")

        for chunk in chunks {
            #expect(chunk.startLine >= 1)
            #expect(chunk.endLine >= chunk.startLine)
            #expect(chunk.endLine <= lines.count)

            // Extract exactly lines from original text
            let slice = lines[(chunk.startLine - 1)...(chunk.endLine - 1)]
            let extracted = slice.joined(separator: "\n")
            #expect(extracted == chunk.content)

            // Citation must match bounds
            if chunk.startLine == chunk.endLine {
                #expect(chunk.citation == "[sample.md:\(chunk.startLine)]")
            } else {
                #expect(chunk.citation == "[sample.md:\(chunk.startLine)-\(chunk.endLine)]")
            }
        }
    }

    // MARK: - 3. Ranking & Search Relevance Tests

    @Test("Ranking: hybrid search returns the most relevant memory first")
    @MainActor
    func testHybridMemorySearchRanking() throws {
        let ws = try createTempWorkspace(prefix: "test-ranking")
        defer { try? FileManager.default.removeItem(at: ws) }

        // Seed distinct memory sections across tiers
        let memoryContent = """
        # Database Infrastructure
        Postgres connection pool configured with 20 max connections.
        Replica sync interval is set to 500 milliseconds.

        # Subagent Orchestration
        Supervisor coordinator delegates specialized sub-agents.
        Each worker operates in an isolated workspace with clear brief.

        # Thermal Throttling
        On high CPU load, long-running batch jobs pause for cooldown.
        Energy peak hours are monitored to avoid fan noise.
        """
        let memoryFile = ws.appendingPathComponent("MEMORY.md").path
        try memoryContent.write(toFile: memoryFile, atomically: true, encoding: .utf8)

        let retriever = HybridMemoryRetriever.shared
        retriever.clearCache()

        // Search for subagent coordination
        let results = retriever.search(
            query: "subagent supervisor coordinator delegation",
            workspacePath: ws.path,
            limit: 5
        )

        #expect(!results.isEmpty)
        let topResult = results[0]

        // Top result must be the Subagent Orchestration chunk
        #expect(topResult.content.contains("Subagent Orchestration"))
        #expect(topResult.content.contains("Supervisor coordinator delegates"))
        #expect(topResult.score > 0.4)

        // It must outrank thermal throttling and database
        if results.count > 1 {
            #expect(topResult.score >= results[1].score)
        }
    }

    // MARK: - 4. Citation Presence in Search Results

    @Test("Citation presence: all search results carry accurate file/line citations")
    @MainActor
    func testCitationPresenceInAllSearchResults() throws {
        let ws = try createTempWorkspace(prefix: "test-citations")
        defer { try? FileManager.default.removeItem(at: ws) }

        let content = """
        # Rules of Engagement
        Always verify features with live executions.
        Never bypass git pre-push hooks or CI gates.
        Keep code clean and strictly typed.
        """
        let path = ws.appendingPathComponent("MEMORY.md").path
        try content.write(toFile: path, atomically: true, encoding: .utf8)

        let retriever = HybridMemoryRetriever.shared
        retriever.clearCache()

        let results = retriever.search(
            query: "verify features with live executions",
            workspacePath: ws.path,
            limit: 3
        )

        #expect(!results.isEmpty)
        for r in results {
            #expect(!r.citation.isEmpty)
            #expect(r.citation.hasPrefix("["))
            #expect(r.citation.hasSuffix("]"))
            #expect(r.citation.contains(":"))
            #expect(r.startLine >= 1)
            #expect(r.endLine >= r.startLine)
            #expect(r.filePath == path)
        }
    }

    // MARK: - 5. Keyword + Vector Fusion Tests

    @Test("Keyword and Vector Fusion: both signals contribute to ranked score")
    @MainActor
    func testKeywordAndVectorFusionEachSideContributes() {
        // 1. Keyword score alone provides positive score
        let kwOnlyScore = HybridMemoryRetriever.computeKeywordScore(
            chunkTokens: ["postgresql", "database", "port", "connection"],
            chunkContent: "Postgres database listening on port 5432.",
            query: "postgresql database",
            queryTokens: ["postgresql", "database"]
        )
        #expect(kwOnlyScore > 0.4)

        // 2. Vector score alone provides positive score
        let mockVec1 = [Double](repeating: 0.5, count: 512)
        let mockVec2 = [Double](repeating: 0.5, count: 512)
        let vecScore = HybridMemoryRetriever.computeVectorScore(
            queryEmbedding: mockVec1,
            chunkEmbedding: mockVec2
        )
        #expect(vecScore > 0.9)

        // 3. Fused score combines both signals
        let fusedDual = HybridMemoryRetriever.fuseScores(vectorScore: 0.8, keywordScore: 0.8)
        let fusedVecOnly = HybridMemoryRetriever.fuseScores(vectorScore: 0.8, keywordScore: 0.0)
        let fusedKwOnly = HybridMemoryRetriever.fuseScores(vectorScore: 0.0, keywordScore: 0.8)

        // Dual match receives synergy bonus and must outrank single-signal matches
        #expect(fusedDual > fusedVecOnly)
        #expect(fusedDual > fusedKwOnly)
        #expect(fusedVecOnly > 0.0)
        #expect(fusedKwOnly > 0.0)
    }

    // MARK: - 6. Tool Execution Tests

    @Test("MemorySearchTool and MemoryGetTool: real tool invocation and output formatting")
    @MainActor
    func testMemoryToolsExecution() async throws {
        let ws = try createTempWorkspace(prefix: "test-tools")
        defer { try? FileManager.default.removeItem(at: ws) }

        let docContent = """
        # Security Policy
        All credentials must be stored in macOS Keychain.
        Plaintext API keys in repositories are strictly forbidden.
        """
        let filePath = ws.appendingPathComponent("MEMORY.md").path
        try docContent.write(toFile: filePath, atomically: true, encoding: .utf8)

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = ws.path

        // Test MemorySearchTool
        let searchTool = MemorySearchTool(orchestrator: orchestrator)
        let searchArgs = MemorySearchTool.Arguments(
            query: "macOS Keychain credentials",
            category: nil,
            limit: 3
        )
        let searchResult = try await searchTool.call(arguments: searchArgs)

        #expect(searchResult.contains("Found"))
        #expect(searchResult.contains("Source: [MEMORY.md:"))
        #expect(searchResult.contains("macOS Keychain"))

        // Test MemoryGetTool
        let getTool = MemoryGetTool(orchestrator: orchestrator)
        let getArgs = MemoryGetTool.Arguments(
            filePath: filePath,
            startLine: 1,
            endLine: 3
        )
        let getResult = try await getTool.call(arguments: getArgs)

        #expect(getResult.contains("Source: [MEMORY.md:1-3]"))
        #expect(getResult.contains("All credentials must be stored in macOS Keychain"))
    }

    // MARK: - 7. Context Assembly Wiring with Citations

    @Test("Context Assembly Wiring: instructions carry citations and citation directive")
    @MainActor
    func testContextAssemblyWiringWithCitations() throws {
        let ws = try createTempWorkspace(prefix: "test-context-wiring")
        defer { try? FileManager.default.removeItem(at: ws) }

        let manager = SpaceMemoryTierManager.shared
        try manager.saveCuratedMemory("Rule: No deployments on Friday without sign-off.", workspacePath: ws.path)
        try manager.savePersona("Persona: Efficient engineering assistant.", workspacePath: ws.path)
        try manager.saveUserContext("User: Principal Engineer on Mac platform.", workspacePath: ws.path)

        // 1. Verify buildComposedMemoryInstructions includes citations and directive
        let instructions = manager.buildComposedMemoryInstructions(workspacePath: ws.path)

        #expect(instructions.contains("=== SPACE CURATED MEMORY (MEMORY.md) ==="))
        #expect(instructions.contains("[Source: MEMORY.md:1-"))
        #expect(instructions.contains("=== AGENT PERSONA & BEHAVIOUR (PERSONA.md) ==="))
        #expect(instructions.contains("[Source: PERSONA.md:1-"))
        #expect(instructions.contains("=== USER PROFILE & PREFERENCES (USER.md) ==="))
        #expect(instructions.contains("[Source: USER.md:1-"))
        #expect(instructions.contains("CITATION DIRECTIVE: When citing facts from memory"))

        // 2. Verify retrieveRelevantContext produces cited excerpts
        let retrieved = manager.retrieveRelevantContext(
            query: "deployments on Friday",
            workspacePath: ws.path,
            limit: 2
        )

        #expect(!retrieved.isEmpty)
        #expect(retrieved.contains("=== RETRIEVED MEMORY CONTEXT (HYBRID SEARCH) ==="))
        #expect(retrieved.contains("Source: [MEMORY.md:"))
        #expect(retrieved.contains("No deployments on Friday"))
    }
}
