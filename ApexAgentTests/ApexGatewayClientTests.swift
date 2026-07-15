import Testing
import Foundation
import SwiftData
@testable import ApexAgentCore

@MainActor
@Suite("ApexGatewayClientTests") final class ApexGatewayClientTests {
    
    @Test func testClientInitialStateAndMethods() {
        let client = ApexGatewayClient()
        client.disconnect()
        #expect(client != nil)
        #expect(!(client.isConnected))
        #expect(!(client.isGenerating))
        #expect(client.activeAssistantMessageId == nil)
        
        // Ensure disconnect resets variables safely
        client.disconnect()
        #expect(!(client.isConnected))
    }
}
