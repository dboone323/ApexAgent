import Testing
import Foundation
import SwiftUI
import AppKit
@testable import ApexAgentCore

// MARK: - MCPServerDashboardTests Suite

@MainActor
@Suite("MCPServerDashboardTests", .serialized)
struct MCPServerDashboardTests {

    /// Zero-mock policy: resolve the REAL filesystem MCP server installed on
    /// this machine. Returns nil when the toolchain is unavailable — callers
    /// then report "no MCP found".
    private func liveServer() -> (workspace: URL, command: String, arguments: [String])? {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live_mcp_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let server = LiveMCP.filesystemServer(root: root.path) else {
            return nil
        }
        return (root, server.command, server.arguments)
    }

    // MARK: - 1. Health Checks & Lifecycle Probing

    @Test func testMCPClientHealthInitialState() async {
        let orchestrator = AgentOrchestrator()
        let client = MCPClient(
            serverName: "TestServer",
            command: "/bin/echo",
            arguments: [],
            logger: orchestrator,
            orchestrator: orchestrator
        )

        let health = await client.health()
        #expect(health.serverName == "TestServer")
        #expect(health.isRunning == false)
        #expect(health.circuitOpen == false)
        #expect(health.failureCount == 0)
        #expect(health.restartCountInWindow == 0)
    }

    @Test func testMCPClientHealthWithActiveProcess() async throws {
        guard let live = liveServer() else {
            Issue.record("no MCP found: @modelcontextprotocol/server-filesystem unavailable via npx")
            return
        }
        defer { try? FileManager.default.removeItem(at: live.workspace) }
        let orchestrator = AgentOrchestrator()
        let config = MCPClientConfig(
            requestTimeout: 20,
            pingTimeout: 10,
            maxRetries: 2,
            circuitFailureThreshold: 3,
            restartRateLimitWindow: 60,
            maxRestartsInWindow: 3
        )

        let client = MCPClient(
            serverName: "LiveFilesystemServer",
            command: live.command,
            arguments: live.arguments,
            logger: orchestrator,
            orchestrator: orchestrator,
            config: config
        )

        try await client.start()
        let isHealthy = await client.ping()
        #expect(isHealthy, "Live MCP server should respond healthy to ping")

        let health = await client.health()
        #expect(health.serverName == "LiveFilesystemServer")
        #expect(health.isRunning == true)
        #expect(health.circuitOpen == false)
        #expect(health.failureCount == 0)

        await client.stop()
        let stoppedHealth = await client.health()
        #expect(stoppedHealth.isRunning == false)
    }

    @Test func testMCPClientCircuitBreakerTripAndReset() async {
        let orchestrator = AgentOrchestrator()
        let client = MCPClient(
            serverName: "CircuitTestServer",
            command: "/bin/echo",
            arguments: [],
            logger: orchestrator,
            orchestrator: orchestrator
        )

        #expect(!(await client.isCircuitOpen()))

        // Manually trip circuit breaker
        await client.openCircuit()
        #expect(await client.isCircuitOpen())
        let healthOpen = await client.health()
        #expect(healthOpen.circuitOpen == true)

        // Reset circuit breaker
        await client.resetCircuit()
        #expect(!(await client.isCircuitOpen()))
        let healthReset = await client.health()
        #expect(healthReset.circuitOpen == false)
        #expect(healthReset.failureCount == 0)
    }

    // MARK: - 2. Roundtrip Latency Probing

    @Test func testMCPClientMeasureLatencySuccess() async throws {
        guard let live = liveServer() else {
            Issue.record("no MCP found: @modelcontextprotocol/server-filesystem unavailable via npx")
            return
        }
        defer { try? FileManager.default.removeItem(at: live.workspace) }
        let orchestrator = AgentOrchestrator()
        let config = MCPClientConfig(
            requestTimeout: 5,
            pingTimeout: 3,
            maxRetries: 2,
            circuitFailureThreshold: 3,
            restartRateLimitWindow: 60,
            maxRestartsInWindow: 3
        )

        let client = MCPClient(
            serverName: "LatencyProbeServer",
            command: live.command,
            arguments: live.arguments,
            logger: orchestrator,
            orchestrator: orchestrator,
            config: config
        )

        // Probing latency on a live server
        let latencyMs = await client.measureLatency()
        #expect(latencyMs != nil, "Latency measurement should succeed for responsive MCP server")

        if let latency = latencyMs {
            #expect(latency > 0.0, "Latency in milliseconds must be strictly positive")
            #expect(latency < 5000.0, "Local MCP server latency should be under 5 seconds")
        }

        await client.stop()
    }

    @Test func testMCPClientMeasureLatencyFailsOnUnreachableServer() async {
        let orchestrator = AgentOrchestrator()
        let config = MCPClientConfig(
            requestTimeout: 1,
            pingTimeout: 1,
            maxRetries: 0,
            circuitFailureThreshold: 1,
            restartRateLimitWindow: 60,
            maxRestartsInWindow: 1
        )

        // Point to non-responsive / non-existent command
        let client = MCPClient(
            serverName: "UnreachableServer",
            command: "/usr/bin/nonexistent_binary_apex_unreachable",
            arguments: [],
            logger: orchestrator,
            orchestrator: orchestrator,
            config: config
        )

        let latency = await client.measureLatency()
        #expect(latency == nil, "Latency measurement must return nil when server is unreachable or fails to start")

        await client.stop()
    }

    // MARK: - 3. Tool Catalog Discovery & Calling

