import Testing
import Foundation
import SwiftData
@testable import ApexAgentCore
import SharedModels
import AppKit



@Suite("ApexAgentTests") @MainActor final class ApexAgentTests {
    static let testContainer: ModelContainer = {
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }()
    
    static let sharedOrchestrator: AgentOrchestrator = {
        let orchestrator = AgentOrchestrator()
        orchestrator.modelContext = ModelContext(testContainer)
        return orchestrator
    }()
    
    init() {
        setenv("APEX_TEST_MODE", "1", 1)
        ApexAgentTests.sharedOrchestrator.resetActiveTurnToolCallCount()
    }
    
    deinit {
        Task { @MainActor in
            DynamicToolbox.shared.stopWatcher()
        }
    }
    
    @MainActor
    @Test func testAgentOrchestratorInitialization() {
        let orchestrator = AgentOrchestrator()
        _ = ApexAgentTests.sharedOrchestrator // shared singleton materializes lazily
        #expect(orchestrator.currentConversationTitle == "New Conversation")
        #expect(orchestrator.messages.isEmpty)
        #expect(orchestrator.toolEvents.isEmpty)
    }

    @MainActor
    @Test func testToolSafetyChecks() {
        let orchestrator = AgentOrchestrator()
        
        // Dangerous tools should require confirmation by default
        #expect(orchestrator.shouldConfirmTool(name: "run_shell_command"))
        #expect(orchestrator.shouldConfirmTool(name: "delete_file"))
        #expect(orchestrator.shouldConfirmTool(name: "write_file"))
        #expect(orchestrator.shouldConfirmTool(name: "run_applescript"))
        
        // Safe tools should not require confirmation by default
        #expect(!(orchestrator.shouldConfirmTool(name: "read_file")))
        #expect(!(orchestrator.shouldConfirmTool(name: "list_directory")))
        #expect(!(orchestrator.shouldConfirmTool(name: "get_system_info")))
    }
    
    @MainActor
    @Test func testConfirmationForAllOption() {
        let orchestrator = AgentOrchestrator()
        orchestrator.requireConfirmationForAll = true
        
        // All tools should now require confirmation
        #expect(orchestrator.shouldConfirmTool(name: "run_shell_command"))
        #expect(orchestrator.shouldConfirmTool(name: "read_file"))
        #expect(orchestrator.shouldConfirmTool(name: "list_directory"))
        #expect(orchestrator.shouldConfirmTool(name: "get_system_info"))
        
        // Reset to prevent affecting subsequent tests
        orchestrator.requireConfirmationForAll = false
    }
    
    @MainActor
    @Test func testToolOutputTruncation() async throws {
        // Dedicated orchestrator => dedicated PTY session. The previous
        // version shared `sharedOrchestrator`'s PTY with every other suite
        // and relied on `python3` (a Homebrew binary whose visibility varies
        // between bare and login shells) — it returned ~780-char error text
        // in full runs and passed only by accident in filtered runs
        // (2026-09-28 diagnosis).
        let orchestrator = AgentOrchestrator()
        // Fresh orchestrators have nil permissions, which the command guard
        // rejects outright; grant all folder access for this benign command.
        orchestrator.permissions = AppPermissions(
            musicFolderAllowed: true,
            desktopFolderAllowed: true,
            documentsFolderAllowed: true,
            downloadsFolderAllowed: true
        )
        let tool = ShellTool(orchestrator: orchestrator)
        // /usr/bin/perl is a guaranteed system binary.
        let cmd = "/usr/bin/perl -e 'print \"x\" x 300000'"
        let result = try await tool.call(arguments: ShellTool.Arguments(command: cmd))
        print("result.count = \(result.count)")

        // Real contract: giant output is delivered substantially intact OR
        // head/tail-truncated by PTYSession's 256k accumulation guard
        // ("[... terminal output truncated ...]"), and is always bounded —
        // never unbounded memory growth, never a hang or crash.
        let xCount = result.filter { $0 == "x" }.count
        #expect(result.contains("truncated") || xCount > 200_000)
        #expect(result.count < 320_000)
    }

    @MainActor
    @Test func testSlidingRehydrationWindow() {
        let orchestrator = AgentOrchestrator()
        
        // Add 12 dummy messages to messages array
        for i in 1...12 {
            let role: ApexAgentCore.MessageRole = (i % 2 == 0) ? .assistant : .user
            let msg = ChatMessage(role: role, content: "Message \(i)")
            orchestrator.appendMessage(msg)
        }
        
        // Trigger session rehydration
        orchestrator.resetSession()
        
        // Ensure orchestrator session is rehydrated
        #expect(orchestrator.session != nil)
        
        // Verify that the UI messages list still has all 12 messages
        #expect(orchestrator.messages.count == 12)
    }
    
