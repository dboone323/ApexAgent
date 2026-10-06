import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("MCPResilienceTests")
struct MCPResilienceTests {

    @Test func testClientCircuitStateInitiallyOpenFalse() async {
        let orchestrator = AgentOrchestrator()
        let client = MCPClient(serverName: "WS6 Test", command: "/bin/echo", logger: orchestrator, orchestrator: orchestrator)
        #expect(!(await client.isCircuitOpen()))
    }

    @Test func testClientOpenCircuitSetsState() async {
        let orchestrator = AgentOrchestrator()
        let client = MCPClient(serverName: "WS6 Test", command: "/bin/echo", logger: orchestrator, orchestrator: orchestrator)
        await client.openCircuit()
        #expect(await client.isCircuitOpen())
    }

    @Test func testClientResetCircuitClearsState() async {
        let orchestrator = AgentOrchestrator()
        let client = MCPClient(serverName: "WS6 Test", command: "/bin/echo", logger: orchestrator, orchestrator: orchestrator)
        await client.openCircuit()
        #expect(await client.isCircuitOpen())
        await client.resetCircuit()
        #expect(!(await client.isCircuitOpen()))
    }

    @Test func testManagerResetClientCircuitForwardsToClient() async {
        let manager = MCPManager(persistsConfigs: false)
        let orchestrator = AgentOrchestrator()
        manager.orchestrator = orchestrator

        let config = MCPServerConfig(name: "WS6 Reset", command: "/bin/echo", arguments: [])
        let client = manager.getClient(for: config)
        await client.openCircuit()
        #expect(await client.isCircuitOpen())

        await manager.resetClientCircuit(id: config.id)
        #expect(!(await client.isCircuitOpen()))
    }

    @Test func testClientHealthSnapshotReportsRunningState() async {
        let orchestrator = AgentOrchestrator()
        let client = MCPClient(serverName: "WS6 Health", command: "/bin/echo", logger: orchestrator, orchestrator: orchestrator)
        let health = await client.health()
        #expect(health.serverName == "WS6 Health")
        #expect(health.circuitOpen == false)
    }

    @Test func testClientHealthSnapshotReflectsCircuitOpen() async {
        let orchestrator = AgentOrchestrator()
        let client = MCPClient(serverName: "WS6 Health", command: "/bin/echo", logger: orchestrator, orchestrator: orchestrator, config: MCPClientConfig(requestTimeout: 60, pingTimeout: 3, maxRetries: 1, circuitFailureThreshold: 3, restartRateLimitWindow: 60, maxRestartsInWindow: 1))
        await client.openCircuit()
        let health = await client.health()
        #expect(health.circuitOpen == true)
        #expect(health.failureCount >= 1)
    }

    /// End-to-end resilience proof: point the client at a process that stays
    /// alive but never replies (a silent server), and verify the real timeout ->
    /// retry -> circuit-open machinery actually fires — not just the state
    /// mutators exercised by openCircuit(). Uses a tight config so it fails fast.
    @Test func testClientTimeoutOpensCircuitAgainstSilentServer() async {
        let orchestrator = AgentOrchestrator()
        // Silent server: reads stdin but never writes a JSON-RPC response.
        let silentCommand = "/bin/zsh"
        let silentArgs = ["-c", "while true; do read line; sleep 1; done"]
        let config = MCPClientConfig(
            requestTimeout: 2,
            pingTimeout: 1,
            maxRetries: 1,
            circuitFailureThreshold: 1,
            restartRateLimitWindow: 60,
            maxRestartsInWindow: 1
        )
        let client = MCPClient(
            serverName: "WS6 Silent",
            command: silentCommand,
            arguments: silentArgs,
            logger: orchestrator,
            orchestrator: orchestrator,
            config: config
        )

        // The handshake must time out (no response) and trip the circuit.
        do {
            _ = try await client.listTools()
            Issue.record("Expected the silent server to cause a timeout/circuit-open, but listTools returned.")
        } catch {
            // Expected: timeout (or circuitOpen) once the retries are exhausted.
        }

        // Give the supervisor a moment to flip the circuit.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await client.isCircuitOpen(), "Circuit should open after the silent server fails to respond.")

        await client.stop()
    }

