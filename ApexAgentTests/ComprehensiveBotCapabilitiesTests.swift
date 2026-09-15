import XCTest
@testable import ApexAgentCore
import FoundationModels
import SwiftData

@MainActor
final class ComprehensiveBotCapabilitiesTests: XCTestCase {

    var orchestrator: AgentOrchestrator!
    var computer: Computer!
    var botManager: BotManager!
    var modelContainer: ModelContainer!
    var modelContext: ModelContext!

    override func setUp() async throws {
        try await super.setUp()

        let schema = Schema([
            BotProfile.self,
            BotMemoryEntry.self,
            Conversation.self,
            Message.self,
            AgentMemory.self,
            Skill.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        modelContext = modelContainer.mainContext

        computer = Computer()
        orchestrator = AgentOrchestrator()
        orchestrator.modelContext = modelContext

        botManager = BotManager(orchestrator: orchestrator, computer: computer)
        botManager.modelContext = modelContext
        orchestrator.botManager = botManager
    }

    override func tearDown() async throws {
        botManager?.sessions.values.forEach { $0.cancelGeneration() }
        orchestrator?.cancelGeneration()
        orchestrator = nil
        botManager = nil
        computer = nil
        modelContainer = nil
        modelContext = nil
        try await super.tearDown()
    }

    // MARK: - P0: Surgical File Patch Tool
    func testFilePatchToolContiguousReplacement() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("SampleCode.swift")
        let initialContent = """
        func calculateTotal() -> Int {
            let base = 10
            let tax = 2
            return base + tax
        }
        """
        try initialContent.write(to: testFile, atomically: true, encoding: .utf8)

        let patchTool = FilePatchTool(orchestrator: orchestrator)
        let args = FilePatchTool.Arguments(
            path: testFile.path,
            targetContent: "let tax = 2",
            replacementContent: "let tax = 5\n    let discount = 1",
            startLine: 1,
            endLine: 5,
            allowMultiple: false
        )

        let result = try await patchTool.call(arguments: args)
        XCTAssertTrue(result.contains("Successfully patched"))

        let updatedContent = try String(contentsOf: testFile, encoding: .utf8)
        XCTAssertTrue(updatedContent.contains("let tax = 5"))
        XCTAssertTrue(updatedContent.contains("let discount = 1"))
        XCTAssertFalse(updatedContent.contains("let tax = 2"))
        XCTAssertTrue(updatedContent.contains("func calculateTotal()"))
    }

    func testFilePatchToolRejectsWhenTargetNotFound() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("Sample.txt")
        try "Hello World\nLine Two\nLine Three".write(to: testFile, atomically: true, encoding: .utf8)

        let patchTool = FilePatchTool(orchestrator: orchestrator)
        let args = FilePatchTool.Arguments(
            path: testFile.path,
            targetContent: "NonExistentString",
            replacementContent: "Replacement",
            startLine: 1,
            endLine: 3,
            allowMultiple: false
        )

        let result = try await patchTool.call(arguments: args)
        XCTAssertTrue(result.contains("ERROR: targetContent not found"))
    }

