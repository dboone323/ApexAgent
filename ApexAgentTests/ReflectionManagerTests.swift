import Testing
import Foundation
import SwiftData
import SharedKit
@testable import ApexAgentCore

@MainActor
@Suite("ReflectionManagerTests") final class ReflectionManagerTests {
    
    @Test func testReflectionTrigger() async throws {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        let history = [
            ChatMessage(role: .user, content: "Build failing with missing entitlement"),
            ChatMessage(role: .assistant, content: "Error: Process missing required entitlement: com.apple.developer.private-cloud-compute"),
            ChatMessage(role: .user, content: "Let's fix it by adding availability guard"),
            ChatMessage(role: .assistant, content: "Applied availability check. Build complete! Test succeeded.")
        ]
        
        let manager = ReflectionManager.shared
        
        // This should trigger the reflection pipeline async task without crashes
        manager.reflectIfResolved(
            prompt: "Fix entitlement crash",
            history: history,
            orchestrator: orchestrator
        )
        
        // Let background dispatch cycle complete
        try? await Task.sleep(for: .milliseconds(50))
    }
}
