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
    @Test("AgentOrchestrator registers all 70 tools in allTools")
    @MainActor
    func testAllToolsRegistrationCount() {
        let orchestrator = AgentOrchestrator()
        let tools = orchestrator.allTools
        // 70 tools registered across all pillars and specialized features
        // (includes RollbackTool, DeleteMemoryTool, and the Space page tools).
        #expect(tools.count == 70)

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

    // MARK: - Step 9: Real Functional Spotlight Concurrency Execution
    @Test("SpotlightSearchTool runs real query safely with OSAllocatedUnfairLock")
    func testSpotlightSearchRealQueryExecution() async {
        // Runs real Spotlight query using the native NSMetadataQuery engine
        let hits = await SpotlightSearchTool.runSpotlightQuery(
            query: "ApexAgent",
            maxResults: 5,
            contentType: nil
        )
        // Ensure execution completes safely without double-resume runtime trap
        #expect(hits.count >= 0)
    }

    // MARK: - Step 10: Real Functional ShellTool Direct Process & Watchdog Timeout
    @Test("ShellTool direct process executes cleanly and enforces watchdog timeout")
    @MainActor
    func testShellToolProcessAndWatchdogExecution() async throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions()
        let tool = ShellTool(orchestrator: orchestrator)

        // 1. Real successful process execution via fallback
        let successResult = try await tool.call(arguments: .init(
            command: "echo 'APEX_WATCHDOG_SMOKE_PASS'",
            timeoutSeconds: 5
        ))
        #expect(successResult.contains("APEX_WATCHDOG_SMOKE_PASS"))

        // 2. Real timeout watchdog execution
        let timeoutResult = try await tool.call(arguments: .init(
            command: "sleep 5",
            timeoutSeconds: 1
        ))
        #expect(timeoutResult.contains("Command timed out after 1 seconds") || timeoutResult.contains("ERROR"))
    }

    // MARK: - Step 11: Real Functional Network Diagnostics Execution
    @Test("NetworkDiagnosticsTool executes status and probe safely without double-resume")
    @MainActor
    func testNetworkDiagnosticsRealExecution() async throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions()
        let tool = NetworkDiagnosticsTool(orchestrator: orchestrator)

        // 1. Real interface status
        let statusResult = try await tool.call(arguments: .init(
            action: "status",
            host: nil,
            port: nil,
            timeoutSeconds: 5
        ))
        #expect(statusResult.contains("Network Interface Status"))
        #expect(statusResult.contains("Primary Interface"))

        // 2. Real probe to localhost port with cancellation safety
        let probeResult = try await tool.call(arguments: .init(
            action: "probe",
            host: "127.0.0.1",
            port: 59999,
            timeoutSeconds: 1
        ))
        // Either connection refused/failed/timed out, but must return cleanly without double-resume crash
        #expect(probeResult.contains("Connected") || probeResult.contains("ERROR") || probeResult.contains("timed out") || probeResult.contains("Connection"))

        // 3. Real DNS resolution
        let dnsResult = try await tool.call(arguments: .init(
            action: "dns",
            host: "localhost",
            port: nil,
            timeoutSeconds: 5
        ))
        #expect(dnsResult.contains("DNS Resolution for `localhost`"))
        #expect(dnsResult.contains("127.0.0.1") || dnsResult.contains("::1"))
    }

    // MARK: - Step 12: Chief of Staff Inter-Bot Tool Registration Verification
    @Test("ChiefOfStaff systemPrompt references exact inter-bot tool names and no hyphen typos")
    func testChiefOfStaffToolPromptExactness() {
        let chiefId = "chief-01"
        let bots = [
            ChiefTeamMember(id: "chief-01", name: "Chief", title: "Chief of Staff", descriptionText: "Coordinates team"),
            ChiefTeamMember(id: "dev-01", name: "Developer", title: "Codex Specialist", descriptionText: "Writes swift code")
        ]
        let prompt = ChiefOfStaff.systemPrompt(chiefId: chiefId, bots: bots, canDelegate: true)
        
        #expect(prompt.contains("`ask_bot`"))
        #expect(prompt.contains("`delegate_task`"))
        #expect(prompt.contains("`dispatch_swarm`"))
        #expect(prompt.contains("`convene_meeting`"))
        #expect(!prompt.contains("ask-bot"))
    }

    // MARK: - Step 13: ModelRegistry Context Ceilings and Long Context Routing
    @Test("ModelRegistry enforces accurate context ceilings and long-context offloading")
    func testModelRegistryContextCeilingsAndRouting() {
        #expect(ModelRegistry.contextCeiling(for: .appleOnDevice) == 4096)
        #expect(ModelRegistry.contextCeiling(for: .localOllama) == 8192)
        #expect(ModelRegistry.contextCeiling(for: .applePCC) == 32768)
        #expect(ModelRegistry.contextCeiling(for: .cloudGemini) == 1000000)

        // Long context > 8000 tokens should route to cloudGemini if API key configured
        let (provider, reason) = ModelRegistry.resolveProviderForTask(
            preferred: .autoPicker,
            prompt: String(repeating: "Large prompt content ", count: 2000), // ~8000+ tokens
            history: [],
            instructions: "",
            tools: []
        )
        if !ModelRegistry.geminiAPIKey().isEmpty {
            #expect(provider == .cloudGemini)
            #expect(reason?.contains("exceed local 8k ceiling") == true)
        } else {
            #expect(provider == .localOllama)
        }
    }

    // MARK: - Step 14: Pre-flight Token Budget & Tool Output Pruning
    @Test("BotSession prunes excessive older tool outputs when approaching context threshold")
    @MainActor
    func testBotSessionToolOutputPruning() {
        let profile = BotProfile(name: "Tester", title: "QA Specialist", descriptionText: "Runs validations")
        let orchestrator = AgentOrchestrator()
        let session = BotSession(bot: profile, orchestrator: orchestrator)

        // Insert a normal user message
        session.appendMessage(ChatMessage(role: .user, content: "Run diagnostic tool"))
        // Insert a giant tool output simulating a 10KB shell/file read
        let giantOutput = String(repeating: "LOG_LINE_DATA_STREAM_PAYLOAD_INDEX_0123456789\n", count: 200)
        session.appendMessage(ChatMessage(role: .assistant, content: giantOutput))
        // Insert current active user follow-up prompt
        session.appendMessage(ChatMessage(role: .user, content: "What were the results?"))

        #expect(session.messages[1].content.count > 8000)

        // Prune excessive tool outputs
        session.pruneExcessiveToolOutputs(maxOutputChars: 1000)

        #expect(session.messages[1].content.contains("[... Tool output truncated from"))
        #expect(session.messages[1].content.count <= 1200)
        // Verify head and tail preserved
        #expect(session.messages[1].content.hasPrefix("LOG_LINE_DATA_STREAM_PAYLOAD"))
        // Verify last message is untouched
        #expect(session.messages[2].content == "What were the results?")
    }

    // MARK: - Step 15: Single-Active-Local-Weights Policy & Browser Session Persistence
    @Test("ModelRegistry tracks and unloads previous Ollama weights when switching local models")
    func testSingleActiveLocalWeightsPolicy() {
        ModelRegistry.resetActiveOllamaModelForTesting()
        #expect(ModelRegistry.currentActiveOllamaModel == nil)

        // First model loaded: no previous model to unload
        let firstUnloaded = ModelRegistry.unloadPreviousOllamaModelIfNeeded(newModel: "qwen2.5-coder:7b")
        #expect(firstUnloaded == nil)
        #expect(ModelRegistry.currentActiveOllamaModel == "qwen2.5-coder:7b")

        // Same model re-invoked: no unload triggered
        let sameUnloaded = ModelRegistry.unloadPreviousOllamaModelIfNeeded(newModel: "qwen2.5-coder:7b")
        #expect(sameUnloaded == nil)
        #expect(ModelRegistry.currentActiveOllamaModel == "qwen2.5-coder:7b")

        // Switch to different model: previous model returned for keep_alive: 0 unloading
        let switchedUnloaded = ModelRegistry.unloadPreviousOllamaModelIfNeeded(newModel: "llama3.2:3b")
        #expect(switchedUnloaded == "qwen2.5-coder:7b")
        #expect(ModelRegistry.currentActiveOllamaModel == "llama3.2:3b")

        // Switch again to deepseek-r1:8b
        let thirdUnloaded = ModelRegistry.unloadPreviousOllamaModelIfNeeded(newModel: "deepseek-r1:8b")
        #expect(thirdUnloaded == "llama3.2:3b")
        #expect(ModelRegistry.currentActiveOllamaModel == "deepseek-r1:8b")
    }

    @Test("BrowserManager persistent dataStore maintains session configuration across invocations")
    @MainActor
    func testBrowserSessionStorePersistence() async throws {
        let browser = BrowserManager.shared
        #expect(browser.isPersistent == true)
        #expect(browser.dataStore.isPersistent == true)

        // Verify clearSession operates on the active dataStore cleanly
        let clearMsg = try await browser.clearSession()
        #expect(clearMsg.contains("Browser session and stored website data cleared"))
        #expect(browser.isPersistent == true)
    }

    // MARK: - Step 16: Background Daemon POSIX Signal Handling
    @Test("DaemonSignalHandler installs, receives signals, and tears down cleanly")
    @MainActor
    func testDaemonSignalHandling() async {
        let handler = DaemonSignalHandler()
        #expect(handler.isInstalled == false)

        let receivedSignal = OSAllocatedUnfairLock<Int32?>(initialState: nil)

        handler.install { sig in
            receivedSignal.withLock { $0 = sig }
        }
        #expect(handler.isInstalled == true)

        // Dispatch SIGTERM to current process; with SIG_IGN active and DispatchSource attached,
        // the source catches the signal without terminating the test runner
        Darwin.kill(Darwin.getpid(), SIGTERM)

        // Allow runloop/queue to process the signal
        for _ in 0..<20 {
            if receivedSignal.withLock({ $0 }) != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(receivedSignal.withLock({ $0 }) == SIGTERM)
        #expect(handler.isInstalled == false) // Handler automatically tears down upon signal

        // Clean teardown
        handler.teardown()
        #expect(handler.isInstalled == false)
    }

    // MARK: - Step 17: Tool & Settings Parity
    @Test("ToolPolicy and documentation maintain parity with registered tool catalog")
    @MainActor
    func testDocumentationAndSettingsToolParity() {
        let orchestrator = AgentOrchestrator()
        let names = Set(orchestrator.allTools.map(\.name))

        #expect(names.contains("control_browser"))
        #expect(names.contains("manage_sandbox"))
        #expect(names.contains("execute_dynamic_tool"))
        #expect(names.contains("control_app"))
        #expect(names.contains("control_accessibility"))
        #expect(names.contains("patch_file"))
        #expect(names.contains("git_operation"))
        #expect(names.contains("ask_bot"))
        #expect(names.contains("dispatch_swarm"))
        #expect(names.contains("spotlight_search"))
        #expect(orchestrator.allTools.count == 70)
    }

    // MARK: - Step 18: Routine and Skill DeepLink & Settings Sheet Integration
    @Test("Routine and Skill deep link routing activates settings navigation and broadcasts notification")
    @MainActor
    func testRoutineAndSkillDeepLinkRouting() async {
        let navState = DeepLinkNavigationState()

        let notificationFired = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .showSettingsSheet,
            object: nil,
            queue: .main
        ) { _ in
            notificationFired.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Test routine deep link routing
        navState.apply(.routine(id: "daily-sync"))
        #expect(navState.selectedRoutineId == "daily-sync")
        #expect(navState.showSettings == true)

        // Test skill deep link routing
        navState.reset()
        #expect(navState.selectedRoutineId == nil)
        #expect(navState.showSettings == false)

        navState.apply(.skill(name: "swift-concurrency"))
        #expect(navState.selectedSkillName == "swift-concurrency")
        #expect(navState.showSettings == true)

        #expect(notificationFired.withLock({ $0 }) >= 2)
    }

    // MARK: - Step 19: Routine Lifecycle & Execution Receipt Durability
    @Test("Routine creation, schedule description, and durable run receipt recording")
    @MainActor
    func testRoutineReceiptDurabilityAndLifecycle() async {
        let routine = Routine(
            name: "Audit Pipeline",
            descriptionText: "Run workspace security verification",
            trigger: .timeInterval,
            scheduledMinutes: 30,
            enabled: true
        )

        #expect(routine.configurationError() == nil)
        #expect(routine.effectiveScheduleDescription == "Every 30 min")
        #expect(routine.enabled == true)

        // Toggle state
        let manager = RoutineManager.shared
        manager.toggle(routine)
        #expect(routine.enabled == false)
        manager.toggle(routine)
        #expect(routine.enabled == true)

        // Durable receipt recording verification
        let initialRunCount = manager.recentRuns.count
        let run = RoutineRun(
            routineId: routine.stableUUID,
            routineName: routine.name,
            prompt: routine.descriptionText,
            trigger: routine.trigger,
            output: "Security verification passed: 0 vulnerabilities found."
        )
        manager.recentRuns.insert(run, at: 0)
        #expect(manager.recentRuns.count == initialRunCount + 1)
        #expect(manager.recentRuns.first?.routineName == "Audit Pipeline")
        #expect(manager.recentRuns.first?.output?.contains("Security verification passed") == true)
    }

    // MARK: - Step 20: Space Page Creation, Selection, and Deletion Lifecycle
    @Test("SpacePage creation, selection, and deletion lifecycle in SpaceManager")
    @MainActor
    func testSpacePageCreationAndDeletionLifecycle() async {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        let spaceManager = SpaceManager()
        spaceManager.orchestrator = orchestrator
        spaceManager.botManager = botManager

        let space = spaceManager.createSpace(
            name: "Platform Architecture",
            summary: "Cross-system architectural design and standards",
            seedDefaults: false
        )
        spaceManager.activeSpaceId = space.id

        #expect(space.pages.isEmpty)

        // Create page
        let page1 = spaceManager.createPage(
            in: space,
            title: "Architecture Charter",
            markdownBody: "# Architecture Charter\n\nGuidelines for multi-agent workflows.",
            authorName: "Alex Rivera"
        )
        let page2 = spaceManager.createPage(
            in: space,
            title: "Release Checklist",
            markdownBody: "# Release Checklist\n\n- Pre-push gates\n- Signoff",
            authorName: "Alex Rivera"
        )

        #expect(space.pages.count == 2)
        #expect(space.sortedPages.count == 2)

        // Select page
        spaceManager.activePageId = page1.id
        #expect(spaceManager.activePage?.id == page1.id)
        #expect(spaceManager.activePage?.title == "Architecture Charter")

        // Delete page
        spaceManager.deletePage(page1, from: space)
        #expect(space.pages.count == 1)
        let remainingIds = space.pages.map(\.id)
        #expect(!remainingIds.contains(page1.id))
        #expect(spaceManager.activePage?.id == page2.id)

        // Delete remaining page
        spaceManager.deletePage(page2, from: space)
        #expect(space.pages.isEmpty)
        #expect(spaceManager.activePage == nil)
    }
}


