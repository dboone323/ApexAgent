import Foundation
import SwiftData
import Testing
@testable import ApexAgentCore

@Suite("Files-First Memory Tiers Tests (Issue #80)")
struct FilesFirstMemoryTiersTests {

    private func createTempWorkspace(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // MARK: - 1. Curated MEMORY.md Tests

    @Test("Curated MEMORY.md: saving, loading, and live edit reflection on disk")
    @MainActor
    func testPerSpaceMemoryFileLoadAndSave() throws {
        let ws = try createTempWorkspace(prefix: "test-memory-md")
        defer { try? FileManager.default.removeItem(at: ws) }

        let manager = SpaceMemoryTierManager.shared
        let memoryPath = ws.appendingPathComponent("MEMORY.md").path

        // Initially nil when file doesn't exist
        #expect(manager.loadCuratedMemory(workspacePath: ws.path) == nil)

        // Save curated memory
        let fact1 = "Fact: Production DB replica runs on port 5433."
        try manager.saveCuratedMemory(fact1, workspacePath: ws.path)

        #expect(FileManager.default.fileExists(atPath: memoryPath))
        let loaded1 = manager.loadCuratedMemory(workspacePath: ws.path)
        #expect(loaded1 == fact1)

        // Hand edit file directly on disk
        let fact2 = "Fact: Production DB replica moved to port 5434 for failover testing."
        try fact2.write(toFile: memoryPath, atomically: true, encoding: .utf8)

        // Live reflection: immediate read from disk
        let loaded2 = manager.loadCuratedMemory(workspacePath: ws.path)
        #expect(loaded2 == fact2)
    }

    @Test("Curated MEMORY.md: fallback hierarchy and whitespace trimming")
    @MainActor
    func testPerSpaceMemoryFallbackHierarchy() throws {
        let ws = try createTempWorkspace(prefix: "test-memory-fallback")
        defer { try? FileManager.default.removeItem(at: ws) }

        let manager = SpaceMemoryTierManager.shared
        let dotApexDir = ws.appendingPathComponent(".apex")
        try FileManager.default.createDirectory(at: dotApexDir, withIntermediateDirectories: true)

        // Write to .apex/MEMORY.md
        let hiddenMemory = dotApexDir.appendingPathComponent("MEMORY.md")
        try "Hidden space knowledge\n\n".write(to: hiddenMemory, atomically: true, encoding: .utf8)

        #expect(manager.loadCuratedMemory(workspacePath: ws.path) == "Hidden space knowledge")

        // Top-level MEMORY.md takes precedence
        let topMemory = ws.appendingPathComponent("MEMORY.md")
        try "Top-level space knowledge".write(to: topMemory, atomically: true, encoding: .utf8)

        #expect(manager.loadCuratedMemory(workspacePath: ws.path) == "Top-level space knowledge")
    }

    // MARK: - 2. Daily Notes Tests

    @Test("Daily notes: creation, date normalization, title extraction, and tag parsing")
    @MainActor
    func testDailyNotesSaveAndParsing() throws {
        let ws = try createTempWorkspace(prefix: "test-daily-notes")
        defer { try? FileManager.default.removeItem(at: ws) }

        let manager = SpaceMemoryTierManager.shared
        let dateStr = "2026-11-12"
        let noteMarkdown = """
        # Incident Triage Postmortem
        Reviewed memory tier design for Issue 80.
        Tags: #architecture #memory #macOS27
        Actions taken:
        - Confirmed zero mocks principle
        - Added real file indexer
        """

        let entry = try manager.saveDailyNote(date: dateStr, content: noteMarkdown, workspacePath: ws.path)

        #expect(entry.date == dateStr)
        #expect(entry.title == "Incident Triage Postmortem")
        #expect(entry.tags.contains("architecture"))
        #expect(entry.tags.contains("memory"))

        // Fetch by date
        let fetched = manager.getDailyNote(date: dateStr, workspacePath: ws.path)
        #expect(fetched?.contains("Incident Triage Postmortem") == true)
        #expect(fetched?.contains("Zero mocks principle") == false) // Case preserved
        #expect(fetched?.contains("zero mocks principle") == true)
    }

    @Test("Daily notes: multi-note indexing, date sorting, and keyword scoring")
    @MainActor
    func testDailyNotesIndexingAndSearch() throws {
        let ws = try createTempWorkspace(prefix: "test-daily-search")
        defer { try? FileManager.default.removeItem(at: ws) }

        let manager = SpaceMemoryTierManager.shared

        // Create 3 notes across different dates
        try manager.saveDailyNote(
            date: "2026-11-10",
            content: "# Database Upgrade\nUpgraded PostgreSQL cluster to version 17. #database #infra",
            workspacePath: ws.path
        )
        try manager.saveDailyNote(
            date: "2026-11-11",
            content: "# Webhook Pipeline\nWired webhook retry queues with exponential backoff. #networking",
            workspacePath: ws.path
        )
        try manager.saveDailyNote(
            date: "2026-11-12",
            content: "# Files-First Memory Tiers\nImplemented per-Space MEMORY.md and daily notes indexer. #memory #spine",
            workspacePath: ws.path
        )

        let allNotes = manager.indexDailyNotes(workspacePath: ws.path)
        #expect(allNotes.count == 3)
        #expect(allNotes[0].date == "2026-11-12") // Newest first
        #expect(allNotes[1].date == "2026-11-11")
        #expect(allNotes[2].date == "2026-11-10")

        // Search by keyword
        let searchDb = manager.searchDailyNotes(query: "PostgreSQL", workspacePath: ws.path)
        #expect(!searchDb.isEmpty)
        #expect(searchDb[0].date == "2026-11-10")
        #expect(searchDb[0].title == "Database Upgrade")

        // Search by date string
        let searchDate = manager.searchDailyNotes(query: "2026-11-12", workspacePath: ws.path)
        #expect(!searchDate.isEmpty)
        #expect(searchDate[0].date == "2026-11-12")

        // Search by tag
        let searchTag = manager.searchDailyNotes(query: "networking", workspacePath: ws.path)
        #expect(!searchTag.isEmpty)
        #expect(searchTag[0].date == "2026-11-11")
    }

    // MARK: - 3. Persona and User File Tests

    @Test("Persona and User files: load, save, and live manual edit reflection")
    @MainActor
    func testPersonaAndUserFilesLiveEditReflection() throws {
        let ws = try createTempWorkspace(prefix: "test-persona-user")
        defer { try? FileManager.default.removeItem(at: ws) }

        let manager = SpaceMemoryTierManager.shared

        // Initial Persona
        let initialPersona = "You are an expert Systems Architect specializing in Swift 6 concurrency."
        try manager.savePersona(initialPersona, workspacePath: ws.path)
        #expect(manager.loadPersona(workspacePath: ws.path) == initialPersona)

        // Hand edit PERSONA.md
        let editedPersona = "You are a concise Staff SRE. Deliver shell commands and postmortems only."
        let personaURL = URL(fileURLWithPath: manager.personaPath(workspacePath: ws.path))
        try editedPersona.write(to: personaURL, atomically: true, encoding: .utf8)
        #expect(manager.loadPersona(workspacePath: ws.path) == editedPersona)

        // Initial User Profile
        let initialUser = """
        # Name: Daniel
        ## Roles
        - Lead Engineer
        """
        try manager.saveUserContext(initialUser, workspacePath: ws.path)
        #expect(manager.loadUserContext(workspacePath: ws.path) == initialUser)

        // Hand edit USER.md
        let editedUser = """
        # Name: Daniel Stevens
        ## Focus
        - P0 Mac release shipping
        - Zero mock testing
        """
        let userURL = URL(fileURLWithPath: manager.userContextPath(workspacePath: ws.path))
        try editedUser.write(to: userURL, atomically: true, encoding: .utf8)
        #expect(manager.loadUserContext(workspacePath: ws.path) == editedUser)
    }

    @Test("PersonalContext parser: extracts name, routines, and goals from USER.md")
    func testPersonalContextMarkdownParsing() {
        let markdown = """
        # Name: Daniel Stevens
        ## Daily Routines
        - Review morning PR queue
        - Run local gate checks
        - Update daily note

        ## Active Goals
        - Complete Issue 80 files-first memory tiers
        - Ship Mac spine release

        ## Peak Energy Hours
        - 9
        - 10
        - 11
        """

        let context = ApexAgentPersonalContext.from(markdown: markdown)
        #expect(context.name == "Daniel Stevens")
        #expect(context.routines.contains("Review morning PR queue"))
        #expect(context.routines.contains("Update daily note"))
        #expect(context.goals.contains("Complete Issue 80 files-first memory tiers"))
        #expect(context.energyPeakHours == [9, 10, 11])
    }

    // MARK: - 4. Space Context Injection Tests

    @Test("Space Context Injection: buildSpaceSystemInstructions includes all active tiers")
    @MainActor
    func testSpaceSystemInstructionsInjection() throws {
        let ws = try createTempWorkspace(prefix: "test-space-injection")
        defer { try? FileManager.default.removeItem(at: ws) }

        let space = SpaceModel(
            name: "Research Hub",
            workspacePath: ws.path
        )

        let manager = SpaceMemoryTierManager.shared
        try manager.saveCuratedMemory("Shared Rule: All migrations require pre-validation.", workspacePath: ws.path)
        try manager.savePersona("Persona: Precise, formal, analytical.", workspacePath: ws.path)
        try manager.saveUserContext("User: Principal Engineer working on Mac build.", workspacePath: ws.path)

        let bot = BotProfile(name: "Oracle", title: "Chief of Staff")
        let channel = SpaceChannel(name: "general")

        let instructions = SpaceManager.shared.buildSpaceSystemInstructions(
            for: bot,
            in: space,
            channel: channel
        )

        #expect(instructions.contains("=== SPACE CURATED MEMORY (MEMORY.md) ==="))
        #expect(instructions.contains("Shared Rule: All migrations require pre-validation."))
        #expect(instructions.contains("=== AGENT PERSONA & BEHAVIOUR (PERSONA.md) ==="))
        #expect(instructions.contains("Persona: Precise, formal, analytical."))
        #expect(instructions.contains("=== USER PROFILE & PREFERENCES (USER.md) ==="))
        #expect(instructions.contains("User: Principal Engineer working on Mac build."))
    }

    // MARK: - 5. Git Versionability Tests

    @Test("Git Versionability: MEMORY.md, PERSONA.md, USER.md, and daily notes are tracked and diffable")
    func testGitVersionability() throws {
        let ws = try createTempWorkspace(prefix: "test-git-versionability")
        defer { try? FileManager.default.removeItem(at: ws) }

        // Helper to run git in ws
        func runGit(_ args: [String]) throws -> String {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.currentDirectoryURL = ws
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            guard proc.terminationStatus == 0 else {
                throw NSError(domain: "GitError", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
            }
            return output
        }

        // Initialize real git repo
        _ = try runGit(["init"])
        _ = try runGit(["config", "user.name", "ApexAgent Tester"])
        _ = try runGit(["config", "user.email", "tester@apexagent.internal"])

        // Create files-first memory files
        let memoryURL = ws.appendingPathComponent("MEMORY.md")
        let personaURL = ws.appendingPathComponent("PERSONA.md")
        let userURL = ws.appendingPathComponent("USER.md")
        let dailyDir = ws.appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let noteURL = dailyDir.appendingPathComponent("2026-11-12.md")

        try "Initial curated memory fact.".write(to: memoryURL, atomically: true, encoding: .utf8)
        try "Initial persona instructions.".write(to: personaURL, atomically: true, encoding: .utf8)
        try "Initial user preferences.".write(to: userURL, atomically: true, encoding: .utf8)
        try "# 2026-11-12 Note\nStandup log.".write(to: noteURL, atomically: true, encoding: .utf8)

        // Stage and commit
        _ = try runGit(["add", "MEMORY.md", "PERSONA.md", "USER.md", "daily/2026-11-12.md"])
        _ = try runGit(["commit", "-m", "chore: initial memory tiers"])

        // Modify MEMORY.md and verify git diff
        try "Initial curated memory fact.\nAdded fact: Service port is 8080.".write(to: memoryURL, atomically: true, encoding: .utf8)
        let diff = try runGit(["diff", "MEMORY.md"])

        #expect(diff.contains("+Added fact: Service port is 8080."))
        #expect(diff.contains("--- a/MEMORY.md"))
        #expect(diff.contains("+++ b/MEMORY.md"))
    }

    // MARK: - 6. Search Memory Tool Integration

    @Test("SearchMemoryTool: retrieves indexed daily notes and curated space memory")
    @MainActor
    func testSearchMemoryToolIntegration() async throws {
        let ws = try createTempWorkspace(prefix: "test-search-tool")
        defer { try? FileManager.default.removeItem(at: ws) }

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = ws.path

        let schema = Schema([Conversation.self, Message.self, AgentMemory.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        orchestrator.modelContext = ModelContext(container)

        let manager = SpaceMemoryTierManager.shared
        try manager.saveCuratedMemory("Database failover target is eu-west-1.", workspacePath: ws.path)
        try manager.saveDailyNote(
            date: "2026-11-12",
            content: "# Schema Migration\nCompleted migration of accounts table to partitioning.",
            workspacePath: ws.path
        )

        let searchTool = SearchMemoryTool(orchestrator: orchestrator)

        // Query daily note content
        let noteResult = try await searchTool.call(arguments: SearchMemoryTool.Arguments(query: "partitioning", category: nil))
        #expect(noteResult.contains("Found 1 indexed daily note(s)"))
        #expect(noteResult.contains("2026-11-12"))
        #expect(noteResult.contains("migration of accounts table"))

        // Query curated memory content
        let memoryResult = try await searchTool.call(arguments: SearchMemoryTool.Arguments(query: "failover", category: nil))
        #expect(memoryResult.contains("Curated Space Memory (MEMORY.md)"))
        #expect(memoryResult.contains("Database failover target is eu-west-1."))
    }
}
