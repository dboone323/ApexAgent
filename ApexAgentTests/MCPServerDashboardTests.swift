import Testing
import Foundation
import SwiftUI
import AppKit
import Darwin
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

    // MARK: - 7. Process Tree Cleanup on stop() (audit H5)

    /// Reproduces audit H5: an MCP server that spawns a child worker subprocess
    /// (e.g. the node child that `npx @modelcontextprotocol/server-filesystem`
    /// launches). `stop()` must tear down the whole process group so the child
    /// is not orphaned after shutdown.
    ///
    /// We drive MCPClient against a hand-written JSON-RPC/stdio server
    /// (no network/npx dependency) that: prints a readiness banner, spawns a
    /// long-lived `sleep` child worker, completes the `initialize` handshake,
    /// then idles so the child outlives the handshake. Before stop() the child
    /// must be alive; after stop() it must be dead — proving killpg(2) reached
    /// the entire tree rather than just the main server pid.
    @Test func testMCPClientStopKillsChildWorkerProcessTree() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp_pgreep_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pidfilePath = tmp.appendingPathComponent("child.pid").path

        // Minimal JSON-RPC stdio server. `$child` and the id are literal shell;
        // only the pidfile path is interpolated (POSIX-safe temp path, no spaces).
        let serverScript = tmp.appendingPathComponent("server.sh")
        let scriptContent = """
#!/bin/zsh
# Readiness banner — MCPClient waits for this before sending `initialize`.
printf 'running on stdio\n' >&2
# Spawn a long-lived child worker that must be reaped by stop()'s process-group kill.
sleep 300 &
child=$!
printf '%s\n' "$child" > "\(pidfilePath)"
# (1) read initialize request
IFS= read -r line || exit 0
# (2) reply to initialize — id 1 is MCPClient's first request id
printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"TestMCP","version":"1.0"}}}\n'
# (3) consume notifications/initialized (best effort)
IFS= read -r line || true
# Idle until the process group is signalled by MCPClient.stop().
wait "$child" 2>/dev/null
"""
        try scriptContent.write(to: serverScript, atomically: true, encoding: .utf8)
        chmod(serverScript.path, 0o755)

        let orchestrator = AgentOrchestrator()
        let client = MCPClient(
            serverName: "ProcessTreeTest",
            command: serverScript.path,
            arguments: [],
            logger: orchestrator,
            orchestrator: orchestrator,
            config: MCPClientConfig(
                requestTimeout: 20, pingTimeout: 10, maxRetries: 2,
                circuitFailureThreshold: 3, restartRateLimitWindow: 60, maxRestartsInWindow: 3
            )
        )

        try await client.start()
        #expect(await client.isRunning(), "MCPClient should be running after start()")

        // Collect the spawned child worker's pid (written by the server script
        // during the handshake). Poll briefly for robustness.
        let pidFileURL = URL(fileURLWithPath: pidfilePath)
        var childPid: pid_t?
        let pidDeadline = Date().addingTimeInterval(5)
        while Date() < pidDeadline {
            if let data = try? String(contentsOf: pidFileURL, encoding: .utf8),
               let value = Int(data.trimmingCharacters(in: .whitespacesAndNewlines)),
               value > 0 {
                childPid = pid_t(value)
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let pid = try #require(childPid)
        #expect(kill(pid, 0) == 0, "child worker must be alive immediately after start")

        // stop() must signal the whole process group — including the child.
        await client.stop()

        // Give the signalled processes a moment to exit, then assert the child
        // is gone. A child that survived would indicate stop() only signalled
        // the main pid (the pre-fix orphaning behaviour).
        var reaped = false
        let settleDeadline = Date().addingTimeInterval(2)
        while Date() < settleDeadline {
            if kill(pid, 0) != 0 { reaped = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(reaped, "child worker must be reaped by MCPClient.stop()'s process-group kill")
        #expect(!(await client.isRunning()), "client should report stopped")
    }
}
