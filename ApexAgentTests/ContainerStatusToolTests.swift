import Testing
import Foundation
@testable import ApexAgentCore

// Test implementation of ContainerManagerProtocol for testing ContainerStatusTool
@MainActor
final class TestContainerManager: ContainerManagerProtocol, @unchecked Sendable {
    var stateDescription: String = "Stopped"
    var containerCPUs: Int = 4
    var containerMemoryMB: Int = 8192
    var appleContainerImage: String = "ghcr.io/apple/darwin-container:latest"

    var startCalled: Bool = false
    var stopCalled: Bool = false
    var shouldFailStart: Bool = false

    func startContainer() async throws {
        if shouldFailStart {
            throw NSError(domain: "TestContainerManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Boot failed"])
        }
        startCalled = true
        stateDescription = "Running"
    }

    func stopContainer() async throws {
        stopCalled = true
        stateDescription = "Stopped"
    }

    func startInteractiveShell(
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> any ContainerInteractiveSession {
        fatalError("Interactive shell not needed for status tool testing")
    }

    func exec(_ command: String) async throws -> (output: String, exitCode: Int32) {
        return ("executed", 0)
    }
}

@Suite("Batch 3: ContainerStatusTool Tests", .serialized)
struct ContainerStatusToolTests {

    @Test("ContainerStatusTool metadata check")
    @MainActor
    func testContainerStatusToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = ContainerStatusTool(orchestrator: orchestrator)
        #expect(tool.name == "manage_sandbox")
        #expect(tool.description.contains("native macOS Apple Container sandbox"))
    }

    @Test("status action returns formatted markdown table with configuration details")
    @MainActor
    func testStatusAction() async throws {
        let originalBridge = ContainerBridge.shared
        defer { ContainerBridge.shared = originalBridge }

        let testManager = TestContainerManager()
        ContainerBridge.shared = testManager

        let orchestrator = AgentOrchestrator()
        let tool = ContainerStatusTool(orchestrator: orchestrator)

        let args = ContainerStatusTool.Arguments(action: "status")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("### Apple Container Sandbox Configuration"))
        #expect(result.contains("| State | `Stopped` |"))
        #expect(result.contains("| Allocated CPUs | `4` |"))
        #expect(result.contains("| Allocated Memory | `8192 MB` |"))
        #expect(result.contains("| Container Image | `ghcr.io/apple/darwin-container:latest` |"))
    }

    @Test("start action invokes startContainer and reports success")
    @MainActor
    func testStartActionSuccess() async throws {
        let originalBridge = ContainerBridge.shared
        defer { ContainerBridge.shared = originalBridge }

        let testManager = TestContainerManager()
        ContainerBridge.shared = testManager

        let orchestrator = AgentOrchestrator()
        let tool = ContainerStatusTool(orchestrator: orchestrator)

        let args = ContainerStatusTool.Arguments(action: "start")
        let result = try await tool.call(arguments: args)

        #expect(testManager.startCalled)
        #expect(result.contains("SUCCESS: Apple Container sandbox started successfully"))
        #expect(result.contains("Status: Running"))
    }

    @Test("start action reports formatted error if startContainer throws")
    @MainActor
    func testStartActionFailure() async throws {
        let originalBridge = ContainerBridge.shared
        defer { ContainerBridge.shared = originalBridge }

        let testManager = TestContainerManager()
        testManager.shouldFailStart = true
        ContainerBridge.shared = testManager

        let orchestrator = AgentOrchestrator()
        let tool = ContainerStatusTool(orchestrator: orchestrator)

        let args = ContainerStatusTool.Arguments(action: "start")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("ERROR: Failed to start sandbox container: Boot failed"))
    }

    @Test("stop action invokes stopContainer and reports success")
    @MainActor
    func testStopActionSuccess() async throws {
        let originalBridge = ContainerBridge.shared
        defer { ContainerBridge.shared = originalBridge }

        let testManager = TestContainerManager()
        testManager.stateDescription = "Running"
        ContainerBridge.shared = testManager

        let orchestrator = AgentOrchestrator()
        let tool = ContainerStatusTool(orchestrator: orchestrator)

        let args = ContainerStatusTool.Arguments(action: "stop")
        let result = try await tool.call(arguments: args)

        #expect(testManager.stopCalled)
        #expect(result.contains("SUCCESS: Apple Container sandbox stopped successfully"))
        #expect(result.contains("Status: Stopped"))
    }

    @Test("Unknown action returns formatted error message")
    @MainActor
    func testUnknownAction() async throws {
        let originalBridge = ContainerBridge.shared
        defer { ContainerBridge.shared = originalBridge }

        let testManager = TestContainerManager()
        ContainerBridge.shared = testManager

        let orchestrator = AgentOrchestrator()
        let tool = ContainerStatusTool(orchestrator: orchestrator)

        let args = ContainerStatusTool.Arguments(action: "invalid_action_xyz")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("ERROR: Unknown action 'invalid_action_xyz'"))
    }

    @Test("Returns error when ContainerBridge.shared is nil")
    @MainActor
    func testNilContainerBridge() async throws {
        let originalBridge = ContainerBridge.shared
        defer { ContainerBridge.shared = originalBridge }

        ContainerBridge.shared = nil

        let orchestrator = AgentOrchestrator()
        let tool = ContainerStatusTool(orchestrator: orchestrator)

        let args = ContainerStatusTool.Arguments(action: "status")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("ERROR: Sandbox is not supported in this target."))
    }
}
