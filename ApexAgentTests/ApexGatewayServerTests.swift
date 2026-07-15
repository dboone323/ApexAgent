import Testing
import Foundation
import SwiftData
import SharedKit
@testable import ApexAgentCore

@MainActor
@Suite("ApexGatewayServerTests") final class ApexGatewayServerTests {
    
    @Test func testServerLifecycle() async throws {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        let server = ApexGatewayServer(port: 27777, orchestrator: orchestrator)
        #expect(server != nil)
        
        // Start the server
        try server.start()
        
        // Trigger a state change to exercise the broadcast state routing
        orchestrator.onStateChanged?()
        
        // Stop the server
        server.stop()
    }
}
