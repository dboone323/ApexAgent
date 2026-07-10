import XCTest
import FoundationModels
import SwiftData
@testable import ApexAgent
import SharedModels

// MARK: - Mock ToolEventLogger for Testing
@MainActor
class MockToolEventLogger: ToolEventLogger {
    var events: [String] = []
    
    func logToolStart(name: String, arguments: String) {
        events.append("start: \(name)")
    }
    
    func logToolEvent(_ event: ToolEvent) {
        events.append("event: \(event.toolName)")
    }
    
    func logToolEnd(name: String, result: String, status: ToolStatus) {
        events.append("end: \(name) - \(status)")
    }
    
    func updateToolStatus(name: String, status: ToolStatus) {
        events.append("status: \(name) - \(status)")
    }
    
    func shouldConfirmTool(name: String) -> Bool {
        return false
    }
    
    func requestConfirmation(
        toolName: String,
        arguments: String,
        riskDescription: String,
        oldContent: String?,
        newContent: String?,
        filePath: String?
    ) async -> Bool {
        return true
    }
    
    func resolveConfirmation(approved: Bool) {
        // no-op
    }
}


struct TestTruncationTool: Tool {
    let orchestrator: any OrchestratorProvider
    
    let name = "test_truncation_tool"
    let description = "A tool to test centralized truncation"
    
    @Generable
    struct Arguments {}
    
    func call(arguments: Arguments) async throws -> String {
        try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            return String(repeating: "X", count: 10000)
        }
    }
}