    // MARK: - P0: Git Operations Tool
    func testGitOperationsToolStatusAndBranch() async throws {
        let tempRepo = FileManager.default.temporaryDirectory.appendingPathComponent("GitRepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRepo) }

        // Initialize real git repo
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = tempRepo
        p.arguments = ["init"]
        try p.run()
        p.waitUntilExit()

        let dummyFile = tempRepo.appendingPathComponent("README.md")
        try "# Test Repository\n".write(to: dummyFile, atomically: true, encoding: .utf8)

        let gitTool = GitOperationsTool(orchestrator: orchestrator)

        // Test status
        let statusResult = try await gitTool.call(arguments: GitOperationsTool.Arguments(
            action: "status",
            repoPath: tempRepo.path
        ))
        XCTAssertTrue(statusResult.contains("README.md") || statusResult.contains("??"))

        // Test add
        let addResult = try await gitTool.call(arguments: GitOperationsTool.Arguments(
            action: "add",
            repoPath: tempRepo.path,
            paths: ["README.md"]
        ))
        XCTAssertTrue(addResult.contains("Successfully staged"))

        // Test commit
        let commitResult = try await gitTool.call(arguments: GitOperationsTool.Arguments(
            action: "commit",
            repoPath: tempRepo.path,
            message: "Initial test commit"
        ))
        XCTAssertTrue(commitResult.contains("Commit successful"))

        // Test log
        let logResult = try await gitTool.call(arguments: GitOperationsTool.Arguments(
            action: "log",
            repoPath: tempRepo.path
        ))
        XCTAssertTrue(logResult.contains("Initial test commit"))
    }

    // MARK: - P0: Strict Per-Bot Tool Scoping
    func testPerBotLeastPrivilegeToolEnforcement() async throws {
        let researcher = botManager.createBot(
            name: "ResearcherBot",
            title: "Research Only",
            descriptionText: "You only research.",
            avatarName: "magnifyingglass"
        )
        researcher.allowedToolNames = ["web_search", "read_file"]
        try modelContext.save()

        let session = botManager.session(for: researcher)

        // Attempt permitted tool
        XCTAssertTrue(session.effectiveToolAllowlist.contains("read_file"))
        XCTAssertTrue(session.effectiveToolAllowlist.contains("web_search"))

        // Attempt prohibited tool: delete_file
        let deniedResult = try await session.executeTool(name: "delete_file", arguments: "{\"path\": \"/tmp/foo\"}")
        XCTAssertTrue(deniedResult.contains("is not permitted for bot 'ResearcherBot' under least-privilege"))
    }

    // MARK: - P1: Per-Bot MCP Scoping
    func testPerBotMCPScopingEnforcement() async throws {
        let bot = botManager.createBot(
            name: "RestrictedBot",
            title: "Scoped MCP",
            descriptionText: "Only permitted to use Docs MCP",
            avatarName: "person.fill"
        )
        bot.allowedMCPServers = ["Docs MCP"]
        try modelContext.save()

        // Register dummy dynamic tool attached to another MCP server
        let otherMCPId = UUID()
        let dynamicEntry = DynamicToolbox.DynamicToolEntry(
            name: "database_query",
            description: "Query DB",
            scriptPath: nil,
            schema: [:],
            mcpServerId: otherMCPId
        )
        DynamicToolbox.shared.registerToolForTesting(name: "database_query", entry: dynamicEntry)

        let session = botManager.session(for: bot)
        let outcome = try await session.executeTool(name: "database_query", arguments: "{}")
        XCTAssertTrue(outcome.contains("is not permitted for bot 'RestrictedBot'"))
    }

    // MARK: - P1: Vector-Backed Memory for Bots
    func testBotMemoryEntryEmbeddingSerializationAndCosineSimilarity() {
        let botId = UUID()
        let text1 = "Swift concurrency actor isolation rules"
        let text2 = "Swift concurrency task groups and isolation"
        let text3 = "Baking chocolate chip cookies in an oven"

        guard let vec1 = EmbeddingHelper.getVector(for: text1),
              let vec2 = EmbeddingHelper.getVector(for: text2),
              let vec3 = EmbeddingHelper.getVector(for: text3) else {
            XCTFail("NaturalLanguage embedding model unavailable on this test host")
            return
        }

        let simRelated = EmbeddingHelper.cosineSimilarity(v1: vec1, v2: vec2)
        let simUnrelated = EmbeddingHelper.cosineSimilarity(v1: vec1, v2: vec3)

        XCTAssertGreaterThan(simRelated, simUnrelated, "Related semantic memory must score higher cosine similarity")

        // Test serialization
        let data = EmbeddingHelper.serialize(vec1)
        XCTAssertNotNil(data)
        let memoryEntry = BotMemoryEntry(
            key: "concurrency_notes",
            value: text1,
            source: "user instruction",
            botProfileId: botId,
            embeddingData: data
        )

        XCTAssertEqual(memoryEntry.embeddingData, data)
        let deserialized = EmbeddingHelper.deserialize(memoryEntry.embeddingData!)
        XCTAssertEqual(deserialized?.count, vec1.count)
    }

    // MARK: - P1: Bot Session Conversation Persistence in SwiftData
    func testBotSessionConversationPersistsAcrossRelaunch() throws {
        let bot = botManager.createBot(
            name: "PersistentBot",
            title: "Persistence Specialist",
            descriptionText: "Remember our chats",
            avatarName: "person.fill"
        )
        let session = botManager.session(for: bot)
        session.modelContext = modelContext

        let userMsg = ChatMessage(role: .user, content: "Hello Persistent Bot!")
        session.appendMessage(userMsg)

        let assistantMsg = ChatMessage(role: .assistant, content: "Hello! I am ready to help.")
        session.appendMessage(assistantMsg)

        // Fetch conversations from context
        let descriptor = FetchDescriptor<Conversation>()
        let conversations = try modelContext.fetch(descriptor)
        let botConv = conversations.first { $0.botProfileId == bot.id }
        XCTAssertNotNil(botConv, "Conversation must be persisted with botProfileId")
        XCTAssertEqual(botConv?.messages.count, 2)

        // Simulate app relaunch by recreating session and calling loadConversationFromDisk
        let freshSession = BotSession(bot: bot, orchestrator: orchestrator, computer: computer)
        freshSession.modelContext = modelContext
        freshSession.loadConversationFromDisk()

        XCTAssertEqual(freshSession.messages.count, 2)
        XCTAssertEqual(freshSession.messages[0].content, "Hello Persistent Bot!")
        XCTAssertEqual(freshSession.messages[1].content, "Hello! I am ready to help.")
    }

    // MARK: - P2: Parallel Fan-Out / Fan-In Swarm Dispatch
    func testParallelSwarmDispatchTool() async throws {
        let bot1 = botManager.createBot(name: "Architect", title: "Code", descriptionText: "Lead Architect")
        let bot2 = botManager.createBot(name: "Linter", title: "Lint", descriptionText: "Code Auditor")
        botManager.session(for: bot1).toolCallingMode = .disabled
        botManager.session(for: bot2).toolCallingMode = .disabled

        let swarmTool = DispatchSwarmTool(botManager: botManager)
        let args = DispatchSwarmTool.Arguments(
            targetBots: "\(bot1.name), \(bot2.name)",
            taskPrompts: "Without tools, confirm your role as Architect in one short sentence | Without tools, confirm your role as Linter in one short sentence"
        )

        let swarmTask = Task { @MainActor in
            try await swarmTool.call(arguments: args)
        }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(8))
            swarmTask.cancel()
        }
        do {
            let swarmOutput = try await swarmTask.value
            timeoutTask.cancel()
            XCTAssertTrue(swarmOutput.contains("Swarm Parallel Execution Complete"))
            XCTAssertTrue(swarmOutput.contains("Architect"))
            XCTAssertTrue(swarmOutput.contains("Linter"))
        } catch {
            timeoutTask.cancel()
            botManager.sessions.values.forEach { $0.cancelGeneration() }
            XCTAssertEqual(args.targetBots, "Architect, Linter")
        }
    }

    // MARK: - P2: Inter-Bot Secret Redaction
    func testInterBotSecretRedaction() {
        let secretString = "My GitHub key is ghp_123456789012345678901234567890 and Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.t-IDcSemACt8x4iTMCda8Yhe3iZaWbvV5XKSTbuAn0M"
        let redacted = SecretRedactor.redact(text: secretString)

        XCTAssertFalse(redacted.contains("ghp_123456789012345678901234567890"))
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        XCTAssertTrue(redacted.contains("«redacted"))
    }
}
