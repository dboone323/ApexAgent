import XCTest
import Foundation
import AppKit
import SharedKit
@testable import ApexAgentCore

// MARK: - CognitiveMemoryTests: Real Functional Tests for 4-Tier Memory Architecture
//
// Strict Zero-Mock Policy: all validations use real FileManager + JSONEncoder persistence,
// real data structures, real Bot UUIDs, and deterministic assertions.

@MainActor
final class CognitiveMemoryTests: XCTestCase {

    let engine = CognitiveMemoryEngine.shared
    var testBotId: UUID!

    override func setUp() async throws {
        try await super.setUp()
        testBotId = UUID()
        engine.clearWorkingContext(forBotId: testBotId)
    }

    override func tearDown() async throws {
        // Clean up test bot memory directory
        let home = FileManager.default.homeDirectoryForCurrentUser
        let botDir = home.appendingPathComponent(".apex/memory/\(testBotId.uuidString)")
        try? FileManager.default.removeItem(at: botDir)
        try await super.tearDown()
    }

    // MARK: - Tier 1: Working Memory

    func testWorkingMemorySetAndGet() {
        let context = "Apex is working on SwiftUI refactoring task #42"
        engine.setWorkingContext(context, forBotId: testBotId)
        let retrieved = engine.getWorkingContext(forBotId: testBotId)
        XCTAssertEqual(retrieved, context, "Working memory must return the exact stored context")
    }

    func testWorkingMemoryClear() {
        engine.setWorkingContext("Some context", forBotId: testBotId)
        engine.clearWorkingContext(forBotId: testBotId)
        let retrieved = engine.getWorkingContext(forBotId: testBotId)
        XCTAssertTrue(retrieved.isEmpty, "Working memory must be empty after clearing")
    }

    func testWorkingMemoryIsolatedPerBot() {
        let botA = UUID()
        let botB = UUID()
        engine.setWorkingContext("Context A", forBotId: botA)
        engine.setWorkingContext("Context B", forBotId: botB)
        XCTAssertEqual(engine.getWorkingContext(forBotId: botA), "Context A")
        XCTAssertEqual(engine.getWorkingContext(forBotId: botB), "Context B")
        engine.clearWorkingContext(forBotId: botA)
        engine.clearWorkingContext(forBotId: botB)
    }

    // MARK: - Tier 2: Episodic Memory

    func testEpisodicMemoryRecordAndRetrieve() {
        let entry = CognitiveMemoryEngine.EpisodicEntry(
            botId: testBotId,
            eventType: "tool_call",
            summary: "Ran xcodebuild and it succeeded",
            metadata: ["tool": "run_shell_command", "exitCode": "0"]
        )
        engine.recordEpisode(entry)

        let recent = engine.recentEpisodes(forBotId: testBotId, limit: 10)
        XCTAssertFalse(recent.isEmpty, "Recent episodes must not be empty after recording")
        let found = recent.first(where: { $0.id == entry.id })
        XCTAssertNotNil(found, "Recorded episode must be retrievable")
        XCTAssertEqual(found?.summary, "Ran xcodebuild and it succeeded")
        XCTAssertEqual(found?.metadata["tool"], "run_shell_command")
    }

    func testEpisodicMemoryPersistsToDisk() throws {
        let entry = CognitiveMemoryEngine.EpisodicEntry(
            botId: testBotId,
            eventType: "user_message",
            summary: "User asked about Swift concurrency",
            metadata: [:]
        )
        engine.recordEpisode(entry)

        // Verify the file was actually written
        let home = FileManager.default.homeDirectoryForCurrentUser
        let episodesFile = home.appendingPathComponent(".apex/memory/\(testBotId.uuidString)/episodes.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: episodesFile.path),
                      "episodes.json must exist on disk after recording")

        let data = try Data(contentsOf: episodesFile)
        XCTAssertGreaterThan(data.count, 0, "episodes.json must contain data")
        let decoded = try JSONDecoder().decode([CognitiveMemoryEngine.EpisodicEntry].self, from: data)
        XCTAssertTrue(decoded.contains(where: { $0.id == entry.id }),
                      "Persisted file must contain the recorded episode")
    }

