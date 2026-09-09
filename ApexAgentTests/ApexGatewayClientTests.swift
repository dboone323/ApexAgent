import Testing
import Foundation
import SwiftData
@testable import ApexAgentCore

@MainActor
@Suite("ApexGatewayClientTests") final class ApexGatewayClientTests {

    @Test func testClientInitialStateAndMethods() {
        let client = ApexGatewayClient()
        client.disconnect()
        #expect(!(client.isConnected))
        #expect(!(client.isGenerating))
        #expect(client.activeAssistantMessageId == nil)

        // Ensure disconnect resets variables safely
        client.disconnect()
        #expect(!(client.isConnected))
    }

    /// Real-path test: the client must actually establish and tear down a connection
    /// to a running ApexGatewayServer (not just assert initial state).
    @Test func testClientConnectsAndDisconnects() async throws {
        let orchestrator = AgentOrchestrator()
        let server = ApexGatewayServer(port: 27888, orchestrator: orchestrator)
        try server.start()
        defer { server.stop() }

        let client = ApexGatewayClient()
        client.connect(port: 27888)

        // Wait for the NWConnection state handler to flip isConnected.
        let connected = await withTimeout(seconds: 3) { client.isConnected }
        #expect(connected, "Client should report isConnected after connecting to a live server")

        client.disconnect()
        let disconnected = await withTimeout(seconds: 3) { !(client.isConnected) }
        #expect(disconnected, "Client should report !isConnected after disconnect()")
    }

    @Test func testServerReachabilityPreflight() async throws {
        let testPort: UInt16 = 27999
        // 1. Port is closed — must report false
        #expect(!ApexGatewayClient.isServerReachable(port: testPort))

        // 2. Start real server on port — must report true
        let orchestrator = AgentOrchestrator()
        let server = ApexGatewayServer(port: testPort, orchestrator: orchestrator)
        try server.start()

        // Allow socket listener to bind
        var reachable = false
        for _ in 0..<20 {
            if ApexGatewayClient.isServerReachable(port: testPort) {
                reachable = true
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(reachable, "Preflight reachability probe should return true when server is listening")

        // 3. Stop server — must return to false
        server.stop()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!ApexGatewayClient.isServerReachable(port: testPort), "Preflight probe should return false once server is stopped")
    }
}

extension ApexGatewayClientTests {
    /// Polls `producer` until it returns true or the timeout elapses.
    private func withTimeout(seconds: Double, _ producer: @escaping () async -> Bool) async -> Bool {
        let start = ContinuousClock().now
        while ContinuousClock().now - start < .seconds(seconds) {
            if await producer() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await producer()
    }
}