    @Test func testMCPClientToolCatalogDiscovery() async throws {
        guard let live = liveServer() else {
            Issue.record("no MCP found: @modelcontextprotocol/server-filesystem unavailable via npx")
            return
        }
        defer { try? FileManager.default.removeItem(at: live.workspace) }
        let orchestrator = AgentOrchestrator()
        let client = MCPClient(
            serverName: "ToolCatalogServer",
            command: live.command,
            arguments: live.arguments,
            logger: orchestrator,
            orchestrator: orchestrator
        )

        let tools = try await client.listRegisteredTools()
        #expect(!tools.isEmpty, "Tool catalog should discover registered tools")

        let readFile = try #require(tools.first { $0.name == "read_file" })
        #expect(!(readFile.description?.isEmpty ?? true))
        #expect(readFile.inputSchema.type == "object")

        await client.stop()
    }

    // MARK: - 4. Dynamic Script Editor Execution

    @Test func testDynamicScriptEditorTestRunSuccess() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptFile = tempDir.appendingPathComponent("custom_calculator.sh")
        let scriptContent = """
        #!/bin/zsh
        # Dynamic tool script test
        input_args="$APEX_ARGS"
        echo "SCRIPT_OUTPUT: Successfully processed $input_args"
        exit 0
        """
        try scriptContent.write(to: scriptFile, atomically: true, encoding: .utf8)
        chmod(scriptFile.path, 0o755)

        let jsonPayload = "{\"operation\":\"add\",\"a\":10,\"b\":20}"
        let result = try await executeDynamicScript(
            scriptPath: scriptFile.path,
            jsonArguments: jsonPayload
        )

        #expect(result.exitCode == 0, "Script should exit with code 0 on success")
        #expect(result.stdout.contains("SCRIPT_OUTPUT: Successfully processed \(jsonPayload)"))
        #expect(result.stderr.isEmpty, "Stderr should be empty on successful run")
        #expect(result.duration >= 0.0, "Execution duration should be positive")
    }

    @Test func testDynamicScriptEditorTestRunErrorCapture() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp_test_err_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptFile = tempDir.appendingPathComponent("failing_tool.sh")
        let scriptContent = """
        #!/bin/zsh
        echo "Fatal: Invalid configuration parameters" >&2
        exit 42
        """
        try scriptContent.write(to: scriptFile, atomically: true, encoding: .utf8)
        chmod(scriptFile.path, 0o755)

        let result = try await executeDynamicScript(
            scriptPath: scriptFile.path,
            jsonArguments: "{}"
        )

        #expect(result.exitCode == 42, "Script should return exit code 42")
        #expect(result.stderr.contains("Fatal: Invalid configuration parameters"), "Stderr should capture error output")
    }

    @MainActor
    @Test func testDynamicToolboxToolRegistrationAndExecution() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("toolbox_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptFile = tempDir.appendingPathComponent("echo_tool.sh")
        let scriptContent = """
        #!/bin/zsh
        echo "DYNAMIC_TOOL_EXEC_OK: $APEX_ARGS"
        exit 0
        """
        try scriptContent.write(to: scriptFile, atomically: true, encoding: .utf8)
        chmod(scriptFile.path, 0o755)

        let toolbox = DynamicToolbox.shared
        let toolEntry = DynamicToolbox.DynamicToolEntry(
            name: "unit_test_echo",
            description: "Echoes test input",
            scriptPath: scriptFile.path,
            schema: ["name": "unit_test_echo", "parameters": ["type": "object"]],
            mcpServerId: nil
        )

        toolbox.registerToolForTesting(name: "unit_test_echo", entry: toolEntry)
        defer { toolbox.removeToolForTesting(name: "unit_test_echo") }

        let testArgs = "{\"message\":\"hello_world\"}"
        let output = try await toolbox.executeTool(name: "unit_test_echo", jsonArguments: testArgs)
        #expect(output.contains("DYNAMIC_TOOL_EXEC_OK: {\"message\":\"hello_world\"}"))
    }

    // MARK: - 5. Transport Configuration & Server Management

    @Test func testMCPServerConfigTransportRepresentation() {
        let stdioConfig = MCPServerConfig(
            name: "StdioServer",
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem"],
            transport: "stdio",
            endpointURL: nil
        )
        #expect(stdioConfig.transport == "stdio")
        #expect(stdioConfig.command == "npx")
        #expect(stdioConfig.arguments.count == 2)

        let sseConfig = MCPServerConfig(
            name: "RemoteSSE",
            command: "http://localhost:8080/sse",
            arguments: [],
            transport: "sse",
            endpointURL: "http://localhost:8080/sse"
        )
        #expect(sseConfig.transport == "sse")
        #expect(sseConfig.endpointURL == "http://localhost:8080/sse")
    }

    @Test func testMCPManagerRestartServer() async throws {
        guard let live = liveServer() else {
            Issue.record("no MCP found: @modelcontextprotocol/server-filesystem unavailable via npx")
            return
        }
        defer { try? FileManager.default.removeItem(at: live.workspace) }
        let config = MCPServerConfig(
            name: "RestartableServer",
            command: live.command,
            arguments: live.arguments
        )
        let manager = MCPManager.shared
        manager.addServer(config)
        defer { manager.removeServer(id: config.id) }

        let client = manager.getClient(for: config)
        try await client.start()
        #expect(await client.isRunning())

        // Restart server
        try await manager.restartServer(id: config.id)
        let restartedClient = manager.getClient(for: config)
        #expect(await restartedClient.isRunning())
    }

    // MARK: - 6. SwiftUI View Hosting Tests

    @Test func testMCPServerDashboardViewHosting() {
        ViewHost.host(MCPServerDashboardView(), pump: 0.1)
    }

    @Test func testDynamicScriptEditorViewHosting() {
        ViewHost.host(DynamicScriptEditorView(), pump: 0.1)
    }

    @Test func testDynamicToolboxManagerSectionHosting() {
        ViewHost.host(DynamicToolboxManagerSection(), pump: 0.1)
    }
}
