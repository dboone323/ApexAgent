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
        let manager = MCPManager.shared
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
}
