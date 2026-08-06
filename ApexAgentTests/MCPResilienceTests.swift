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
}