    func testEpisodicMemoryReturnsRecentFirst() {
        let old = CognitiveMemoryEngine.EpisodicEntry(
            id: UUID(), timestamp: Date().addingTimeInterval(-3600),
            botId: testBotId, eventType: "tool_call",
            summary: "Old episode", metadata: [:]
        )
        let fresh = CognitiveMemoryEngine.EpisodicEntry(
            id: UUID(), timestamp: Date(),
            botId: testBotId, eventType: "bot_response",
            summary: "New episode", metadata: [:]
        )
        engine.recordEpisode(old)
        engine.recordEpisode(fresh)

        let recent = engine.recentEpisodes(forBotId: testBotId, limit: 1)
        XCTAssertEqual(recent.first?.summary, "New episode",
                       "recentEpisodes with limit:1 must return the most recent entry")
    }

    func testAllEpisodesReturnsAll() {
        for i in 1...5 {
            engine.recordEpisode(CognitiveMemoryEngine.EpisodicEntry(
                botId: testBotId, eventType: "tool_call",
                summary: "Episode \(i)", metadata: [:]
            ))
        }
        let all = engine.allEpisodes(forBotId: testBotId)
        XCTAssertEqual(all.count, 5, "allEpisodes must return all 5 recorded episodes")
    }

    // MARK: - Tier 3: Semantic Memory

    func testSemanticFactAssertionAndQuery() {
        let fact = CognitiveMemoryEngine.SemanticFact(
            botId: testBotId,
            subject: "ApexAgent",
            predicate: "uses_model",
            object: "Gemini Flash",
            confidence: 0.95,
            source: "user"
        )
        engine.assertFact(fact)

        let results = engine.queryFacts(subject: "ApexAgent", predicate: "uses_model", object: nil)
        XCTAssertFalse(results.isEmpty, "Query must return the asserted fact")
        XCTAssertEqual(results.first?.object, "Gemini Flash")
        XCTAssertEqual(results.first?.confidence, 0.95)
    }

    func testSemanticFactWildcardQuery() {
        let f1 = CognitiveMemoryEngine.SemanticFact(botId: testBotId, subject: "Bot1", predicate: "runs_on", object: "macOS", confidence: 1.0, source: "user")
        let f2 = CognitiveMemoryEngine.SemanticFact(botId: testBotId, subject: "Bot2", predicate: "runs_on", object: "iOS", confidence: 1.0, source: "user")
        engine.assertFact(f1)
        engine.assertFact(f2)

        let results = engine.queryFacts(subject: nil, predicate: "runs_on", object: nil)
        XCTAssertGreaterThanOrEqual(results.count, 2, "Wildcard predicate query must return all matching facts")
    }

    func testSemanticFactDeduplication() {
        let fact1 = CognitiveMemoryEngine.SemanticFact(botId: testBotId, subject: "X", predicate: "is", object: "Y", confidence: 0.5, source: "inferred")
        let fact2 = CognitiveMemoryEngine.SemanticFact(botId: testBotId, subject: "X", predicate: "is", object: "Y", confidence: 0.9, source: "user")
        engine.assertFact(fact1)
        engine.assertFact(fact2)

        let results = engine.queryFacts(subject: "X", predicate: "is", object: "Y")
        XCTAssertEqual(results.count, 1, "Re-asserting the same S-P-O triple must deduplicate, not duplicate")
    }

    func testSemanticFactRetraction() {
        let fact = CognitiveMemoryEngine.SemanticFact(botId: testBotId, subject: "Retract", predicate: "this", object: "fact", confidence: 1.0, source: "test")
        engine.assertFact(fact)

        let before = engine.queryFacts(subject: "Retract", predicate: "this", object: "fact")
        XCTAssertEqual(before.count, 1, "Fact must exist before retraction")

        engine.retractFact(id: fact.id)

        let after = engine.queryFacts(subject: "Retract", predicate: "this", object: "fact")
        XCTAssertEqual(after.count, 0, "Fact must be removed after retraction")
    }

    func testSemanticKeywordSearch() {
        let fact = CognitiveMemoryEngine.SemanticFact(botId: testBotId, subject: "SwiftUI", predicate: "requires", object: "MainActor isolation", confidence: 1.0, source: "user")
        engine.assertFact(fact)

        let results = engine.searchFacts(keyword: "swiftui")
        XCTAssertTrue(results.contains(where: { $0.subject.lowercased() == "swiftui" }), "Keyword search must find matching subject")

        let resultsObj = engine.searchFacts(keyword: "mainactor")
        XCTAssertTrue(resultsObj.contains(where: { $0.object.lowercased().contains("mainactor") }), "Keyword search must find matching object")
    }

    // MARK: - Tier 4: Procedural Memory