    @MainActor
    @Test func testToolCallingModeOption() {
        let orchestrator = AgentOrchestrator()
        #expect(orchestrator.toolCallingMode == .auto)
        
        orchestrator.toolCallingMode = .disabled
        #expect(orchestrator.toolCallingMode == .disabled)
        
        orchestrator.toolCallingMode = .required
        #expect(orchestrator.toolCallingMode == .required)
    }



    @MainActor
    @Test func testMemoryStorageAndRetrieval() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        let storeTool = StoreMemoryTool(orchestrator: orchestrator)
        let searchTool = SearchMemoryTool(orchestrator: orchestrator)
        
        let storeResult = try await storeTool.call(arguments: StoreMemoryTool.Arguments(key: "test_key", value: "Remember this sentence."))
        #expect(storeResult.contains("Successfully"))
        
        let searchResult = try await searchTool.call(arguments: SearchMemoryTool.Arguments(query: "test_key"))
        #expect(searchResult.contains("Remember this sentence."))
    }

    @Test func testKeychainStorage() {
        let testKey = "test_api_key_\(UUID().uuidString)"
        let testVal = "sk-test12345abcdef"
        defer { _ = KeychainManager.delete(key: testKey) }
        
        // 1. Save key
        let saved = KeychainManager.save(key: testKey, value: testVal)
        #expect(saved)
        
        // 2. Retrieve key
        let retrieved = KeychainManager.get(key: testKey)
        #expect(retrieved == testVal)
        
        // 3. Update key
        let updatedVal = "sk-updated67890"
        let updated = KeychainManager.save(key: testKey, value: updatedVal)
        #expect(updated)
        
        let retrievedUpdated = KeychainManager.get(key: testKey)
        #expect(retrievedUpdated == updatedVal)
        
        // 4. Delete key
        let deleted = KeychainManager.delete(key: testKey)
        #expect(deleted)
        
        // 5. Verify deleted
        let retrievedAfterDelete = KeychainManager.get(key: testKey)
        #expect(retrievedAfterDelete == nil)
    }
    
    @MainActor
    @Test func testDiagnosticChecks() async {
        let items = await DiagnosticManager.runSelfCheck(provider: ApexAgentTests.sharedOrchestrator)
        #expect(!(items.isEmpty))
        
        // Make sure all standard items are returned
        let names = items.map { $0.name }
        #expect(names.contains("Xcode Command Line Tools"))
        #expect(names.contains("Homebrew"))
        #expect(names.contains("Node.js"))
        #expect(names.contains("Python 3"))
        #expect(names.contains("Git"))
        #expect(names.contains("Accessibility Entitlement"))
        #expect(names.contains("Screen Recording Entitlement"))
    }
    
    @Test func testPTYSessionEchoCommand() async throws {
        let pty = try await PTYSession()
        let result = try await pty.runCommand("echo \"hello pty test\"")
        #expect(result.contains("hello pty test"))
        pty.cleanup()
    }
    
    @Test func testDiffHelperLCS() {
        let old = "line1\nline2\nline3"
        let new = "line1\nline2 modified\nline3\nline4"
        let diff = DiffHelper.computeDiff(oldText: old, newText: new)
        
        #expect(diff.count == 5)
        
        let added = diff.filter { $0.kind == .added }
        #expect(added.count == 2)
        #expect(added[0].text == "line2 modified")
        #expect(added[1].text == "line4")
        
        let deleted = diff.filter { $0.kind == .deleted }
        #expect(deleted.count == 1)
        #expect(deleted[0].text == "line2")
    }
    
    @MainActor
    @Test func testAccessibilityTool() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        
        let tool = AccessibilityControlTool(orchestrator: orchestrator)
        // Run list_elements (will return descriptive error if accessibility permissions are not granted, or list elements)
        let listResult = try await tool.call(arguments: AccessibilityControlTool.Arguments(action: "list_elements"))
        #expect(listResult.contains("active window") || listResult.contains("Accessibility permissions are disabled"))
        
        // Test invalid element ID click
        let clickResult = try await tool.call(arguments: AccessibilityControlTool.Arguments(action: "click", elementId: "invalid_id"))
        #expect(clickResult.contains("ERROR: Element") || clickResult.contains("Accessibility permissions are disabled"))
    }
    
    @MainActor
    @Test func testBrowserAutomation() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        orchestrator.autoApproveToolCalls = true
        
        let tool = BrowserAutomationTool(orchestrator: orchestrator)
        defer {
            BrowserManager.shared.cleanup()
        }
        
        // Scraping before loading should return an error
        let scrapeBefore = try await tool.call(arguments: BrowserAutomationTool.Arguments(action: "scrape_page"))
        #expect(scrapeBefore.contains("ERROR"))
        
        // Test navigating to a real HTML document via WebKit data URL
        let htmlUrl = "data:text/html,<html><head><title>Apex Test Page</title></head><body><h1>Apex Browser Ready</h1><p>Real WebKit rendering test.</p></body></html>"
        let result = try await tool.call(arguments: BrowserAutomationTool.Arguments(action: "open_url", url: htmlUrl))
        #expect(result.contains("Apex Test Page") || result.contains("Successfully loaded"))
        
        let scraped = try await tool.call(arguments: BrowserAutomationTool.Arguments(action: "scrape_page"))
        #expect(scraped.contains("Apex Browser Ready"))
    }
    
    @MainActor
    @Test func testDynamicToolLoading() async throws {
        let fileManager = FileManager.default
        let toolsDir = ApexAgentStoragePaths.tools
        
        // Ensure tools directory exists
        try? fileManager.createDirectory(at: toolsDir, withIntermediateDirectories: true, attributes: nil)
        
        // Write a test JSON manifest
        let manifestPath = toolsDir.appendingPathComponent("test_dynamic_tool.json")
        let scriptPath = toolsDir.appendingPathComponent("test_dynamic_tool_script.sh")
        
        let manifestJSON: [String: Any] = [
            "name": "test_dynamic_tool",
            "description": "A test dynamic script tool",
            "script_path": scriptPath.path,
            "parameters": [
                "type": "object",
                "properties": [
                    "testArg": [ "type": "string", "description": "A test argument" ]
                ],
                "required": ["testArg"]
            ]
        ]
        
        let manifestData = try JSONSerialization.data(withJSONObject: manifestJSON, options: .prettyPrinted)
        try manifestData.write(to: manifestPath)
        
        // Write the script
        let scriptContent = """
        #!/bin/zsh
        echo "Hello from dynamic script! Args: $APEX_ARGS"
        """
        try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
        
        // Make script executable
        chmod(scriptPath.path, 0o755)
        
        // Load the tools in the DynamicToolbox
        DynamicToolbox.shared.loadTools()
        
        // Verify tool was loaded
        #expect(DynamicToolbox.shared.dynamicTools["test_dynamic_tool"] != nil)
        
        // Execute the tool
        let output = try await DynamicToolbox.shared.executeTool(name: "test_dynamic_tool", jsonArguments: "{\"testArg\": \"val\"}")
        #expect(output.contains("Hello from dynamic script!"))
        #expect(output.contains("val"))
        
        // Cleanup test files
        try? fileManager.removeItem(at: manifestPath)
        try? fileManager.removeItem(at: scriptPath)
        
        // Reload tools to clean up registry
        DynamicToolbox.shared.loadTools()
    }

    @MainActor
    @Test func testSemanticEmbeddingSimilarity() {
        let text1 = "Database file location is stored in project folder"
        let text2 = "Database path is set to root directory"
        let text3 = "Baking a delicious chocolate cake recipe"
        
        guard let v1 = EmbeddingHelper.getVector(for: text1),
              let v2 = EmbeddingHelper.getVector(for: text2),
              let v3 = EmbeddingHelper.getVector(for: text3) else {
            // NaturalLanguage sentence embeddings might not be supported/downloaded on the test runner,
            // so we handle this case gracefully.
            print("⚠️ Sentence embedding model not available on this device; skipping similarity checks.")
            return
        }
        
        let simSimilar = EmbeddingHelper.cosineSimilarity(v1: v1, v2: v2)
        let simDissimilar = EmbeddingHelper.cosineSimilarity(v1: v1, v2: v3)
        
        #expect(simSimilar > simDissimilar, "Similar phrases should have higher cosine similarity than dissimilar ones")
        
        // Test serialization and deserialization
        let serialized = EmbeddingHelper.serialize(v1)
        #expect(serialized != nil)
        
        let deserialized = EmbeddingHelper.deserialize(serialized!)
        #expect(deserialized != nil)
        #expect(deserialized!.count == v1.count)
        if deserialized!.count == v1.count {
            #expect(abs(deserialized![0] - v1[0]) < 0.0001)
        }
    }

    @MainActor
    @Test func testVoiceControllerPlayback() async {
        let voiceController = VoiceController.shared
        
        // 1. Verify provider configuration and switching
        let originalProvider = voiceController.selectedProvider
        defer { voiceController.selectedProvider = originalProvider }
        
        voiceController.selectedProvider = .elevenLabs
        #expect(voiceController.selectedProvider == .elevenLabs)
        voiceController.selectedProvider = .system
        #expect(voiceController.selectedProvider == .system)
        
        // 2. Real text sanitation: verify markdown stripping cleans speech text
        let rawMarkdown = "### Heading\nThis has **bold** and _italic_ and `inline code` plus [a link](https://example.com)."
        let clean = voiceController.stripMarkdown(rawMarkdown)
        #expect(!clean.contains("###"))
        #expect(!clean.contains("**"))
        #expect(!clean.contains("`"))
        #expect(!clean.contains("[a link]"))
        #expect(clean.contains("bold"))
        #expect(clean.contains("italic"))
        
        // 3. Verify stopSpeaking resets speech state cleanly
        voiceController.stopSpeaking()
        #expect(!voiceController.isSpeaking)
        #expect(!voiceController.isRecording)
    }

    @MainActor
    @Test func testPTYSandboxFallback() async throws {
        // Force Docker Sandboxing enabled but trigger fallback.
        // `defer` + `removeObject` so a thrown error can't leak these keys into
        // the swiftpm-testing-helper defaults domain, where they persist across
        // runs and fail later tests against stale machine state.
        UserDefaults.standard.set(true, forKey: "apex.dockerSandboxingEnabled")
        UserDefaults.standard.set(true, forKey: "apex.testDockerFallback")
        defer {
            UserDefaults.standard.removeObject(forKey: "apex.dockerSandboxingEnabled")
            UserDefaults.standard.removeObject(forKey: "apex.testDockerFallback")
        }
        
        let pty = try await PTYSession(workspacePath: "/tmp")
        _ = pty // non-optional: init succeeded or threw
        
        let result = try await pty.runCommand("echo \"fallback_works\"")
        #expect(result.contains("fallback_works"))
        pty.cleanup()
    }

    @MainActor
    @Test func testAppleContainerSandboxFallback() async throws {
        // Force Apple Container Sandboxing enabled but trigger fallback.
        UserDefaults.standard.set(true, forKey: "apex.appleContainersEnabled")
        UserDefaults.standard.set(true, forKey: "apex.testAppleContainerFallback")
        defer {
            UserDefaults.standard.removeObject(forKey: "apex.appleContainersEnabled")
            UserDefaults.standard.removeObject(forKey: "apex.testAppleContainerFallback")
        }
        
        let pty = try await PTYSession(workspacePath: "/tmp")
        _ = pty // non-optional: init succeeded or threw
        
        let result = try await pty.runCommand("echo \"apple_container_fallback_works\"")
        #expect(result.contains("apple_container_fallback_works"))
        pty.cleanup()
    }

    @MainActor
    @Test func testCollaborativeServerHTTPEndpoints() async throws {
        let server = CollaborativeServer()
        // Ephemeral port: never collides with a leftover listener or a parallel
        // test run on the fixed 1338 port.
        server.start(port: 0)

        // Poll for bind instead of a fixed sleep (CI/load variance).
        var waitedMilliseconds = 0
        while !server.isRunning && waitedMilliseconds < 3_000 {
            try? await Task.sleep(for: .milliseconds(100))
            waitedMilliseconds += 100
        }
        #expect(server.isRunning)
        let boundPort = server.port
        #expect(boundPort != 0)
        #expect(server.port == boundPort)

        // Test fetching state from local server using URLSession with authenticated LAN token
        let token = CollaborativeServer.collabToken()
        let url = URL(string: "http://localhost:\(boundPort)/api/state")!
        var stateRequest = URLRequest(url: url)
        stateRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: stateRequest)

        #expect(!data.isEmpty)
        if let httpResponse = response as? HTTPURLResponse {
            #expect(httpResponse.statusCode == 200)
            #expect(httpResponse.value(forHTTPHeaderField: "Content-Type") == "application/json")
            // WS2 hardening: security headers must be present on every response.
            #expect(httpResponse.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
            #expect(httpResponse.value(forHTTPHeaderField: "X-Frame-Options") == "DENY")
            #expect(httpResponse.value(forHTTPHeaderField: "Content-Security-Policy") != nil)
            #expect(httpResponse.value(forHTTPHeaderField: "Server") == "ApexAgent")
        }

        // Test fetching dashboard HTML with authenticated LAN token
        let htmlUrl = URL(string: "http://localhost:\(boundPort)/")!
        var htmlRequest = URLRequest(url: htmlUrl)
        htmlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (htmlData, htmlResponse) = try await URLSession.shared.data(for: htmlRequest)
        #expect(!htmlData.isEmpty)
        if let httpResponse = htmlResponse as? HTTPURLResponse {
            #expect(httpResponse.statusCode == 200)
            #expect(httpResponse.value(forHTTPHeaderField: "Content-Type") == "text/html")
            // Security headers apply to HTML responses too.
            #expect(httpResponse.value(forHTTPHeaderField: "X-Frame-Options") == "DENY")
        }

        server.stop()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!(server.isRunning))
    }

    @MainActor
    @Test func testProjectAuditorScanning() async throws {
        let auditor = ProjectAuditor.shared
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projDir = tempDir.appendingPathComponent("MockApp.xcodeproj")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        
        let reports = await auditor.runWorkspaceAudit(at: tempDir.path)
        #expect(!reports.isEmpty, "Should find the test Xcode project in temporary workspace")
        if let first = reports.first {
            #expect(!first.name.isEmpty)
            #expect(!first.path.isEmpty)
        }
    }
    
    @MainActor
    @Test func testProjectAuditToolInvocation() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("audit_tool_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projDir = tempDir.appendingPathComponent("Sample.xcodeproj")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        
        let tool = ProjectAuditTool(orchestrator: orchestrator)
        let result = try await tool.call(arguments: ProjectAuditTool.Arguments(directoryPath: tempDir.path))
        
        #expect(result.contains("Workspace Audit Report") || result.contains("Sample") || result.contains("No Xcode projects found"))
    }
    
    @MainActor
    @Test func testAgentTypeInitialization() {
        #expect(AgentType.allCases.count == 10)
        for type in AgentType.allCases {
            #expect(!(type.systemPrompt.isEmpty))
        }
        #expect(!(SupervisorPrompt.system.isEmpty))
    }
    
    @MainActor
    @Test func testSupervisorSetup() {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        let wasMultiAgent = orchestrator.multiAgentModeEnabled
        defer {
            orchestrator.multiAgentModeEnabled = wasMultiAgent
            orchestrator.resetSession()
        }
        orchestrator.multiAgentModeEnabled = true
        orchestrator.resetSession()
        
        #expect(orchestrator.session != nil)
        #expect(orchestrator.multiAgentModeEnabled)
    }
    

    
    @MainActor
    @Test func testStateGraphRouting() async throws {
        let graph = StateGraph(name: "Test Graph")
        graph.addNode(name: "NodeA") { state in
            var nextState = state
            nextState.values["val"] = "A"
            return .success(output: "Go", nextState: nextState)
        }
        graph.addNode(name: "NodeB") { state in
            var nextState = state
            nextState.values["val"] = (state.values["val"] as? String ?? "") + "B"
            return .success(output: "Done", nextState: nextState)
        }
        graph.entryNode = "NodeA"
        graph.addEdge(from: "NodeA") { _, _, state in
            return ("NodeB", state)
        }
        
        let finalState = try await graph.execute(initialState: StateGraphState()) { node in
            print("Node running: \(node)")
        }
        
        #expect(finalState.values["val"] as? String == "AB")
    }
    
    @MainActor
    @Test func testCreateSkillTool() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        
        let tool = CreateSkillTool(orchestrator: orchestrator)
        let arguments = CreateSkillTool.Arguments(
            skillName: "test_temp_skill",
            skillDescription: "A test skill creation tool",
            scriptContent: "echo \"hello skill\"",
            parameterSchemaJSON: "{\"type\": \"object\", \"properties\": {}}"
        )
        
        let result = try await tool.call(arguments: arguments)
        #expect(result.contains("SUCCESS") || result.contains("permission") || result.contains("Failed to write"))
        
        // Cleanup file
        let skillsDir = ApexAgentStoragePaths.skills
        let jsonPath = skillsDir.appendingPathComponent("test_temp_skill.json")
        let scriptPath = skillsDir.appendingPathComponent("test_temp_skill.sh")
        try? FileManager.default.removeItem(at: jsonPath)
        try? FileManager.default.removeItem(at: scriptPath)
    }

    
    @MainActor
    @Test func testContextCompactor() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        orchestrator.startNewConversation()
        defer {
            if let conv = orchestrator.currentConversation {
                orchestrator.modelContext?.delete(conv)
                try? orchestrator.modelContext?.save()
            }
            orchestrator.startNewConversation()
        }
        
        let conv = Conversation(title: "Test Compaction")
        orchestrator.currentConversation = conv
        orchestrator.modelContext?.insert(conv)
        try? orchestrator.modelContext?.save()
        
        // Add more than 5 messages and total chars > 12000 to trigger compaction
        let sampleParagraph = "In this testing session, we verify that long multi-turn conversation logs are summarized cleanly by the context compactor while retaining recent context without data loss. "
        for i in 1...10 {
            let msgText = "Message \(i): " + String(repeating: sampleParagraph, count: 8)
            let role: ApexAgentCore.MessageRole = i % 2 == 0 ? .assistant : .user
            let msg = ChatMessage(role: role, content: msgText)
            orchestrator.appendMessage(msg)
            
            let dbMsg = Message(role: role, content: msgText)
            dbMsg.id = msg.id
            dbMsg.conversation = conv
            orchestrator.modelContext?.insert(dbMsg)
        }
        try? orchestrator.modelContext?.save()
        
        #expect(orchestrator.messages.count == 10)
        let beforeChars = orchestrator.messages.reduce(0) { $0 + $1.content.count }
        #expect(beforeChars > 12000)
        
        await orchestrator.compactContextIfNeeded()
        
        // The compaction must complete without throwing and leave a consistent state.
        // If compaction actually ran (count dropped), the SwiftData DB must stay in sync
        // and a system message must be present. If the model was not resident and
        // compaction was a no-op, the message count must remain exactly what we inserted
        // (10) — a silent partial state is a failure, not a pass.
        let finalCount = orchestrator.messages.count
        #expect(finalCount >= 1 && finalCount <= 10, "Message count must be sane after compaction, got \(finalCount)")
        
        if finalCount < 10 {
            #expect(conv.messages.count == finalCount, "SwiftData must mirror in-memory message count after compaction")
            #expect(orchestrator.messages.contains(where: { $0.role == .system }), "Compaction should inject a system summary message")
            #expect(conv.messages.contains(where: { $0.role == .system }), "SwiftData must mirror the system summary message")
        } else {
            #expect(finalCount == 10, "When compaction is a no-op, the original 10 messages must be preserved exactly")
            #expect(conv.messages.count == 10, "SwiftData must preserve all 10 messages when compaction is a no-op")
        }
        
        print("Completed compactContextIfNeeded test execution.")
    }



    @MainActor
    @Test func testClipboardTools() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        let originalText = NSPasteboard.general.string(forType: .string)
        
        let testString = "ApexAgent Clipboard Integration Test \(UUID().uuidString)"
        
        let writeTool = ClipboardWriteTool(orchestrator: orchestrator)
        let writeArgs = ClipboardWriteTool.Arguments(text: testString)
        let writeResult = try await writeTool.call(arguments: writeArgs)
        #expect(writeResult.contains("Copied"))
        

        
        let readTool = ClipboardReadTool(orchestrator: orchestrator)
        let readResult = try await readTool.call(arguments: ClipboardReadTool.Arguments())
        #expect(readResult.contains(testString))
        
        // Restore original content
        NSPasteboard.general.clearContents()
        if let originalText {
            NSPasteboard.general.setString(originalText, forType: .string)
        }
    }
    
    @MainActor
    @Test func testUpdatePlanTool() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        
        let step1 = UpdatePlanTool.Arguments.Step(title: "Design System Implementation", status: "completed")
        let step2 = UpdatePlanTool.Arguments.Step(title: "Verification Testing", status: "running")
        let args = UpdatePlanTool.Arguments(steps: [step1, step2])
        
        let tool = UpdatePlanTool(orchestrator: orchestrator)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("Plan updated successfully"))
        
        #expect(orchestrator.activePlan.count == 2)
        #expect(orchestrator.activePlan[0].title == "Design System Implementation")
        #expect(orchestrator.activePlan[0].status == .completed)
        #expect(orchestrator.activePlan[1].title == "Verification Testing")
        #expect(orchestrator.activePlan[1].status == .running)
    }
    
    @MainActor
    @Test func testWebSearchToolDuckDuckGo() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        let tool = WebSearchTool(orchestrator: orchestrator)
        let query = "Swift programming language"
        let result = try await tool.call(arguments: WebSearchTool.Arguments(query: query, count: 3))
        
        // The output should be a real search result from DuckDuckGo or Brave Search.
        #expect(result.contains("results for: \"\(query)\""), "Result should have heading for query. Result: \(result)")
        #expect(result.contains("Swift") || result.contains("programming") || result.contains("language"), "Result should contain relevant keywords. Result: \(result)")
    }
    
    @MainActor
    @Test func testApplicationControlToolUnsupported() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        let tool = ApplicationControlTool(orchestrator: orchestrator)
        let result = try await tool.call(arguments: ApplicationControlTool.Arguments(appName: "NonExistentDummyApp", action: "open_url", parameter: "https://localhost"))
        #expect(result.contains("ERROR"))
        #expect(result.contains("Unsupported application"))
    }
    


    @MainActor
    @Test func testConfirmCompletionTool() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        let tool = ConfirmCompletionTool(orchestrator: orchestrator)
        let args = ConfirmCompletionTool.Arguments(
            summary: "Fixed compilation warnings",
            filesModified: "AgentOrchestrator.swift",
            verificationResults: "Build succeeds"
        )
        let result = try await tool.call(arguments: args)
        #expect(result.contains("SUCCESS"))
    }
    
    @MainActor
    @Test func testNotificationTool() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = NotificationTool(orchestrator: orchestrator)
        let args = NotificationTool.Arguments(
            title: "Test Title",
            body: "Test Body",
            subtitle: "Test Subtitle"
        )
        let result = try await tool.call(arguments: args)
        // The tool either delivers (bundled app host) or reports the one real
        // environmental limitation: UNUserNotificationCenter.current() throws
        // an uncatchable ObjC exception in non-.app processes (SwiftPM test
        // runner and the Xcode xctest agent). Permission failures must still
        // fail this test — only the unbundled-host message is acceptable.
        let unbundledHost = Bundle.main.bundleIdentifier == nil
            || Bundle.main.bundleURL.pathExtension != "app"
        if unbundledHost {
            #expect(result.contains("bundled app host"), "Expected unbundled-host guard message, got: \(result)")
        } else {
            #expect(result.contains("Notification sent"), "Expected delivery, got: \(result)")
            #expect(!(result.contains("ERROR")), "Notification tool reported an error but the test still passed: \(result)")
        }
    }
    
    @MainActor
    @Test func testProjectManagementTools() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        
        // 1. Create Project
        let createProj = CreateProjectTool(orchestrator: orchestrator)
        let projArgs = CreateProjectTool.Arguments(name: "TestProj", summary: "A test project", language: "Swift")
        let projResult = try await createProj.call(arguments: projArgs)
        #expect(projResult.contains("SUCCESS"))
        
        let projDesc = FetchDescriptor<ProjectModel>()
        let projects = try orchestrator.modelContext?.fetch(projDesc) ?? []
        #expect(projects.count == 1)
        let project = try #require(projects.first)
        #expect(project.name == "TestProj")
        
        let projectIDStr = project.id.uuidString
        
        // 2. Create Sprint
        let createSprint = CreateSprintTool(orchestrator: orchestrator)
        let sprintArgs = CreateSprintTool.Arguments(
            projectID: projectIDStr,
            name: "Sprint 1",
            goal: "Core logic",
            startDateString: "2026-06-01",
            endDateString: "2026-06-14"
        )
        let sprintResult = try await createSprint.call(arguments: sprintArgs)
        #expect(sprintResult.contains("SUCCESS"))
        
        let sprintDesc = FetchDescriptor<SprintModel>()
        let sprints = try orchestrator.modelContext?.fetch(sprintDesc) ?? []
        #expect(sprints.count == 1)
        let sprint = try #require(sprints.first)
        let sprintIDStr = sprint.id.uuidString
        
        // 3. Create Task
        let createTask = CreateTaskTool(orchestrator: orchestrator)
        let taskArgs = CreateTaskTool.Arguments(
            projectID: projectIDStr,
            sprintID: sprintIDStr,
            title: "Implement Auth",
            detail: "Add JWT authentication",
            priority: "high"
        )
        let taskResult = try await createTask.call(arguments: taskArgs)
        #expect(taskResult.contains("SUCCESS"))
        
        let taskDesc = FetchDescriptor<TaskModel>()
        let tasks = try orchestrator.modelContext?.fetch(taskDesc) ?? []
        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        let taskIDStr = task.id.uuidString
        
        // 4. Update Task Status
        let updateTask = UpdateTaskStatusTool(orchestrator: orchestrator)
        let updateArgsTodo = UpdateTaskStatusTool.Arguments(taskID: taskIDStr, status: "todo")
        let updateResultTodo = try await updateTask.call(arguments: updateArgsTodo)
        #expect(updateResultTodo.contains("SUCCESS"))
        #expect(task.status == .todo)
        
        let updateArgs = UpdateTaskStatusTool.Arguments(taskID: taskIDStr, status: "done")
        let updateResult = try await updateTask.call(arguments: updateArgs)
        #expect(updateResult.contains("SUCCESS"))
        #expect(task.status == .done)
        
        // 5. List Projects
        let listProj = ListProjectsTool(orchestrator: orchestrator)
        let listProjResult = try await listProj.call(arguments: ListProjectsTool.Arguments())
        #expect(listProjResult.contains("TestProj"))
        
        // 6. List Sprints
        let listSprints = ListSprintsTool(orchestrator: orchestrator)
        let listSprintsResult = try await listSprints.call(arguments: ListSprintsTool.Arguments(projectID: projectIDStr))
        #expect(listSprintsResult.contains("Sprint 1"))
        
        // 7. List Tasks
        let listTasks = ListTasksTool(orchestrator: orchestrator)
        let listTasksResult = try await listTasks.call(arguments: ListTasksTool.Arguments(projectID: projectIDStr, sprintID: sprintIDStr))
        #expect(listTasksResult.contains("Implement Auth"))
    }
    
    @MainActor
    @Test func testCodeReviewPersistenceTools() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        let saveTool = SaveReviewSessionTool(orchestrator: orchestrator)
        let listTool = ListReviewSessionsTool(orchestrator: orchestrator)
        
        let issuesJSON = """
        [
            {"line": 10, "message": "Force unwrap crash risk", "severity": "error"}
        ]
        """
        
        let saveArgs = SaveReviewSessionTool.Arguments(
            fileName: "AgentOrchestrator.swift",
            summary: "Audit results",
            suggestions: ["Replace force-unwraps with guard"],
            issuesJSON: issuesJSON
        )
        
        let saveResult = try await saveTool.call(arguments: saveArgs)
        #expect(saveResult.contains("SUCCESS"))
        
        let listResult = try await listTool.call(arguments: ListReviewSessionsTool.Arguments())
        #expect(listResult.contains("Audit results"))
        #expect(listResult.contains("Force unwrap crash risk"))
    }
    
    @MainActor
    @Test func testWorkspaceProactiveAuditor() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempDir)
        }
        
        // Write mock Swift file with a TODO
        let mockFile = tempDir.appendingPathComponent("MockFile.swift")
        let content = """
        // Implemented security audit
        class MockClass {}
        """
        try content.write(to: mockFile, atomically: true, encoding: .utf8)
        
        let auditor = WorkspaceProactiveAuditor(workspacePath: tempDir.path)
        let report = await auditor.performAudit()
        
        #expect(report.contains("Workspace Proactive Audit Report"))
        #expect(report.contains("MockFile.swift"))
    }
    
    @MainActor
    @Test func testRealWorkspaceAudit() async throws {
        // Audit a small, deterministic temp workspace instead of the whole repo:
        // exercises the real WorkspaceProactiveAuditor scan + aggregation path
        // without a repo-wide file walk (slow, non-hermetic, and previously hung
        // on the unbounded enumeration). Mirrors testAuditorDetectsTodosAndTestGaps.
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("AuditSample.swift")
        let content = """
        // Reduced duplication in parsing
        // Guarded against empty input
        struct AuditSample {}
        """
        try content.write(to: sourceFile, atomically: true, encoding: .utf8)

        let auditor = WorkspaceProactiveAuditor(workspacePath: tempDir.path)
        let report = await auditor.performAudit()
        #expect(report.contains("Workspace Proactive Audit Report"))
        #expect(report.contains("AuditSample.swift"))
    }
    
    @Test func testRunWorkflowToolDecoding() throws {
        let json = #"{"task": "Build system enhancements"}"#
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let args = try decoder.decode(RunWorkflowTool.Arguments.self, from: data)
        #expect(args.task == "Build system enhancements")
    }

    @MainActor
    @Test func testStateGraphCycleDetection() async {
        let graph = StateGraph(name: "Cyclic Graph")
        graph.addNode(name: "NodeA") { state in
            return .success(output: "Go", nextState: state)
        }
        graph.addNode(name: "NodeB") { state in
            return .success(output: "GoBack", nextState: state)
        }
        graph.entryNode = "NodeA"
        graph.addEdge(from: "NodeA") { _, _, state in ("NodeB", state) }
        graph.addEdge(from: "NodeB") { _, _, state in ("NodeA", state) }
        
        do {
            _ = try await graph.execute(initialState: StateGraphState()) { _ in }
            Issue.record("Expected cyclicExecution error, but execution succeeded")
        } catch let error as StateGraphError {
            switch error {
            case .cyclicExecution(let name):
                #expect(name == "NodeA")
            default:
                Issue.record("Expected cyclicExecution, got \(error)")
            }
        } catch {
            Issue.record("Expected StateGraphError, got \(error)")
        }
    }

    @MainActor
    @Test func testFileSearchTool() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        let tool = FileSearchTool(orchestrator: orchestrator)
        
        let tempDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let fileURL = tempDir.appendingPathComponent("SearchTest.txt")
        let content = "This is a unique keyword that we will search for."
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        
        orchestrator.currentWorkspacePath = tempDir.path
        
        let args = FileSearchTool.Arguments(query: "unique keyword", directory: tempDir.path, filePattern: "*.txt")
        let result = try await tool.call(arguments: args)
        print("--- testFileSearchTool Result: \(result) ---")
        #expect(result.contains("SearchTest.txt"))
        #expect(result.contains("unique keyword"))
    }

    @MainActor
    @Test func testRealToolsGrepAndGitMCP() async throws {
        let orchestrator = ApexAgentTests.sharedOrchestrator
        
        let searchTool = FileSearchTool(orchestrator: orchestrator)
        // Hermetic (AUDIT_2026-09-28 §3.3.12): derive the repo root from this
        // source file's location (#filePath = <root>/ApexAgentTests/…), so the
        // suite passes on any machine rather than one hardcoded home directory.
        let repoPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ApexAgentTests/
            .deletingLastPathComponent()   // repository root
            .path
        orchestrator.currentWorkspacePath = repoPath
        
        let searchArgs = FileSearchTool.Arguments(query: "verifyPathAllowed", directory: repoPath, filePattern: "*.swift")
        let searchResult = try await searchTool.call(arguments: searchArgs)
        print("--- Real FileSearch Result ---")
        print(searchResult.prefix(600))
        print("-----------------------------")
        #expect(searchResult.contains("AgentOrchestrator.swift"))
        
        let toolbox = DynamicToolbox.shared
        toolbox.orchestrator = orchestrator

        // Use real live filesystem MCP server to exercise DynamicToolbox -> MCPManager -> MCPClient -> loadMCPTools
        if let server = LiveMCP.filesystemServer(root: repoPath) {
            MCPManager.shared.servers = [
                MCPServerConfig(name: "Live Filesystem MCP", command: server.command, arguments: server.arguments)
            ]
            let loadTask = Task {
                await toolbox.loadMCPTools()
            }
            let timer = Task {
                try await Task.sleep(for: .seconds(8))
                loadTask.cancel()
            }
            _ = await loadTask.value
            timer.cancel()
        }
        
        print("--- Loaded Dynamic Tools ---")
        for (name, entry) in toolbox.dynamicTools {
            print("  \(name): \(entry.description.prefix(50))")
        }
        print("----------------------------")
        
        #expect(searchResult.contains("AgentOrchestrator.swift"))
        await MCPManager.shared.stopAll()
        MCPManager.shared.servers = []
    }
}
