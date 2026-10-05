import Testing
import Foundation
@testable import ApexAgentCore

@Suite("SandboxTests") @MainActor
struct SandboxTests {

    @Test func testPathRejectedForArbitraryOutsideWorkspace() {
        let orchestrator = AgentOrchestrator()
        #expect(!orchestrator.isPathAllowed("/var/denied-path"))
    }

    @Test func testRelativeAndDotPathsAllowedInWorkspace() {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions()
        let ws = orchestrator.currentWorkspacePath
        #expect(orchestrator.isPathAllowed("."))
        #expect(orchestrator.isPathAllowed("./"))
        #expect(orchestrator.isPathAllowed(""))
        #expect(orchestrator.isPathAllowed(ws))
    }

    @Test func testCommandRejectedWhenDesktopRestricted() {
        let orchestrator = AgentOrchestrator()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let desktop = (home as NSString).appendingPathComponent("Desktop")
        orchestrator.permissions = AppPermissions(desktopFolderAllowed: false)
        #expect(!orchestrator.isCommandOrScriptAllowed("ls " + desktop))
    }

    @Test func testCommandDeniedWhenPermissionsUnset() {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = nil
        #expect(!orchestrator.isCommandOrScriptAllowed("echo hello"))
    }

    @Test func testCommandAllowedWhenContainerSandboxedEvenIfDesktopPathReferenced() {
        let orchestrator = AgentOrchestrator()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let desktop = (home as NSString).appendingPathComponent("Desktop")
        orchestrator.permissions = AppPermissions(desktopFolderAllowed: false)
        
        // On host: blocked
        #expect(!orchestrator.isCommandOrScriptAllowed("ls " + desktop, isContainerSandboxed: false))
        
        // In container sandbox: allowed (isolated micro-VM guest)
        #expect(orchestrator.isCommandOrScriptAllowed("ls " + desktop, isContainerSandboxed: true))
    }