    // MARK: - Schema Validation & Hallucination Prevention Tests

    @Test @MainActor func testDynamicToolboxRejectsMissingRequiredParameters() async throws {
        let toolbox = DynamicToolbox.shared
        let toolName = "test_schema_tool_\(UUID().uuidString.prefix(6))"
        let schema: [String: Any] = [
            "name": toolName,
            "description": "Schema test tool",
            "parameters": [
                "type": "object",
                "properties": [
                    "targetPath": ["type": "string", "description": "Target file path"],
                    "count": ["type": "integer", "description": "Count"]
                ],
                "required": ["targetPath"]
            ]
        ]
        let entry = DynamicToolbox.DynamicToolEntry(
            name: toolName,
            description: "Schema test tool",
            scriptPath: nil,
            schema: schema,
            mcpServerId: UUID() // mock server ID to hit schema check before server lookup
        )

        toolbox.registerToolForTesting(name: toolName, entry: entry)
        defer {
            toolbox.removeToolForTesting(name: toolName)
        }

        // 1. Missing required parameter 'targetPath'
        do {
            _ = try await toolbox.executeTool(name: toolName, jsonArguments: "{\"count\": 5}")
            Issue.record("Expected missing required parameter validation error")
        } catch {
            let nsError = error as NSError
            #expect(nsError.localizedDescription.contains("missing required parameter 'targetPath'"))
        }

        // 2. Hallucinated/undeclared parameter 'hallucinatedExtra'
        do {
            _ = try await toolbox.executeTool(name: toolName, jsonArguments: "{\"targetPath\": \"/tmp/test\", \"hallucinatedExtra\": true}")
            Issue.record("Expected undeclared parameter validation error")
        } catch {
            let nsError = error as NSError
            #expect(nsError.localizedDescription.contains("undeclared parameter 'hallucinatedExtra'"))
        }

        // 3. Type mismatch: count expected type 'integer', received string 'five'
        do {
            _ = try await toolbox.executeTool(name: toolName, jsonArguments: "{\"targetPath\": \"/tmp/test\", \"count\": \"five\"}")
            Issue.record("Expected parameter type mismatch validation error")
        } catch {
            let nsError = error as NSError
            #expect(nsError.localizedDescription.contains("expected type 'integer'"))
        }
    }
}

// MARK: - Input validation hardening for MCP configs

@Suite("MCPConfigValidationTests")
struct MCPConfigValidationTests {
    @Test func mcpServerConfigValidation() {
        var cfg = MCPServerConfig(name: "", command: "npx", arguments: [])
        #expect(!cfg.isValid)
        #expect(cfg.validationError() != nil)
        cfg = MCPServerConfig(name: "FS", command: "npx", arguments: ["-y", "x"])
        #expect(cfg.isValid)
        cfg = MCPServerConfig(name: "W", command: "x", arguments: [], transport: "http", endpointURL: nil)
        #expect(!cfg.isValid)
        cfg = MCPServerConfig(name: "W", command: "x", arguments: [], transport: "http", endpointURL: "ftp://bad")
        #expect(!cfg.isValid)
        cfg = MCPServerConfig(name: "W", command: "x", arguments: [], transport: "http", endpointURL: "https://ok/hooks")
        #expect(cfg.isValid)
        cfg = MCPServerConfig(name: "W", command: "x", arguments: [], transport: "carrier-pigeon")
        #expect(!cfg.isValid)
    }

    @Test func mcpClientConfigClamped() {
        let bad = MCPClientConfig(requestTimeout: -5, pingTimeout: 5000, maxRetries: 999, circuitFailureThreshold: 0, restartRateLimitWindow: -1, maxRestartsInWindow: 999)
        let c = bad.clamped()
        #expect(c.requestTimeout >= 1 && c.requestTimeout <= 600)
        #expect(c.pingTimeout >= 0.5 && c.pingTimeout <= 60)
        #expect(c.maxRetries <= 20)
        #expect(c.circuitFailureThreshold >= 1)
        #expect(c.maxRestartsInWindow <= 50)
    }
}
