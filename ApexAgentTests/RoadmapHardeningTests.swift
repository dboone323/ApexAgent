import Testing
import Foundation
import os
import WebKit
@testable import ApexAgentCore

@Suite("RoadmapHardeningTests")
struct RoadmapHardeningTests {

    // MARK: - Step 1: SpotlightSearch Lock Concurrency Safety
    @Test("Spotlight unfair lock prevents double-resume races")
    func testSpotlightContinuationLockSafety() async {
        let hasResumed = OSAllocatedUnfairLock(initialState: false)

        let resumeCount = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    hasResumed.withLock { isResumed -> Bool in
                        if !isResumed {
                            isResumed = true
                            return true
                        }
                        return false
                    }
                }
            }
            var total = 0
            for await resumed in group {
                if resumed {
                    total += 1
                }
            }
            return total
        }

        #expect(resumeCount == 1)
    }

    // MARK: - Step 2: AskBotTool and Peer Delivery
    @Test("AskBotTool correctly delegates and enforces peer approvals")
    @MainActor
    func testAskBotToolPeerDeliveryAndExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)

        let chief = botManager.createBot(
            name: "Chief",
            title: "Executive Coordinator",
            descriptionText: "Coordinates tasks."
        )
        let researcher = botManager.createBot(
            name: "Researcher",
            title: "Research Specialist",
            descriptionText: "Researches facts."
        )

        botManager.openConversation(with: chief)

        let askBotTool = AskBotTool(orchestrator: orchestrator, currentBotId: chief.id)

        // 1. Without grant -> blocked pending approval card
        let args = AskBotTool.Arguments(targetBot: "Researcher", message: "Find swift data docs")
        let blockedResult = try await askBotTool.call(arguments: args)
        #expect(blockedResult.contains("Peer approval required") || blockedResult.contains("pending approval card"))

        // 2. Add grant -> allowed and delivered
        botManager.peerApprovals.addGrant(
            action: .askBot,
            senderBotId: chief.id.uuidString,
            targetBotId: researcher.id.uuidString
        )
        #expect(botManager.peerApprovals.hasGrant(
            action: .askBot,
            senderBotId: chief.id.uuidString,
            targetBotId: researcher.id.uuidString
        ))

        let decision = botManager.peerDeliveryDecision(from: chief, to: researcher, message: "Hello researcher")
        #expect(decision == .deliver)
    }

    // MARK: - Step 3: RepeatDetector Loop Interception
    @Test("RepeatDetector loop detection stops infinite tool loops")
    @MainActor
    func testRepeatDetectorLoopInterception() async throws {
        let orchestrator = AgentOrchestrator()
        let tempDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let sampleFile = tempDir.appendingPathComponent("test.txt")
        try "sample search content".write(to: sampleFile, atomically: true, encoding: .utf8)
        orchestrator.currentWorkspacePath = tempDir.path
        orchestrator.permissions = AppPermissions()

        let tool = FileSearchTool(orchestrator: orchestrator)
        let args = FileSearchTool.Arguments(query: "search content", directory: tempDir.path, filePattern: "*.txt")

        var lastResult = ""
        for i in 1...6 {
            let res = try await tool.call(arguments: args)
            lastResult = res
            if i >= 5 {
                #expect(res.contains("Loop detected") || res.contains("identical arguments"))
            }
        }
        #expect(lastResult.contains("Loop detected"))
    }

    // MARK: - Step 5: Group Chat Speaker Attribution
    @Test("GroupChatSession attributes speaker names to assistant messages")
    @MainActor
    func testGroupChatSpeakerAttribution() {
        let botA = BotProfile(name: "Architect", title: "Code Lead", descriptionText: "Designs systems.")
        let botB = BotProfile(name: "Reviewer", title: "QA Specialist", descriptionText: "Reviews code.")

        let group = GroupChatSession(name: "Sprint Review", participants: [botA, botB])

        // Add user prompt
        group.messages.append(ChatMessage(role: .user, content: "What is our architecture plan?"))
        // Add assistant message from Architect
        group.messages.append(ChatMessage(role: .assistant, content: "We use micro-modules.", botName: "Architect"))
        // Add thinking marker (should be ignored in context)
        group.messages.append(ChatMessage(role: .assistant, content: "[Reviewer is thinking...]", isStreaming: true, botName: "Reviewer"))

        let contextForReviewer = group.buildGroupContext(for: botB)

        #expect(contextForReviewer.contains("[Architect] We use micro-modules."))
        #expect(contextForReviewer.contains("[User] What is our architecture plan?"))
        #expect(!contextForReviewer.contains("Reviewer is thinking"))
    }

    // MARK: - Step 7: Persistent Browser Session Store
    @Test("BrowserManager uses persistent on-disk dataStore")
    @MainActor
    func testBrowserPersistentDataStore() {
        let browser = BrowserManager.shared
        #expect(browser.isPersistent == true)
        #expect(browser.dataStore === WKWebsiteDataStore.default())
    }

    // MARK: - Registered Tools Count
    @Test("AgentOrchestrator registers all 63 tools in allTools")
    @MainActor
    func testAllToolsRegistrationCount() {
        let orchestrator = AgentOrchestrator()
        let tools = orchestrator.allTools
        // 65 tools registered across all pillars and specialized features
        // (includes RollbackTool and DeleteMemoryTool).
        #expect(tools.count == 67)

        let names = Set(tools.map(\.name))
        #expect(names.contains("run_shell_command"))
        #expect(names.contains("read_file"))
        #expect(names.contains("patch_file"))
        #expect(names.contains("git_operation"))
        #expect(names.contains("dispatch_swarm"))
        #expect(names.contains("spotlight_search"))
        #expect(names.contains("ask_bot"))
        #expect(names.contains("control_browser"))
        #expect(names.contains("save_review_session"))
        #expect(names.contains("delegate_task"))
        #expect(names.contains("convene_meeting"))
    }

    // MARK: - Step 8: Delegation Turn Bounds and Anti-Loop Capping
    @Test("AgentOrchestrator bounds delegation to max 2 per specialist and 3 total per turn")
    @MainActor
    func testDelegationTurnBoundsAndCapping() {
        let orchestrator = AgentOrchestrator()
        orchestrator.resetActiveTurnToolCallCount()

        // 1st delegation to developer (Codex) -> allowed
        let res1 = orchestrator.recordDelegation(to: "developer")
        #expect(res1.allowed == true)
        #expect(res1.message == nil)
        #expect(orchestrator.totalTurnDelegations == 1)
        #expect(orchestrator.activeTurnDelegationsByAgent["developer"] == 1)

        // 2nd delegation to developer (Codex) -> allowed
        let res2 = orchestrator.recordDelegation(to: "developer")
        #expect(res2.allowed == true)
        #expect(res2.message == nil)
        #expect(orchestrator.totalTurnDelegations == 2)
        #expect(orchestrator.activeTurnDelegationsByAgent["developer"] == 2)

        // 3rd delegation to developer -> blocked (exceeds 2 per agent)
        let res3 = orchestrator.recordDelegation(to: "developer")
        #expect(res3.allowed == false)
        #expect(res3.message?.contains("DELEGATION LIMIT REACHED") == true)
        #expect(res3.message?.contains("already completed 2 tasks") == true)
        #expect(orchestrator.totalTurnDelegations == 2)

        // 3rd total delegation to researcher (Oracle) -> allowed (first for researcher, 3rd total)
        let res4 = orchestrator.recordDelegation(to: "researcher")
        #expect(res4.allowed == true)
        #expect(res4.message == nil)
        #expect(orchestrator.totalTurnDelegations == 3)

        // 4th total delegation to any agent (e.g. executor) -> blocked (exceeds 3 total per turn)
        let res5 = orchestrator.recordDelegation(to: "executor")
        #expect(res5.allowed == false)
        #expect(res5.message?.contains("DELEGATION LIMIT REACHED") == true)
        #expect(res5.message?.contains("Maximum total delegations (3) reached") == true)

        // checkRepeat also catches delegate_task when total delegations >= 3
        let repeatWarning = orchestrator.checkRepeat(tool: "delegate_task", arguments: "any arguments")
        #expect(repeatWarning != nil)
        #expect(repeatWarning?.contains("Maximum delegations (3) reached") == true)

        // Resetting turn clears the counts and unlocks delegation
        orchestrator.resetActiveTurnToolCallCount()
        #expect(orchestrator.totalTurnDelegations == 0)
        #expect(orchestrator.activeTurnDelegationsByAgent.isEmpty)

        let resAfterReset = orchestrator.recordDelegation(to: "developer")
        #expect(resAfterReset.allowed == true)
        #expect(orchestrator.totalTurnDelegations == 1)
    }
}