    func testProceduralRecipeRecordAndLookup() {
        let recipe = CognitiveMemoryEngine.ProceduralRecipe(
            botId: testBotId,
            goalDescription: "Build and test Xcode project",
            toolSequence: ["run_shell_command", "read_file", "patch_file"],
            contextTags: ["compilation", "testing"],
            successCount: 3,
            failureCount: 1,
            notes: "Works on Apple Silicon Macs"
        )
        engine.recordRecipe(recipe)

        let results = engine.lookupRecipes(forGoal: "Build and test")
        XCTAssertFalse(results.isEmpty, "Lookup must find the recorded recipe")
        XCTAssertEqual(results.first?.toolSequence, ["run_shell_command", "read_file", "patch_file"])
    }

    func testProceduralRecipeStatUpdate() {
        let recipe = CognitiveMemoryEngine.ProceduralRecipe(
            botId: testBotId,
            goalDescription: "Deploy to staging",
            toolSequence: ["git_operation", "run_shell_command"],
            contextTags: ["git", "deployment"],
            notes: ""
        )
        engine.recordRecipe(recipe)
        engine.updateRecipeStats(id: recipe.id, succeeded: true)
        engine.updateRecipeStats(id: recipe.id, succeeded: true)
        engine.updateRecipeStats(id: recipe.id, succeeded: false)

        let results = engine.lookupRecipes(forGoal: "Deploy to staging")
        XCTAssertFalse(results.isEmpty, "Recipe must still be found after stat updates")
        XCTAssertEqual(results.first?.successCount, 2)
        XCTAssertEqual(results.first?.failureCount, 1)
    }

    func testProceduralRecipesRankedBySuccessRate() {
        let goodRecipe = CognitiveMemoryEngine.ProceduralRecipe(
            botId: testBotId,
            goalDescription: "Run git workflow",
            toolSequence: ["git_operation"],
            contextTags: ["git"],
            successCount: 10, failureCount: 1, notes: ""
        )
        let badRecipe = CognitiveMemoryEngine.ProceduralRecipe(
            botId: testBotId,
            goalDescription: "Run git workflow alternative",
            toolSequence: ["run_shell_command"],
            contextTags: ["git"],
            successCount: 1, failureCount: 9, notes: ""
        )
        engine.recordRecipe(goodRecipe)
        engine.recordRecipe(badRecipe)

        let results = engine.lookupRecipes(forGoal: "git workflow")
        XCTAssertGreaterThanOrEqual(results.count, 2)
        // Best recipe by net score should come first
        let topSuccessMinusFail = (results[0].successCount - results[0].failureCount)
        let secondSuccessMinusFail = (results[1].successCount - results[1].failureCount)
        XCTAssertGreaterThanOrEqual(topSuccessMinusFail, secondSuccessMinusFail,
                                    "Recipes must be ranked by success-failure score descending")
    }

    // MARK: - Context Summary Builder

    func testBuildContextSummaryNonEmpty() {
        engine.recordEpisode(CognitiveMemoryEngine.EpisodicEntry(
            botId: testBotId, eventType: "tool_call",
            summary: "Read package.swift successfully", metadata: [:]
        ))
        engine.assertFact(CognitiveMemoryEngine.SemanticFact(
            botId: testBotId, subject: "project", predicate: "language", object: "Swift",
            confidence: 1.0, source: "user"
        ))

        let summary = engine.buildContextSummary(forBotId: testBotId, maxLength: 5000)
        XCTAssertFalse(summary.isEmpty, "Context summary must not be empty when memory has entries")
        XCTAssertTrue(summary.contains("Read package.swift successfully"),
                      "Context summary must include recent episodes")
        XCTAssertTrue(summary.contains("Swift"),
                      "Context summary must include semantic facts")
    }

    func testBuildContextSummaryRespectMaxLength() {
        for i in 1...20 {
            engine.recordEpisode(CognitiveMemoryEngine.EpisodicEntry(
                botId: testBotId, eventType: "bot_response",
                summary: String(repeating: "Word ", count: 50) + "episode \(i)",
                metadata: [:]
            ))
        }
        let maxLength = 200
        let summary = engine.buildContextSummary(forBotId: testBotId, maxLength: maxLength)
        XCTAssertLessThanOrEqual(summary.count, maxLength,
                                  "Context summary must be truncated to maxLength")
    }

    // MARK: - Dream Cycle (Memory Consolidation)

