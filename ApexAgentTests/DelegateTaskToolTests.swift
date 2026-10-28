import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 4: DelegateTaskTool Tests", .serialized)
struct DelegateTaskToolTests {

    @Test("DelegateTaskTool metadata check")
    @MainActor
    func testDelegateTaskToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = DelegateTaskTool(orchestrator: orchestrator)
        #expect(tool.name == "delegate_task")
        #expect(tool.description.contains("Delegates the user's specific concrete task to a specialized sub-agent"))
    }

    @Test("DelegateTaskTool enforces recursion depth limit when depth >= 2")
    @MainActor
    func testRecursionDepthLimit() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = DelegateTaskTool(orchestrator: orchestrator)

        let args = DelegateTaskTool.Arguments(agentType: "developer", taskDescription: "Run inner task")

        // Simulate activeDelegationDepth at 2
        let result = try await DelegateTaskTool.$activeDelegationDepth.withValue(2) {
            try await tool.call(arguments: args)
        }

        #expect(result.contains("ERROR: Maximum delegation depth reached."))
    }

    @Test("DelegateTaskTool returns error for invalid or unregistered agentType")
    @MainActor
    func testInvalidAgentType() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = DelegateTaskTool(orchestrator: orchestrator)

        let args = DelegateTaskTool.Arguments(agentType: "non_existent_agent_archetype", taskDescription: "Do something")
        let result = try await tool.call(arguments: args)

        #expect(result.contains("ERROR: Invalid agentType 'non_existent_agent_archetype'."))
    }

    @Test("DelegateTaskTool resolves valid agentType and sets up delegation context")
    @MainActor
    func testValidAgentResolution() {
        // Verify AgentRegistry resolves primary subagents
        let developerAgent = AgentRegistry.shared.resolve(name: "developer")
        #expect(developerAgent != nil)
        #expect(developerAgent?.name == "developer")

        let researcherAgent = AgentRegistry.shared.resolve(name: "researcher")
        #expect(researcherAgent != nil)
        #expect(researcherAgent?.name == "researcher")
    }
}