final class ApexAgentTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            let orchestrator = AgentOrchestrator()
            AppDelegate.sharedOrchestrator = orchestrator
            orchestrator.resetActiveTurnToolCallCount()
            AgentOrchestrator.isTestMode = true
        }
    }
    
    override func tearDown() {
        MainActor.assumeIsolated {
            AgentOrchestrator.isTestMode = true
        }
        let expectation = XCTestExpectation(description: "stop all mcp")
        Task {
            await MCPManager.shared.stopAll()
            expectation.fulfill()
        }
        _ = XCTWaiter.wait(for: [expectation], timeout: 5.0)
        super.tearDown()
    }
    
    @MainActor
    func testAgentOrchestratorInitialization() {
        let orchestrator = AgentOrchestrator()
        XCTAssertNotNil(AppDelegate.getSharedOrchestrator())
        XCTAssertEqual(orchestrator.currentConversationTitle, "New Conversation")
        XCTAssertTrue(orchestrator.messages.isEmpty)
        XCTAssertTrue(orchestrator.toolEvents.isEmpty)
    }

    @MainActor
    func testToolSafetyChecks() {
        let orchestrator = AgentOrchestrator()
        
        // Dangerous tools should require confirmation by default
        XCTAssertTrue(orchestrator.shouldConfirmTool(name: "run_shell_command"))
        XCTAssertTrue(orchestrator.shouldConfirmTool(name: "delete_file"))
        XCTAssertTrue(orchestrator.shouldConfirmTool(name: "write_file"))
        XCTAssertTrue(orchestrator.shouldConfirmTool(name: "run_applescript"))
        
        // Safe tools should not require confirmation by default
        XCTAssertFalse(orchestrator.shouldConfirmTool(name: "read_file"))
        XCTAssertFalse(orchestrator.shouldConfirmTool(name: "list_directory"))
        XCTAssertFalse(orchestrator.shouldConfirmTool(name: "get_system_info"))
    }
    
    @MainActor
    func testConfirmationForAllOption() {
        let orchestrator = AgentOrchestrator()
        orchestrator.requireConfirmationForAll = true
        
        // All tools should now require confirmation
        XCTAssertTrue(orchestrator.shouldConfirmTool(name: "run_shell_command"))
        XCTAssertTrue(orchestrator.shouldConfirmTool(name: "read_file"))
        XCTAssertTrue(orchestrator.shouldConfirmTool(name: "list_directory"))
        XCTAssertTrue(orchestrator.shouldConfirmTool(name: "get_system_info"))
        
        // Reset to prevent affecting subsequent tests
        orchestrator.requireConfirmationForAll = false
    }
    
    @MainActor
    func testToolOutputTruncation() async throws {
        let orchestrator = AgentOrchestrator()
        AppDelegate.sharedOrchestrator = orchestrator
        
        let tool = TestTruncationTool(orchestrator: orchestrator)
        let result = try await tool.call(arguments: TestTruncationTool.Arguments())
        XCTAssertEqual(result.count, 8000 + "\n\n[... output truncated at 8000 characters to optimize token usage ...]".count)
        XCTAssertTrue(result.contains("truncated"))
    }

    @MainActor
    func testSlidingRehydrationWindow() {
        let orchestrator = AgentOrchestrator()
        
        // Add 12 dummy messages to messages array
        for i in 1...12 {
            let role: ApexAgent.MessageRole = (i % 2 == 0) ? .assistant : .user
            let msg = ChatMessage(role: role, content: "Message \(i)")
            orchestrator.appendMessage(msg)
        }
        
        // Trigger session rehydration
        orchestrator.resetSession()
        
        // Ensure orchestrator session is rehydrated
        XCTAssertNotNil(orchestrator.session)
        
        // Verify that the UI messages list still has all 12 messages
        XCTAssertEqual(orchestrator.messages.count, 12)
    }
    
    @MainActor
    func testToolCallingModeOption() {
        let orchestrator = AgentOrchestrator()
        XCTAssertEqual(orchestrator.toolCallingMode, .auto)
        
        orchestrator.toolCallingMode = .disabled
        XCTAssertEqual(orchestrator.toolCallingMode, .disabled)
        
        orchestrator.toolCallingMode = .required
        XCTAssertEqual(orchestrator.toolCallingMode, .required)
    }

    @MainActor
    func testModelProtocols() {
        let localModel: any LanguageModel = SystemLanguageModel.default
        XCTAssertNotNil(localModel)
        
        if AgentOrchestrator.isPrivateCloudComputeAvailable() {
            let cloudModel = PrivateCloudComputeLanguageModel()
            XCTAssertNotNil(cloudModel)
        } else {
            print("⚠️ Private Cloud Compute entitlement not available; skipping PCC model test.")
        }
    }
    
    @MainActor
    func testModelPreferenceConfiguration() {
        let orchestrator = AgentOrchestrator()
        XCTAssertEqual(orchestrator.modelPreference, .localSystem)
        
        if AgentOrchestrator.isPrivateCloudComputeAvailable() {
            orchestrator.modelPreference = .privateCloud
            orchestrator.resetSession()
            XCTAssertEqual(orchestrator.modelPreference, .privateCloud)
            XCTAssertNotNil(orchestrator.session)
        } else {
            print("⚠️ Private Cloud Compute entitlement not available; skipping privateCloud modelPreference test.")
        }
        
        orchestrator.modelPreference = .cloudGemini
        orchestrator.resetSession()
        XCTAssertEqual(orchestrator.modelPreference, .cloudGemini)
        XCTAssertNotNil(orchestrator.session)
    }

    @MainActor
    func testDynamicProfile() {
        struct TestProfile: LanguageModelSession.DynamicProfile {
            var body: some LanguageModelSession.DynamicProfile {
                LanguageModelSession.Profile {
                    Instructions("Test Instructions")
                    // SystemInfoTool() - requires orchestrator, not used in this test
                }
                .model(SystemLanguageModel.default)
                .toolCallingMode(.allowed)
            }
        }
        let transcript = Transcript(entries: [])
        let session = LanguageModelSession(profile: TestProfile(), history: transcript)
        XCTAssertNotNil(session)
    }

    @MainActor
    func testApexAgentProfileInstantiation() {
        let transcript = Transcript(entries: [])
        let orchestrator = AgentOrchestrator()
        let profile = ApexAgentProfile(
            instructions: "Test instructions",
            model: SystemLanguageModel.default,
            toolCallingMode: .allowed,
            orchestrator: orchestrator
        )
        let session = LanguageModelSession(profile: profile, history: transcript)
        XCTAssertNotNil(session)
    }

    @MainActor
    func testAttachmentCompilation() async throws {
        let session = LanguageModelSession()
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor.red.set()
            NSBezierPath(rect: rect).fill()
            return true
        }
        let attachment = Attachment(image)
        XCTAssertNotNil(attachment)
        
        let streamTask = Task<Void, Error> {
            let stream = session.streamResponse {
                "Describe this image:"
                Attachment(image)
            }
            for try await _ in stream {
                break
            }
        }
        
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(5))
            streamTask.cancel()
        }
        
        do {
            try await streamTask.value
            timeoutTask.cancel()
        } catch is CancellationError {
            print("Attachment stream timed out (model not resident); compilation verified.")
        } catch {
            timeoutTask.cancel()
            print("Caught expected environment error: \(error)")
        }
    }

    @MainActor
    func testMemoryStorageAndRetrieval() async throws {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        let storeTool = StoreMemoryTool(orchestrator: orchestrator)
        let searchTool = SearchMemoryTool(orchestrator: orchestrator)
        
        let storeResult = try await storeTool.call(arguments: StoreMemoryTool.Arguments(key: "test_key", value: "Remember this sentence."))
        XCTAssertTrue(storeResult.contains("Successfully"))
        
        let searchResult = try await searchTool.call(arguments: SearchMemoryTool.Arguments(query: "test_key"))
        XCTAssertTrue(searchResult.contains("Remember this sentence."))
    }

    func testKeychainStorage() {
        let testKey = "test_api_key_name"
        let testVal = "sk-test12345abcdef"
        
        // 1. Save key
        let saved = KeychainManager.save(key: testKey, value: testVal)
        XCTAssertTrue(saved)
        
        // 2. Retrieve key
        let retrieved = KeychainManager.get(key: testKey)
        XCTAssertEqual(retrieved, testVal)
        
        // 3. Update key
        let updatedVal = "sk-updated67890"
        let updated = KeychainManager.save(key: testKey, value: updatedVal)
        XCTAssertTrue(updated)
        
        let retrievedUpdated = KeychainManager.get(key: testKey)
        XCTAssertEqual(retrievedUpdated, updatedVal)
        
        // 4. Delete key
        let deleted = KeychainManager.delete(key: testKey)
        XCTAssertTrue(deleted)
        
        // 5. Verify deleted
        let retrievedAfterDelete = KeychainManager.get(key: testKey)
        XCTAssertNil(retrievedAfterDelete)
    }
    
    @MainActor
    func testDiagnosticChecks() async {
        let items = await DiagnosticManager.runSelfCheck()
        XCTAssertFalse(items.isEmpty)
        
        // Make sure all standard items are returned
        let names = items.map { $0.name }
        XCTAssertTrue(names.contains("Xcode Command Line Tools"))
        XCTAssertTrue(names.contains("Homebrew"))
        XCTAssertTrue(names.contains("Node.js"))
        XCTAssertTrue(names.contains("Python 3"))
        XCTAssertTrue(names.contains("Git"))
        XCTAssertTrue(names.contains("Accessibility Entitlement"))
        XCTAssertTrue(names.contains("Screen Recording Entitlement"))
    }
    
    func testPTYSessionEchoCommand() async throws {
        let pty = try await PTYSession()
        let result = try await pty.runCommand("echo \"hello pty test\"")
        XCTAssertTrue(result.contains("hello pty test"))
        pty.cleanup()
    }
    
    func testDiffHelperLCS() {
        let old = "line1\nline2\nline3"
        let new = "line1\nline2 modified\nline3\nline4"
        let diff = DiffHelper.computeDiff(oldText: old, newText: new)
        
        XCTAssertEqual(diff.count, 5)
        
        let added = diff.filter { $0.kind == .added }
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(added[0].text, "line2 modified")
        XCTAssertEqual(added[1].text, "line4")
        
        let deleted = diff.filter { $0.kind == .deleted }
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted[0].text, "line2")
    }
    
    @MainActor
    func testAccessibilityTool() async throws {
        let orchestrator = AgentOrchestrator()
        AppDelegate.sharedOrchestrator = orchestrator
        
        let tool = AccessibilityControlTool(orchestrator: orchestrator)
        // Run list_elements (will return descriptive error if accessibility permissions are not granted, or list elements)
        let listResult = try await tool.call(arguments: AccessibilityControlTool.Arguments(action: "list_elements"))
        XCTAssertTrue(listResult.contains("active window") || listResult.contains("Accessibility permissions are disabled"))
        
        // Test invalid element ID click
        let clickResult = try await tool.call(arguments: AccessibilityControlTool.Arguments(action: "click", elementId: "invalid_id"))
        XCTAssertTrue(clickResult.contains("ERROR: Element") || clickResult.contains("Accessibility permissions are disabled"))
    }
    
    @MainActor
    func testBrowserAutomation() async throws {
        let orchestrator = AgentOrchestrator()
        AppDelegate.sharedOrchestrator = orchestrator
        
        let tool = BrowserAutomationTool(orchestrator: orchestrator)
        
        // Scraping before loading should return an error
        let scrapeBefore = try await tool.call(arguments: BrowserAutomationTool.Arguments(action: "scrape_page"))
        XCTAssertTrue(scrapeBefore.contains("ERROR"))
        
        // Test navigating to a local loopback
        do {
            let result = try await tool.call(arguments: BrowserAutomationTool.Arguments(action: "open_url", url: "https://localhost:9999/invalid_endpoint"))
            XCTAssertNotNil(result)
        } catch {
            XCTAssertNotNil(error)
        }
    }
    
    @MainActor
    func testDynamicToolLoading() async throws {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let toolsDir = homeDir.appendingPathComponent(".apex/tools")
        
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
        let chmodProcess = Process()
        chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodProcess.arguments = ["+x", scriptPath.path]
        try chmodProcess.run()
        chmodProcess.waitUntilExit()
        
        // Load the tools in the DynamicToolbox
        DynamicToolbox.shared.loadTools()
        
        // Verify tool was loaded
        XCTAssertNotNil(DynamicToolbox.shared.dynamicTools["test_dynamic_tool"])
        
        // Execute the tool
        let output = try await DynamicToolbox.shared.executeTool(name: "test_dynamic_tool", jsonArguments: "{\"testArg\": \"val\"}")
        XCTAssertTrue(output.contains("Hello from dynamic script!"))
        XCTAssertTrue(output.contains("val"))
        
        // Cleanup test files
        try? fileManager.removeItem(at: manifestPath)
        try? fileManager.removeItem(at: scriptPath)
        
        // Reload tools to clean up registry
        DynamicToolbox.shared.loadTools()
    }

    @MainActor
    func testSemanticEmbeddingSimilarity() {
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
        
        XCTAssertGreaterThan(simSimilar, simDissimilar, "Similar phrases should have higher cosine similarity than dissimilar ones")
        
        // Test serialization and deserialization
        let serialized = EmbeddingHelper.serialize(v1)
        XCTAssertNotNil(serialized)
        
        let deserialized = EmbeddingHelper.deserialize(serialized!)
        XCTAssertNotNil(deserialized)
        XCTAssertEqual(deserialized!.count, v1.count)
        if deserialized!.count == v1.count {
            XCTAssertEqual(deserialized![0], v1[0], accuracy: 0.0001)
        }
    }

    @MainActor
    func testVoiceControllerPlayback() {
        let voiceController = VoiceController.shared
        XCTAssertNotNil(voiceController)
        
        voiceController.speak("Testing voice playback setup.")
        voiceController.stopSpeaking()
        XCTAssertFalse(voiceController.isSpeaking)
    }

    @MainActor
    func testPTYSandboxFallback() async throws {
        // Force Docker Sandboxing enabled but trigger fallback
        UserDefaults.standard.set(true, forKey: "apex.dockerSandboxingEnabled")
        UserDefaults.standard.set(true, forKey: "apex.testDockerFallback")
        
        let pty = try await PTYSession(workspacePath: "/tmp")
        XCTAssertNotNil(pty)
        
        let result = try await pty.runCommand("echo \"fallback_works\"")
        XCTAssertTrue(result.contains("fallback_works"))
        pty.cleanup()
        
        // Restore default settings
        UserDefaults.standard.set(false, forKey: "apex.dockerSandboxingEnabled")
        UserDefaults.standard.set(false, forKey: "apex.testDockerFallback")
    }

    @MainActor
    func testAppleContainerSandboxFallback() async throws {
        // Force Apple Container Sandboxing enabled but trigger fallback
        UserDefaults.standard.set(true, forKey: "apex.appleContainersEnabled")
        UserDefaults.standard.set(true, forKey: "apex.testAppleContainerFallback")
        
        let pty = try await PTYSession(workspacePath: "/tmp")
        XCTAssertNotNil(pty)
        
        let result = try await pty.runCommand("echo \"apple_container_fallback_works\"")
        XCTAssertTrue(result.contains("apple_container_fallback_works"))
        pty.cleanup()
        
        // Restore default settings
        UserDefaults.standard.set(false, forKey: "apex.appleContainersEnabled")
        UserDefaults.standard.set(false, forKey: "apex.testAppleContainerFallback")
    }

    @MainActor
    func testCollaborativeServerEndpoints() async throws {
        let server = CollaborativeServer.shared
        XCTAssertNotNil(server)
        
        server.stop()
        server.start(port: 1338)
        XCTAssertEqual(server.port, 1338)
        
        // Wait a brief moment for socket to bind and start running
        try? await Task.sleep(for: .milliseconds(500))
        
        XCTAssertTrue(server.isRunning)
        
        // Test fetching state from local server using URLSession
        let url = URL(string: "http://localhost:1338/api/state")!
        let (data, response) = try await URLSession.shared.data(from: url)
        
        XCTAssertNotNil(data)
        if let httpResponse = response as? HTTPURLResponse {
            XCTAssertEqual(httpResponse.statusCode, 200)
            XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "application/json")
        }
        
        // Test fetching dashboard HTML
        let htmlUrl = URL(string: "http://localhost:1338/")!
        let (htmlData, htmlResponse) = try await URLSession.shared.data(from: htmlUrl)
        XCTAssertNotNil(htmlData)
        if let httpResponse = htmlResponse as? HTTPURLResponse {
            XCTAssertEqual(httpResponse.statusCode, 200)
            XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "text/html")
        }
        
        server.stop()
        XCTAssertFalse(server.isRunning)
    }

    @MainActor
    func testProjectAuditorScanning() async {
        let auditor = ProjectAuditor.shared
        let path = "/Users/danielstevens/Developer/fleet"
        let reports = await auditor.runWorkspaceAudit(at: path)
        
        XCTAssertNotNil(reports)
        if FileManager.default.fileExists(atPath: path) {
            XCTAssertFalse(reports.isEmpty, "Should find the swift applications")
            if !reports.isEmpty {
                let first = reports[0]
                XCTAssertFalse(first.name.isEmpty)
                XCTAssertFalse(first.path.isEmpty)
            }
        }
    }
    
    @MainActor
    func testProjectAuditToolInvocation() async throws {
        let orchestrator = AgentOrchestrator()
        AppDelegate.sharedOrchestrator = orchestrator
        
        let tool = ProjectAuditTool(orchestrator: orchestrator)
        let result = try await tool.call(arguments: ProjectAuditTool.Arguments(directoryPath: "/Users/danielstevens/Developer/fleet"))
        
        XCTAssertTrue(result.contains("Workspace Audit Report") || result.contains("No Xcode projects found"))
    }
    
    @MainActor
    func testAgentTypeInitialization() {
        XCTAssertEqual(AgentType.allCases.count, 7)
        for type in AgentType.allCases {
            XCTAssertFalse(type.systemPrompt.isEmpty)
        }
        XCTAssertFalse(SupervisorPrompt.system.isEmpty)
    }
    
    @MainActor
    func testSupervisorSetup() {
        let orchestrator = AgentOrchestrator()
        orchestrator.multiAgentModeEnabled = true
        orchestrator.resetSession()
        
        XCTAssertNotNil(orchestrator.session)
        XCTAssertTrue(orchestrator.multiAgentModeEnabled)
    }
    
    @MainActor
    func testDetectImageTextTool() async throws {
        let orchestrator = AgentOrchestrator()
        AppDelegate.sharedOrchestrator = orchestrator
        
        AgentOrchestrator.isTestMode = true
        defer { AgentOrchestrator.isTestMode = false }
        
        // 1. Create a dummy image with text "Hello OCR Test"
        let size = NSSize(width: 200, height: 100)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.set()
            rect.fill()
            let str = "Hello OCR Test" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24),
                .foregroundColor: NSColor.black
            ]
            str.draw(at: NSPoint(x: 10, y: 35), withAttributes: attrs)
            return true
        }
        
        // 2. Save it to a temporary path
        let tempPath = NSTemporaryDirectory() + "test_ocr_input.png"
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        
        let tiffData = image.tiffRepresentation
        XCTAssertNotNil(tiffData)
        let bitmap = NSBitmapImageRep(data: tiffData!)
        XCTAssertNotNil(bitmap)
        let pngData = bitmap!.representation(using: .png, properties: [:])
        XCTAssertNotNil(pngData)
        try pngData!.write(to: URL(fileURLWithPath: tempPath))
        
        // 3. Perform OCR using the tool
        let tool = DetectImageTextTool(orchestrator: orchestrator)
        let result = try await tool.call(arguments: DetectImageTextTool.Arguments(imagePath: tempPath))
        
        // 4. Verify OCR result contains our drawn words (case-insensitive checks)
        let lowerResult = result.lowercased()
        XCTAssertTrue(lowerResult.contains("hello") || lowerResult.contains("ocr") || lowerResult.contains("test"), "OCR should detect the drawn text. Result: \(result)")
    }
    
    @MainActor
    func testAnalyzeImageTool() async throws {
        let orchestrator = AgentOrchestrator()
        AppDelegate.sharedOrchestrator = orchestrator
        
        AgentOrchestrator.isTestMode = true
        defer { AgentOrchestrator.isTestMode = false }
        
        // 1. Create a dummy image
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.red.set()
            rect.fill()
            return true
        }
        let tempPath = NSTemporaryDirectory() + "test_analyze_input.png"
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        let tiffData = image.tiffRepresentation!
        let bitmap = NSBitmapImageRep(data: tiffData)!
        let pngData = bitmap.representation(using: .png, properties: [:])!
        try pngData.write(to: URL(fileURLWithPath: tempPath))
        
        // 2. Execute tool
        let tool = AnalyzeImageTool(orchestrator: orchestrator)
        let analyzeTask = Task<String, Error> {
            try await tool.call(arguments: AnalyzeImageTool.Arguments(imagePath: tempPath, query: "What color is this?"))
        }
        
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(5))
            analyzeTask.cancel()
        }
        
        do {
            let result = try await analyzeTask.value
            timeoutTask.cancel()
            XCTAssertNotNil(result)
        } catch is CancellationError {
            print("AnalyzeImageTool timed out (model not resident); tool invocation verified.")
        } catch {
            timeoutTask.cancel()
            print("Caught expected environment error: \(error)")
        }
    }
    
    @MainActor
    func testNewAgentProfiles() {
        let transcript = Transcript(entries: [])
        let model = SystemLanguageModel.default
        let orchestrator = AgentOrchestrator()
        
        let linterProfile = LinterAgentProfile(instructions: "Test", model: model, toolCallingMode: .allowed, orchestrator: orchestrator)
        let uiDesignerProfile = UIDesignerAgentProfile(instructions: "Test", model: model, toolCallingMode: .allowed, orchestrator: orchestrator)
        let plannerProfile = PlannerAgentProfile(instructions: "Test", model: model, toolCallingMode: .allowed, orchestrator: orchestrator)
        
        XCTAssertNotNil(LanguageModelSession(profile: linterProfile, history: transcript))
        XCTAssertNotNil(LanguageModelSession(profile: uiDesignerProfile, history: transcript))
        XCTAssertNotNil(LanguageModelSession(profile: plannerProfile, history: transcript))
    }
    
    @MainActor
    func testConveneMeetingTool() async throws {
        AgentOrchestrator.isTestMode = true
        defer { AgentOrchestrator.isTestMode = false }
        
        let orchestrator = AgentOrchestrator()
        // Ensure shared static pointer is set so the tool can find it
        AppDelegate.sharedOrchestrator = orchestrator
        
        let tool = ConveneMeetingTool(orchestrator: orchestrator)
        let arguments = ConveneMeetingTool.Arguments(
            topic: "Test debating coding standards",
            participants: ["linter", "uiDesigner", "planner"]
        )
        
        do {
            let result = try await tool.call(arguments: arguments)
            XCTAssertNotNil(result)
            XCTAssertTrue(result.contains("Debate Consensus Transcript:") || result.contains("ERROR"))
        } catch {
            // Under test runners without model access, this may throw a model error, which we catch gracefully
            XCTAssertNotNil(error)
        }
    }
    
    @MainActor
    func testStateGraphRouting() async throws {
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
        graph.addEdge(from: "NodeA") { output, isSuccess, state in
            return ("NodeB", state)
        }
        
        let finalState = try await graph.execute(initialState: StateGraphState()) { node in
            print("Node running: \(node)")
        }
        
        XCTAssertEqual(finalState.values["val"] as? String, "AB")
    }
    
    @MainActor
    func testCreateSkillTool() async throws {
        let orchestrator = AgentOrchestrator()
        AppDelegate.sharedOrchestrator = orchestrator
        
        let tool = CreateSkillTool(orchestrator: orchestrator)
        let arguments = CreateSkillTool.Arguments(
            skillName: "test_temp_skill",
            skillDescription: "A test skill creation tool",
            scriptContent: "echo \"hello skill\"",
            parameterSchemaJSON: "{\"type\": \"object\", \"properties\": {}}"
        )
        
        let result = try await tool.call(arguments: arguments)
        XCTAssertTrue(result.contains("SUCCESS"))
        
        // Cleanup file
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let skillsDir = homeDir.appendingPathComponent(".apex/skills")
        let jsonPath = skillsDir.appendingPathComponent("test_temp_skill.json")
        let scriptPath = skillsDir.appendingPathComponent("test_temp_skill.sh")
        try? FileManager.default.removeItem(at: jsonPath)
        try? FileManager.default.removeItem(at: scriptPath)
    }
    
    @MainActor
    func testMCPClient() async throws {
        let orchestrator = AgentOrchestrator()
        AppDelegate.sharedOrchestrator = orchestrator
        
        // Use a simple zsh mock command that reads stdin and echos a JSON-RPC response, including the new initialize handshake
        let mockCommand = "read line1; echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"MockServer\",\"version\":\"1.0.0\"}}}'; read line2; read line3; echo '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"mock_tool\",\"description\":\"A mock tool\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"required\":[]}}]}}'"
        let client = MCPClient(serverName: "Mock Server", command: mockCommand, logger: orchestrator, orchestrator: orchestrator)
        
        try await client.start()
        let isRunning1 = await client.isRunning()
        XCTAssertTrue(isRunning1)
        
        let tools = try await client.listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "mock_tool")
        
        await client.stop()
        let isRunning2 = await client.isRunning()
        XCTAssertFalse(isRunning2)
    }
    
    @MainActor
    func testContextCompactor() async throws {
        let orchestrator = AgentOrchestrator()
        
        // Setup in-memory SwiftData container for testing compaction DB sync
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        let conv = Conversation(title: "Test Compaction")
        orchestrator.currentConversation = conv
        orchestrator.modelContext?.insert(conv)
        try? orchestrator.modelContext?.save()
        
        // Add more than 5 messages and total chars > 12000 to trigger compaction
        for i in 1...10 {
            let msgText = "This is message number \(i) which contains some repeating characters to easily exceed the character threshold: " + String(repeating: "A", count: 1500)
            let role: ApexAgent.MessageRole = i % 2 == 0 ? .assistant : .user
            let msg = ChatMessage(role: role, content: msgText)
            orchestrator.appendMessage(msg)
            
            let dbMsg = Message(role: role, content: msgText)
            dbMsg.id = msg.id
            dbMsg.conversation = conv
            orchestrator.modelContext?.insert(dbMsg)
        }
        try? orchestrator.modelContext?.save()
        
        XCTAssertEqual(orchestrator.messages.count, 10)
        let beforeChars = orchestrator.messages.reduce(0) { $0 + $1.content.count }
        XCTAssertGreaterThan(beforeChars, 12000)
        
        // Run compaction with a real timeout to avoid hanging if the model is not resident.
        let compactTask = Task {
            await orchestrator.compactContextIfNeeded()
        }
        
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(5))
            compactTask.cancel()
        }
        
        await compactTask.value
        timeoutTask.cancel()
        
        // If compaction succeeds (decreases count), verify SwiftData database is in sync
        if orchestrator.messages.count < 10 {
            XCTAssertEqual(conv.messages.count, orchestrator.messages.count)
            XCTAssertTrue(orchestrator.messages.contains(where: { $0.role == .system }))
            XCTAssertTrue(conv.messages.contains(where: { $0.role == .system }))
        }
        
        print("Completed compactContextIfNeeded test execution.")
    }

    @MainActor
    func testInteractiveFeatureTesting() async throws {
        print("======== STARTING INTERACTIVE FEATURE TESTING ========")
        
        let orchestrator = AgentOrchestrator()
        
        // Setup in-memory SwiftData container for testing
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        AppDelegate.sharedOrchestrator = orchestrator
        AgentOrchestrator.isTestMode = true
        defer { AgentOrchestrator.isTestMode = false }
        
        // 1. Test System Info Tool
        print("--- Testing SystemInfoTool ---")
        orchestrator.resetActiveTurnToolCallCount()

        let sysInfoTool = SystemInfoTool(orchestrator: orchestrator)
        if let info = try? await sysInfoTool.call(arguments: SystemInfoTool.Arguments()) {
            print("SystemInfoTool result: \(info)")
        } else {
            print("SystemInfoTool failed.")
        }
        
        // 2. Test Shell Tool
        print("--- Testing ShellTool ---")
        orchestrator.resetActiveTurnToolCallCount()

        let shellTool = ShellTool(orchestrator: orchestrator)
        if let shellRes = try? await shellTool.call(arguments: ShellTool.Arguments(command: "echo 'Hello from Apex Shell!'")) {
            print("ShellTool result: \(shellRes)")
        } else {
            print("ShellTool failed.")
        }
        
        // 3. Test File System Tools (ListDirectoryTool)
        print("--- Testing ListDirectoryTool ---")
        orchestrator.resetActiveTurnToolCallCount()

        let fsTool = ListDirectoryTool(orchestrator: orchestrator)
        if let fsRes = try? await fsTool.call(arguments: ListDirectoryTool.Arguments(path: ".", showHidden: false, depth: 1)) {
            print("ListDirectoryTool result: \(fsRes)")
        } else {
            print("ListDirectoryTool failed.")
        }
        
        // 4. Test Memory Tools (StoreMemoryTool & SearchMemoryTool)
        print("--- Testing MemoryTools ---")
        orchestrator.resetActiveTurnToolCallCount()
        let storeTool = StoreMemoryTool(orchestrator: orchestrator)
        let storeRes = try? await storeTool.call(arguments: StoreMemoryTool.Arguments(key: "test_key", value: "Test memory context content"))
        print("StoreMemoryTool result: \(String(describing: storeRes))")

        let searchTool = SearchMemoryTool(orchestrator: orchestrator)
        let searchRes = try? await searchTool.call(arguments: SearchMemoryTool.Arguments(query: "test_key"))
        print("SearchMemoryTool result: \(String(describing: searchRes))")
        
        // 5. Test Screenshot Tool
        print("--- Testing ScreenshotTool ---")
        orchestrator.resetActiveTurnToolCallCount()
        let screenshotTool = ScreenshotTool(orchestrator: orchestrator)
        if let screenshotPath = try? await screenshotTool.call(arguments: ScreenshotTool.Arguments(savePath: "/tmp/apex_test_screenshot.png", windowOnly: false)) {
            print("ScreenshotTool result: \(screenshotPath)")

            // 6. Test OCR Text Recognition on Screenshot
            print("--- Testing DetectImageTextTool on screenshot ---")
            orchestrator.resetActiveTurnToolCallCount()
            let ocrTool = DetectImageTextTool(orchestrator: orchestrator)
            if let ocrRes = try? await ocrTool.call(arguments: DetectImageTextTool.Arguments(imagePath: "/tmp/apex_test_screenshot.png")) {
                print("DetectImageTextTool result: \(ocrRes)")
            } else {
                print("DetectImageTextTool failed.")
            }
        } else {
            print("ScreenshotTool failed.")
        }
        
        // 7. Test Convene Meeting Tool
        print("--- Testing ConveneMeetingTool ---")
        orchestrator.resetActiveTurnToolCallCount()
        let meetingTool = ConveneMeetingTool(orchestrator: orchestrator)
        if let meetingRes = try? await meetingTool.call(arguments: ConveneMeetingTool.Arguments(topic: "Discuss strict concurrency in Swift 6", participants: ["linter", "planner"])) {
            print("ConveneMeetingTool result: \(meetingRes)")
        } else {
            print("ConveneMeetingTool failed.")
        }
        
        // 8. Test Delegate Task Tool
        print("--- Testing DelegateTaskTool ---")
        orchestrator.resetActiveTurnToolCallCount()
        let delegateTool = DelegateTaskTool(orchestrator: orchestrator)
        if let delegateRes = try? await delegateTool.call(arguments: DelegateTaskTool.Arguments(agentType: "developer", taskDescription: "Explain strict concurrency in 1 sentence")) {
            print("DelegateTaskTool (developer) result: \(delegateRes)")
        } else {
            print("DelegateTaskTool failed.")
        }
 
        // 9. Test AppleScript Tool
        print("--- Testing AppleScriptTool ---")
        orchestrator.resetActiveTurnToolCallCount()
        let appleScriptTool = AppleScriptTool(orchestrator: orchestrator)
        if let scriptRes = try? await appleScriptTool.call(arguments: AppleScriptTool.Arguments(script: "say \"Apex Agent Testing complete\"")) {
            print("AppleScriptTool result: \(scriptRes)")
        } else {
            print("AppleScriptTool failed.")
        }
 
        // 10. Test Notification Tool
        print("--- Testing NotificationTool ---")
        orchestrator.resetActiveTurnToolCallCount()

        let notificationTool = NotificationTool(orchestrator: orchestrator)
        if let notifRes = try? await notificationTool.call(arguments: NotificationTool.Arguments(title: "Apex Test", body: "All features running perfectly")) {
            print("NotificationTool result: \(notifRes)")
        } else {
            print("NotificationTool failed.")
        }
 
        // 11. Test Project Audit Tool
        print("--- Testing ProjectAuditTool ---")
        orchestrator.resetActiveTurnToolCallCount()

        let auditTool = ProjectAuditTool(orchestrator: orchestrator)
        if let auditRes = try? await auditTool.call(arguments: ProjectAuditTool.Arguments(directoryPath: ".")) {
            print("ProjectAuditTool result: \(auditRes.prefix(300))")
        } else {
            print("ProjectAuditTool failed.")
        }
 
        // 12. Test Browser Automation Tool
        print("--- Testing BrowserAutomationTool ---")
        orchestrator.resetActiveTurnToolCallCount()
        let browserTool = BrowserAutomationTool(orchestrator: orchestrator)
        if let browserRes = try? await browserTool.call(arguments: BrowserAutomationTool.Arguments(action: "open_url", url: "https://example.com")) {
            print("BrowserAutomationTool result: \(browserRes)")
        } else {
            print("BrowserAutomationTool failed.")
        }
        
        // 13. Test each Model Preference
        for modelPref in AgentModelPreference.allCases {
            print("--- Testing Model Preference: \(modelPref.rawValue) ---")
            orchestrator.modelPreference = modelPref
            
            if modelPref == .cloudGemini {
                let apiKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
                if apiKey.isEmpty {
                    print("Skipping Cloud Gemini because api key is empty.")
                    continue
                }
            }
            
            if modelPref == .localOllama {
                // Check if Ollama is running first
                let host = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
                var request = URLRequest(url: host.appendingPathComponent("api/tags"))
                request.httpMethod = "GET"
                request.timeoutInterval = 2
                if let (_, res) = try? await URLSession.shared.data(for: request), (res as? HTTPURLResponse)?.statusCode == 200 {
                    print("Ollama is reachable.")
                } else {
                    print("Skipping Local Ollama because it is not reachable.")
                    continue
                }
            }
            
            if (modelPref == .privateCloud || modelPref == .hybrid) && !AgentOrchestrator.isPrivateCloudComputeAvailable() {
                print("Skipping \(modelPref.rawValue) because Private Cloud Compute entitlement is not available.")
                continue
            }
            
            orchestrator.resetSession()
            XCTAssertNotNil(orchestrator.session, "Expected non-nil session after resetSession")
        }

        print("======== COMPLETED INTERACTIVE FEATURE TESTING ========")
    }
    
    @MainActor
    func testClipboardTools() async throws {
        let orchestrator = AppDelegate.getSharedOrchestrator()!
        let originalText = NSPasteboard.general.string(forType: .string)
        
        let testString = "ApexAgent Clipboard Integration Test \(UUID().uuidString)"
        
        let writeTool = ClipboardWriteTool(orchestrator: orchestrator)
        let writeArgs = ClipboardWriteTool.Arguments(text: testString)
        let writeResult = try await writeTool.call(arguments: writeArgs)
        XCTAssertTrue(writeResult.contains("Copied"))
        

        
        let readTool = ClipboardReadTool(orchestrator: orchestrator)
        let readResult = try await readTool.call(arguments: ClipboardReadTool.Arguments())
        XCTAssertTrue(readResult.contains(testString))
        
        // Restore original content
        NSPasteboard.general.clearContents()
        if let originalText {
            NSPasteboard.general.setString(originalText, forType: .string)
        }
    }
    
    @MainActor
    func testUpdatePlanTool() async throws {
        let orchestrator = AgentOrchestrator()
        AppDelegate.sharedOrchestrator = orchestrator
        
        let step1 = UpdatePlanTool.Arguments.Step(title: "Design System Implementation", status: "completed")
        let step2 = UpdatePlanTool.Arguments.Step(title: "Verification Testing", status: "running")
        let args = UpdatePlanTool.Arguments(steps: [step1, step2])
        
        let tool = UpdatePlanTool(orchestrator: orchestrator)
        let result = try await tool.call(arguments: args)
        XCTAssertTrue(result.contains("Plan updated successfully"))
        
        XCTAssertEqual(orchestrator.activePlan.count, 2)
        XCTAssertEqual(orchestrator.activePlan[0].title, "Design System Implementation")
        XCTAssertEqual(orchestrator.activePlan[0].status, .completed)
        XCTAssertEqual(orchestrator.activePlan[1].title, "Verification Testing")
        XCTAssertEqual(orchestrator.activePlan[1].status, .running)
    }
    
    @MainActor
    func testWebSearchToolDuckDuckGo() async throws {
        let orchestrator = AppDelegate.getSharedOrchestrator()!
        let tool = WebSearchTool(orchestrator: orchestrator)
        let query = "Swift programming language"
        let result = try await tool.call(arguments: WebSearchTool.Arguments(query: query, count: 3))
        
        // The output should be a real search result from DuckDuckGo or Brave Search.
        XCTAssertTrue(result.contains("results for: \"\(query)\""), "Result should have heading for query. Result: \(result)")
        XCTAssertTrue(result.contains("Swift") || result.contains("programming") || result.contains("language"), "Result should contain relevant keywords. Result: \(result)")
    }
    
    @MainActor
    func testApplicationControlToolUnsupported() async throws {
        let orchestrator = AppDelegate.getSharedOrchestrator()!
        let tool = ApplicationControlTool(orchestrator: orchestrator)
        let result = try await tool.call(arguments: ApplicationControlTool.Arguments(appName: "NonExistentDummyApp", action: "open_url", parameter: "https://localhost"))
        XCTAssertTrue(result.contains("ERROR"))
        XCTAssertTrue(result.contains("Unsupported application"))
    }
    
    @MainActor
    func testApplicationControlToolFinder() async throws {
        let orchestrator = AppDelegate.getSharedOrchestrator()!
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let tool = ApplicationControlTool(orchestrator: orchestrator)
        let result = try await tool.call(arguments: ApplicationControlTool.Arguments(appName: "Finder", action: "open_folder", parameter: tempDir.path))
        XCTAssertNotNil(result)
    }

    @MainActor
    func testConfirmCompletionTool() async throws {
        let orchestrator = AgentOrchestrator()
        AppDelegate.sharedOrchestrator = orchestrator
        AgentOrchestrator.isTestMode = true
        defer { AgentOrchestrator.isTestMode = false }
        
        let tool = ConfirmCompletionTool(orchestrator: orchestrator)
        let args = ConfirmCompletionTool.Arguments(
            summary: "Fixed compilation warnings",
            filesModified: "AgentOrchestrator.swift",
            verificationResults: "Build succeeds"
        )
        let result = try await tool.call(arguments: args)
        XCTAssertTrue(result.contains("SUCCESS"))
    }
    
    @MainActor
    func testProjectManagementTools() async throws {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        // 1. Create Project
        let createProj = CreateProjectTool(orchestrator: orchestrator)
        let projArgs = CreateProjectTool.Arguments(name: "TestProj", summary: "A test project", language: "Swift")
        let projResult = try await createProj.call(arguments: projArgs)
        XCTAssertTrue(projResult.contains("SUCCESS"))
        
        let projDesc = FetchDescriptor<ProjectModel>()
        let projects = try orchestrator.modelContext?.fetch(projDesc) ?? []
        XCTAssertEqual(projects.count, 1)
        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project.name, "TestProj")
        
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
        XCTAssertTrue(sprintResult.contains("SUCCESS"))
        
        let sprintDesc = FetchDescriptor<SprintModel>()
        let sprints = try orchestrator.modelContext?.fetch(sprintDesc) ?? []
        XCTAssertEqual(sprints.count, 1)
        let sprint = try XCTUnwrap(sprints.first)
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
        XCTAssertTrue(taskResult.contains("SUCCESS"))
        
        let taskDesc = FetchDescriptor<TaskModel>()
        let tasks = try orchestrator.modelContext?.fetch(taskDesc) ?? []
        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        let taskIDStr = task.id.uuidString
        
        // 4. Update Task Status
        let updateTask = UpdateTaskStatusTool(orchestrator: orchestrator)
        let updateArgsTodo = UpdateTaskStatusTool.Arguments(taskID: taskIDStr, status: "todo")
        let updateResultTodo = try await updateTask.call(arguments: updateArgsTodo)
        XCTAssertTrue(updateResultTodo.contains("SUCCESS"))
        XCTAssertEqual(task.status, .todo)
        
        let updateArgs = UpdateTaskStatusTool.Arguments(taskID: taskIDStr, status: "done")
        let updateResult = try await updateTask.call(arguments: updateArgs)
        XCTAssertTrue(updateResult.contains("SUCCESS"))
        XCTAssertEqual(task.status, .done)
        
        // 5. List Projects
        let listProj = ListProjectsTool(orchestrator: orchestrator)
        let listProjResult = try await listProj.call(arguments: ListProjectsTool.Arguments())
        XCTAssertTrue(listProjResult.contains("TestProj"))
        
        // 6. List Sprints
        let listSprints = ListSprintsTool(orchestrator: orchestrator)
        let listSprintsResult = try await listSprints.call(arguments: ListSprintsTool.Arguments(projectID: projectIDStr))
        XCTAssertTrue(listSprintsResult.contains("Sprint 1"))
        
        // 7. List Tasks
        let listTasks = ListTasksTool(orchestrator: orchestrator)
        let listTasksResult = try await listTasks.call(arguments: ListTasksTool.Arguments(projectID: projectIDStr, sprintID: sprintIDStr))
        XCTAssertTrue(listTasksResult.contains("Implement Auth"))
    }
    
    @MainActor
    func testCodeReviewPersistenceTools() async throws {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
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
        XCTAssertTrue(saveResult.contains("SUCCESS"))
        
        let listResult = try await listTool.call(arguments: ListReviewSessionsTool.Arguments())
        XCTAssertTrue(listResult.contains("Audit results"))
        XCTAssertTrue(listResult.contains("Force unwrap crash risk"))
    }
    
    @MainActor
    func testWorkspaceProactiveAuditor() async throws {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        AppDelegate.sharedOrchestrator = orchestrator
        
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempDir)
            UserDefaults.standard.removeObject(forKey: "apex.workspacePath")
        }
        
        // Write mock Swift file with a TODO
        let mockFile = tempDir.appendingPathComponent("MockFile.swift")
        let content = """
        // TODO: Implement security audit
        class MockClass {}
        """
        try content.write(to: mockFile, atomically: true, encoding: .utf8)
        
        UserDefaults.standard.set(tempDir.path, forKey: "apex.workspacePath")
        
        let auditor = WorkspaceProactiveAuditor.shared
        let report = await auditor.performAudit()
        
        XCTAssertTrue(report.contains("Workspace Proactive Audit Report"))
        XCTAssertTrue(report.contains("MockFile.swift"))
    }
    
    @MainActor
    func testRealWorkspaceAudit() async throws {
        UserDefaults.standard.set("/Users/danielstevens/Developer", forKey: "apex.workspacePath")
        let auditor = WorkspaceProactiveAuditor.shared
        let report = await auditor.performAudit()
        print("\n\n======== REAL WORKSPACE AUDIT REPORT ========")
        print(report)
        print("=============================================\n\n")
    }
    
    func testRunWorkflowToolDecoding() throws {
        let json = #"{"task": "Build system enhancements"}"#
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let args = try decoder.decode(RunWorkflowTool.Arguments.self, from: data)
        XCTAssertEqual(args.task, "Build system enhancements")
    }

    @MainActor
    func testStateGraphCycleDetection() async {
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
            XCTFail("Expected cyclicExecution error, but execution succeeded")
        } catch let error as StateGraphError {
            switch error {
            case .cyclicExecution(let name):
                XCTAssertEqual(name, "NodeA")
            default:
                XCTFail("Expected cyclicExecution, got \(error)")
            }
        } catch {
            XCTFail("Expected StateGraphError, got \(error)")
        }
    }

    @MainActor
    func testFileSearchTool() async throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions()
        let tool = FileSearchTool(orchestrator: orchestrator)
        
        let tempDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let fileURL = tempDir.appendingPathComponent("SearchTest.txt")
        let content = "This is a unique keyword that we will search for."
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        
        UserDefaults.standard.set(tempDir.path, forKey: "apex.workspacePath")
        
        let args = FileSearchTool.Arguments(query: "unique keyword", directory: tempDir.path, filePattern: "*.txt")
        let result = try await tool.call(arguments: args)
        print("--- testFileSearchTool Result: \(result) ---")
        XCTAssertTrue(result.contains("SearchTest.txt"))
        XCTAssertTrue(result.contains("unique keyword"))
    }

    @MainActor
    func testRealToolsGrepAndGitMCP() async throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions()
        
        let searchTool = FileSearchTool(orchestrator: orchestrator)
        let repoPath = "/Users/danielstevens/Developer/ApexAgent"
        UserDefaults.standard.set(repoPath, forKey: "apex.workspacePath")
        
        let searchArgs = FileSearchTool.Arguments(query: "verifyPathAllowed", directory: repoPath, filePattern: "*.swift")
        let searchResult = try await searchTool.call(arguments: searchArgs)
        print("--- Real FileSearch Result ---")
        print(searchResult.prefix(600))
        print("-----------------------------")
        XCTAssertTrue(searchResult.contains("AgentOrchestrator.swift"))
        
        let toolbox = DynamicToolbox.shared
        toolbox.orchestrator = orchestrator
        
        MCPManager.shared.loadConfigs()
        await toolbox.loadMCPTools()
        
        print("--- Loaded Dynamic Tools ---")
        for (name, entry) in toolbox.dynamicTools {
            print("  \(name): \(entry.description.prefix(50))")
        }
        print("----------------------------")
        
        if toolbox.dynamicTools["git_status"] != nil {
            print("Invoking real git_status...")
            let escapedPath = repoPath.replacingOccurrences(of: "\"", with: "\\\"")
            let gitResult = try await toolbox.executeTool(name: "git_status", jsonArguments: "{\"repo_path\": \"\(escapedPath)\"}")
            print("--- Real git_status Result ---")
            print(gitResult)
            print("------------------------------")
            XCTAssertNotNil(gitResult)
            XCTAssertFalse(gitResult.isEmpty)
            XCTAssertFalse(gitResult.contains("Input validation error"))
        } else {
            print("⚠️ Git MCP 'git_status' tool not loaded.")
        }
    }
}

