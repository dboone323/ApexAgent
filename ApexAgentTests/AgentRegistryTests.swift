import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("AgentRegistryTests")
struct AgentRegistryTests {

    @Test func testBuiltInDefaultsContainExpectedAgents() {
        let agents = AgentRegistry.shared.allAgents()
        let names = agents.map(\.name)
        #expect(names.contains("developer"))
        #expect(names.contains("executor"))
        #expect(names.contains("researcher"))
        #expect(names.contains("planner"))
    }

    @Test func testResolveKnownAgentReturnsRegisteredAgent() {
        let agent = AgentRegistry.shared.resolve(name: "Developer")
        #expect(agent != nil)
        #expect(agent?.name == "developer")
    }

    @Test func testResolveUnknownAgentReturnsNil() {
        let agent = AgentRegistry.shared.resolve(name: "nonexistent-agent-xyz")
        #expect(agent == nil)
    }

    @Test func testResolveIsCaseAndWhitespaceInsensitive() {
        let agent = AgentRegistry.shared.resolve(name: "  Developer  ")
        #expect(agent != nil)
        #expect(agent?.name == "developer")
    }

    @Test func testRegisterAndResolveCustomAgent() {
        let custom = RegisteredAgent(
            name: "customTestAgent",
            systemPrompt: "Test prompt",
            allowedTools: ["read_file"],
            modelPreference: nil
        )
        AgentRegistry.shared.register(custom)

        let resolved = AgentRegistry.shared.resolve(name: "customTestAgent")
        #expect(resolved != nil)
        #expect(resolved?.name == "customTestAgent")
        #expect(resolved?.allowedTools == ["read_file"])
    }

    @Test func testRegisterOverwriteReplacesExistingAgent() {
        let original = RegisteredAgent(name: "overwriteTarget", systemPrompt: "original", allowedTools: [], modelPreference: nil)
        let replacement = RegisteredAgent(name: "overwriteTarget", systemPrompt: "replacement", allowedTools: ["write_file"], modelPreference: nil)
        AgentRegistry.shared.register(original)
        AgentRegistry.shared.register(replacement)

        let resolved = AgentRegistry.shared.resolve(name: "overwriteTarget")
        #expect(resolved?.systemPrompt == "replacement")
        #expect(resolved?.allowedTools == ["write_file"])
    }

    @Test func testUnregisterRemovesAgent() {
        let custom = RegisteredAgent(name: "toBeRemoved", systemPrompt: "temp", allowedTools: [], modelPreference: nil)
        AgentRegistry.shared.register(custom)
        #expect(AgentRegistry.shared.resolve(name: "toBeRemoved") != nil)

        AgentRegistry.shared.unregister(name: "toBeRemoved")
        #expect(AgentRegistry.shared.resolve(name: "toBeRemoved") == nil)
    }

    @Test func testTaskContextDTORoundTripsThroughCodable() {
        let context = TaskContext(
            taskId: "task-1",
            topic: "review",
            instructions: "review code",
            contextHistory: "none"
        )
        let data = try? JSONEncoder().encode(context)
        #expect(data != nil)
        let decoded = try? JSONDecoder().decode(TaskContext.self, from: data!)
        #expect(decoded != nil)
        #expect(decoded?.taskId == "task-1")
    }

    @Test func testTaskResultDTOEncodesStatusFields() {
        let result = TaskResult(
            taskId: "task-2",
            status: "completed",
            resultSummary: "done",
            errorDetails: nil
        )
        let data = try? JSONEncoder().encode(result)
        let decoded = try? JSONDecoder().decode(TaskResult.self, from: data!)
        #expect(decoded?.status == "completed")
        #expect(decoded?.errorDetails == nil)
    }

    @Test func testLoadAgentsFromDiskLoadsValidJSON() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let diskAgent = RegisteredAgent(name: "diskAgent", systemPrompt: "from disk", allowedTools: ["read_file"], modelPreference: nil)
        let fileURL = tempDir.appendingPathComponent("agent.json")
        let data = try JSONEncoder().encode(diskAgent)
        try data.write(to: fileURL)

        await AgentRegistry.shared.loadAgentsFromDisk(directory: tempDir)

        let resolved = AgentRegistry.shared.resolve(name: "diskAgent")
        #expect(resolved != nil)
        #expect(resolved?.systemPrompt == "from disk")
    }

    @Test func testLoadAgentsFromDiskIgnoresInvalidJSON() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let badURL = tempDir.appendingPathComponent("bad.json")
        try "not json".write(to: badURL, atomically: true, encoding: .utf8)

        await AgentRegistry.shared.loadAgentsFromDisk(directory: tempDir)

        // Registry should still resolve built-in agents and not crash.
        #expect(AgentRegistry.shared.resolve(name: "developer") != nil)
    }

}
