import Testing
import Foundation
import SwiftData
@testable import ApexAgentCore
import SharedModels

@Suite("BackendServiceTests") class BackendServiceTests {
    @MainActor
    @Test func testAgentOrchestratorDatabaseAndCompaction() async throws {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        let conv = Conversation(title: "Save Test")
        orchestrator.currentConversation = conv
        orchestrator.modelContext?.insert(conv)
        
        // Add messages to verify DB saves and context properties
        let msg1 = ChatMessage(role: .user, content: "Test message")
        orchestrator.appendMessage(msg1)
        
        let dbMsg = Message(role: .user, content: "Test message")
        dbMsg.id = msg1.id
        dbMsg.conversation = conv
        orchestrator.modelContext?.insert(dbMsg)
        
        try? orchestrator.modelContext?.save()
        #expect(conv.messages.count == 1)
    }
    
    @Test func testWorkspaceProactiveAuditorScanning() async throws {
        let auditor = WorkspaceProactiveAuditor.shared
        let report = await auditor.performAudit()
        
        #expect(report.contains("Workspace Proactive Audit Report"))
        #expect(report.contains("Pending Tasks") || report.contains("healthy") || report.contains("Test Coverage Gaps"))
    }
    
    @Test func testPTYSessionInteractiveCommands() async throws {
        // Pin the sandbox flags: this test asserts plain PTY behavior, so it
        // must not inherit docker/Apple-container settings left in the
        // swiftpm-testing-helper defaults domain by an earlier run.
        let sandboxKeys = [
            "apex.dockerSandboxingEnabled",
            "apex.testDockerFallback",
            "apex.appleContainersEnabled",
            "apex.testAppleContainerFallback",
        ]
        for key in sandboxKeys { UserDefaults.standard.removeObject(forKey: key) }

        // Spawn a real, functioning interactive shell session and execute a command
        // Hermetic (AUDIT_2026-09-28 §3.3.12): derive repo root from #filePath.
        let workspacePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ApexAgentTests/
            .deletingLastPathComponent()   // repository root
            .path
        let pty = try await PTYSession(workspacePath: workspacePath)
        _ = pty // non-optional: init succeeded or threw
        
        do {
            let output = try await pty.runCommand("echo 'Hello PTY Session'")
            #expect(output.contains("Hello PTY Session"))
        } catch {
            Issue.record("PTY failed to execute echo command: \(error)")
        }
        
        pty.cleanup()
    }
    
    @MainActor
    @Test func testCollaborativeServerAndGatewayConnection() async throws {
        let server = CollaborativeServer()
        
        // Use a test port to avoid conflict with active servers
        let testPort: UInt16 = 29999
        server.start(port: testPort)
        
        // Pre-warm client connection and attempt connecting
        let client = ApexGatewayClient()
        client.connect(host: "localhost", port: testPort)
        
        // Clean up connections
        client.disconnect()
        server.stop()
    }
    
    @MainActor
    @Test func testVoiceAndScreenStreamerPreflight() async {
        let voice = VoiceController.shared
        _ = voice // shared singleton
        
        let streamer = ScreenStreamer.shared
        _ = streamer // shared singleton
        #expect(streamer.getLatestFrame() == nil)
    }
    
    @MainActor
    @Test func testRealDaemonCommunication() async throws {
        
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        let testPort: UInt16 = 28888
        let server = ApexGatewayServer(port: testPort, orchestrator: orchestrator)
        try server.start()
        defer { server.stop() }
        
        let client = ApexGatewayClient()
        client.disconnect()
        client.connect(host: "127.0.0.1", port: testPort)
        defer { client.disconnect() }
        
        // Wait for client to connect
        var isConnected = false
        for _ in 1...20 {
            if client.isConnected {
                isConnected = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        
        #expect(isConnected, "Gateway client failed to connect to daemon server")
        
        // Ensure handshake finishes
        try? await Task.sleep(for: .milliseconds(200))
        
        // Send a live prompt message from client
        client.sendMessage("Echo Test Live", attachments: [])
        
        // Wait for server to receive and orchestrator to start generating/storing
        var messageReceived = false
        for _ in 1...60 {
            if client.isGenerating || 
               orchestrator.isGenerating || 
               orchestrator.messages.contains(where: { $0.content.contains("Echo Test Live") }) {
                messageReceived = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        
        #expect(messageReceived, "Failed to transmit message over TCP gateway")
    }
}