    @Test func testApprovalPolicyAutoApprovesInContainerSandbox() {
        // Privileged commands inside the container are auto-approved
        let verdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "sudo apt-get install -y build-essential && rm -rf /tmp/build",
            isContainerSandboxed: true
        )
        #expect(verdict.approve != nil)
        #expect(verdict.source == .containerSandbox)
    }

    @Test func testApprovalPolicyBlocksHostDiskEraseEvenInContainerSandbox() {
        // Catastrophic host disk destruction is guarded regardless
        let verdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "diskutil eraseDisk APFS CleanDisk /dev/disk2",
            isContainerSandboxed: true
        )
        #expect(verdict.approve == nil)
        #expect(verdict.source == .destructiveGuard)
    }

    @Test func testApprovalPolicyRetainsDestructiveGuardOnHost() {
        // Host execution without container sandbox blocks destructive rm -rf
        let verdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "rm -rf /Users/test/project",
            isContainerSandboxed: false
        )
        #expect(verdict.approve == nil)
        #expect(verdict.source == .destructiveGuard)
    }

    @Test func testListDirectoryWithDotAndRelativePath() async throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions()
        let tool = ListDirectoryTool(orchestrator: orchestrator)

        let dotResult = try await tool.call(arguments: ListDirectoryTool.Arguments(path: ".", showHidden: false, depth: 1))
        #expect(!dotResult.contains("ERROR: Access to path is disabled in settings"))
        #expect(dotResult.hasPrefix("Directory:"))

        let emptyResult = try await tool.call(arguments: ListDirectoryTool.Arguments(path: "", showHidden: false, depth: 1))
        #expect(!emptyResult.contains("ERROR: Access to path is disabled in settings"))
        #expect(emptyResult.hasPrefix("Directory:"))
    }

    // MARK: - Context Compaction Real Tests (Zero-Mock)

    @Test func testContextCompactionDoesNotTriggerWhenUnderThreshold() async throws {
        let testBotId = UUID()
        let engine = CognitiveMemoryEngine.shared
        defer {
            let botDir = ApexAgentStoragePaths.directory("memory")
                .appendingPathComponent(testBotId.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: botDir)
        }

        let msgs = [
            ChatMessage(role: .user, content: "Hello!"),
            ChatMessage(role: .assistant, content: "Hi there! How can I assist you today?")
        ]

        let (compacted, archivedCount) = try await engine.compactMessages(
            messages: msgs,
            keepRecent: 4,
            maxChars: 4000,
            botId: testBotId
        ) { _ in
            Issue.record("Summarizer should not be called when under message count threshold")
            return ""
        }

        #expect(archivedCount == 0)
        #expect(compacted.count == 2)
        #expect(compacted.first?.content == "Hello!")
    }

    @Test func testContextCompactionSummarizesOlderTurnsAndPreservesRecent() async throws {
        let testBotId = UUID()
        let engine = CognitiveMemoryEngine.shared
        defer {
            let botDir = ApexAgentStoragePaths.directory("memory")
                .appendingPathComponent(testBotId.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: botDir)
        }

        var msgs: [ChatMessage] = []
        for i in 1...4 {
            msgs.append(ChatMessage(role: .user, content: "Question #\(i): Please check file path /Users/dev/file\(i).swift"))
            msgs.append(ChatMessage(role: .assistant, content: "Answer #\(i): Status code is 200, file\(i) validated successfully."))
        }

        #expect(msgs.count == 8)

        var summarizerInvoked = false
        let expectedSummary = "User checked files 1 through 2. All status codes returned 200 and verified."

        let (compacted, archivedCount) = try await engine.compactMessages(
            messages: msgs,
            keepRecent: 4,
            maxChars: 4000,
            botId: testBotId
        ) { transcript in
            summarizerInvoked = true
            #expect(transcript.contains("file1.swift"))
            #expect(transcript.contains("file2.swift"))
            return expectedSummary
        }

        #expect(summarizerInvoked)
        #expect(archivedCount == 4)
        #expect(compacted.count == 5)

        let summaryMsg = compacted.first
        #expect(summaryMsg?.role == .system)
        #expect(summaryMsg?.content.contains(expectedSummary) == true)

        let preserved = Array(compacted.dropFirst())
        #expect(preserved.count == 4)
        #expect(preserved[0].content == msgs[4].content)
        #expect(preserved[1].content == msgs[5].content)
        #expect(preserved[2].content == msgs[6].content)
        #expect(preserved[3].content == msgs[7].content)
    }

    @Test func testCompactedMessagesArchivedToDurableEpisodicDisk() async throws {
        let testBotId = UUID()
        let engine = CognitiveMemoryEngine.shared
        defer {
            let botDir = ApexAgentStoragePaths.directory("memory")
                .appendingPathComponent(testBotId.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: botDir)
        }

        let msgs = [
            ChatMessage(role: .user, content: "Initial audit request for security vulnerabilities"),
            ChatMessage(role: .assistant, content: "Found 0 critical path traversal risks in SandboxTests"),
            ChatMessage(role: .user, content: "Check PTY session allocation"),
            ChatMessage(role: .assistant, content: "PTY allocation verified and stable"),
            ChatMessage(role: .user, content: "Recent question 1"),
            ChatMessage(role: .assistant, content: "Recent answer 1"),
            ChatMessage(role: .user, content: "Recent question 2"),
            ChatMessage(role: .assistant, content: "Recent answer 2")
        ]

        let summary = "Security audit clean, PTY allocation stable."

        let (_, archivedCount) = try await engine.compactMessages(
            messages: msgs,
            keepRecent: 4,
            maxChars: 4000,
            botId: testBotId
        ) { _ in summary }

        #expect(archivedCount == 4)

        let episodes = engine.recentEpisodes(forBotId: testBotId, limit: 10)
        #expect(!episodes.isEmpty)

        let compactionEpisode = episodes.first(where: { $0.eventType == "context_compaction" })
        #expect(compactionEpisode != nil)
        #expect(compactionEpisode?.summary == summary)
        #expect(compactionEpisode?.metadata["compactedTurnCount"] == "4")
    }

    @Test func testContextCompactionTriggersOnMassivePayloadWithFewTurns() async throws {
        let testBotId = UUID()
        let engine = CognitiveMemoryEngine.shared
        defer {
            let botDir = ApexAgentStoragePaths.directory("memory")
                .appendingPathComponent(testBotId.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: botDir)
        }

        // Only 3 messages (<= 5), but first message is massive (25,000 characters > 20,000 threshold)
        let massivePayload = String(repeating: "diff --git a/file.swift b/file.swift\n+ line of code\n", count: 600)
        #expect(massivePayload.count > 20000)

        let msgs = [
            ChatMessage(role: .user, content: massivePayload),
            ChatMessage(role: .assistant, content: "Analyzed git diff."),
            ChatMessage(role: .user, content: "Now patch line 42")
        ]

        var summarizerCalled = false
        let (compacted, archivedCount) = try await engine.compactMessages(
            messages: msgs,
            keepRecent: 4,
            maxChars: 4000,
            botId: testBotId
        ) { transcript in
            summarizerCalled = true
            return "Summarized 25k massive git diff into concise digest."
        }

        #expect(summarizerCalled == true)
        #expect(archivedCount >= 1)
        #expect(compacted.count >= 2)
        #expect(compacted.first?.role == .system)
        #expect(compacted.first?.content.contains("Summarized 25k massive git diff") == true)
    }
}
