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

    // MARK: - WS1.5 Handoff / Consensus reconciliation
    // Verifies the AgentHandoff DTOs are actually recorded by the registry
    // (the structured outputs delegate_task / convene_meeting now produce),
    // without requiring a live LanguageModelSession (which is unavailable on
    // the macOS 27 beta). Exercises the real DTO + store path end-to-end.

    @Test func testRecordHandoffStoresTaskResult() async {
        let result = TaskResult(
            taskId: "ws1-recon-1",
            status: "completed",
            resultSummary: "Sub-agent finished the task.",
            errorDetails: nil
        )
        await AgentRegistry.shared.recordHandoff(result)

        let recent = await AgentRegistry.shared.recentHandoffs(limit: 10)
        #expect(recent.contains { $0.taskId == "ws1-recon-1" })
        #expect(recent.first { $0.taskId == "ws1-recon-1" }?.status == "completed")
    }

    @Test func testRecordConsensusStoresConsensusReport() async {
        let report = ConsensusReport(
            consensusDecision: "Agreed on approach X.",
            majorityView: "Developer + Researcher support X.",
            minorityDissent: nil,
            confidence: 0.9
        )
        await AgentRegistry.shared.recordConsensus(report)

        let recent = await AgentRegistry.shared.recentConsensusReports(limit: 10)
        #expect(recent.contains { $0.consensusDecision == "Agreed on approach X." })
        #expect(recent.first?.confidence == 0.9)
    }

}

// MARK: - Markdown projection for registered agents

@Suite("RegisteredAgentMarkdownTests")
struct RegisteredAgentMarkdownTests {
    @Test func registeredAgentMarkdown() {
        let agent = RegisteredAgent(name: "developer", systemPrompt: "You build software.", allowedTools: ["read_file"], modelPreference: nil)
        let md = agent.formatAsMarkdown()
        #expect(md.contains("developer"))
        #expect(md.contains("read_file"))
    }
}