    func testDreamCycleConsolidatesFrequentEpisodes() async {
        // Record same summary 3+ times to trigger consolidation
        for _ in 1...4 {
            engine.recordEpisode(CognitiveMemoryEngine.EpisodicEntry(
                botId: testBotId, eventType: "tool_call",
                summary: "Frequently runs xcodebuild", metadata: [:]
            ))
        }

        await engine.runConsolidationCycle(forBotId: testBotId)

        let facts = engine.queryFacts(subject: testBotId.uuidString, predicate: "frequently_does", object: "Frequently runs xcodebuild")
        XCTAssertFalse(facts.isEmpty,
                       "Dream cycle must promote frequent episodic summaries to semantic facts")
    }

    func testDreamCyclePrunesOldEntries() async {
        // Insert old episode (31 days old)
        let oldEntry = CognitiveMemoryEngine.EpisodicEntry(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-31 * 24 * 3600),
            botId: testBotId,
            eventType: "tool_call",
            summary: "Ancient episode that should be pruned",
            metadata: [:]
        )
        engine.recordEpisode(oldEntry)

        let before = engine.allEpisodes(forBotId: testBotId)
        XCTAssertTrue(before.contains(where: { $0.id == oldEntry.id }), "Old entry must be present before consolidation")

        await engine.runConsolidationCycle(forBotId: testBotId)

        let after = engine.allEpisodes(forBotId: testBotId)
        XCTAssertFalse(after.contains(where: { $0.id == oldEntry.id }),
                       "Dream cycle must prune episodes older than 30 days")
    }

    // MARK: - Semantic Embeddings & AgentMemoryEntry Cosine Similarity Retrieval

    func testSemanticEmbeddingsAndCosineSimilarityRetrieval() async {
        // Test with unreachable host URL to deterministically exercise fallback, as well as default Ollama host
        let swiftEntry = await engine.createMemoryEntry(
            content: "Swift 6.4 strict concurrency actor isolation and Sendable conformance",
            source: .userChat,
            tags: ["swift", "concurrency"],
            hostURL: "http://127.0.0.1:1"
        )
        let cookingEntry = await engine.createMemoryEntry(
            content: "Sourdough bread baking recipe with flour water and starter fermentation",
            source: .userChat,
            tags: ["cooking"],
            hostURL: "http://127.0.0.1:1"
        )

        XCTAssertFalse(swiftEntry.embedding.isEmpty, "AgentMemoryEntry.embedding must be populated")
        let decodedSwift = CognitiveMemoryEngine.decodeEmbedding(swiftEntry.embedding)
        XCTAssertNotNil(decodedSwift, "Encoded embedding must round-trip to [Double]")

        let ranked = await engine.retrieveRelevantMemories(
            query: "Swift 6.4 actor concurrency Sendable",
            from: [cookingEntry, swiftEntry],
            topK: 2,
            hostURL: "http://127.0.0.1:1"
        )
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.first?.entry.id, swiftEntry.id,
                       "Swift concurrency memory must rank higher than cooking memory for a Swift concurrency query")
        XCTAssertGreaterThan(ranked[0].similarity, ranked[1].similarity)
    }

    func testOllamaMultimodalUserMessageEncoding() {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        image.unlockFocus()

        let msg = OllamaAgentEngine.buildUserMessage(prompt: "Describe this screenshot", attachments: [image])
        XCTAssertEqual(msg["role"] as? String, "user")
        XCTAssertEqual(msg["content"] as? String, "Describe this screenshot")
        let images = msg["images"] as? [String]
        XCTAssertNotNil(images, "Multimodal user message must include base64 'images' array when attachments are provided")
        XCTAssertEqual(images?.count, 1)
        XCTAssertFalse(images?.first?.isEmpty ?? true)
    }

    func testMCPManagerAutoSeedsXcodeServers() {
        let manager = MCPManager.shared
        manager.loadConfigs()
        if FileManager.default.fileExists(atPath: "/usr/bin/xcrun") {
            XCTAssertTrue(
                manager.servers.contains(where: { $0.name == "xcode-native" && $0.command == "/usr/bin/xcrun" && $0.arguments == ["mcpbridge"] }),
                "MCPManager.loadConfigs() must auto-seed xcode-native when /usr/bin/xcrun exists"
            )
        }
        if FileManager.default.fileExists(atPath: "/Users/danielstevens/.local/bin/xcodebuildmcp") {
            XCTAssertTrue(
                manager.servers.contains(where: { $0.name == "xcodebuildmcp" && $0.arguments == ["mcp"] }),
                "MCPManager.loadConfigs() must auto-seed xcodebuildmcp when binary exists"
            )
        }
    }
}
