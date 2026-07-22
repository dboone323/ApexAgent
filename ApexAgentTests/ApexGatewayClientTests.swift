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
        let connected = await withTimeout(seconds: 3) { await client.isConnected }
        #expect(connected, "Client should report isConnected after connecting to a live server")

        client.disconnect()
        let disconnected = await withTimeout(seconds: 3) { !(await client.isConnected) }
        #expect(disconnected, "Client should report !isConnected after disconnect()")
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
