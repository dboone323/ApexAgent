import Testing
import Foundation
@testable import ApexAgentCore

@Suite("HardeningCycle3DenyTests") @MainActor
struct HardeningCycle3DenyTests {

    @Test func askBotDeniedReturnsRefusal() async throws {
        setenv("APEX_FORCE_DENY", "1", 1)
        defer { unsetenv("APEX_FORCE_DENY") }
        let orch = AgentOrchestrator()
        let tool = AskBotTool(orchestrator: orch)
        let result = try await tool.call(arguments: .init(targetBot: "Nobody", message: "hi"))
        #expect(result == "ERROR: Operation denied by user.")
    }

    @Test func dispatchSwarmDeniedReturnsRefusal() async throws {
        setenv("APEX_FORCE_DENY", "1", 1)
        defer { unsetenv("APEX_FORCE_DENY") }
        let tool = DispatchSwarmTool(botManager: nil)
        let result = try await tool.call(arguments: .init(targetBots: "X", taskPrompts: "hi"))
        #expect(result == "ERROR: Operation denied by user.")
    }

    @Test func writeFileDeniedNoMutation() async throws {
        setenv("APEX_FORCE_DENY", "1", 1)
        defer { unsetenv("APEX_FORCE_DENY") }
        let orch = AgentOrchestrator()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("f.txt").path
        try "original".write(toFile: path, atomically: true, encoding: .utf8)
        let tool = FileWriteTool(orchestrator: orch)
        let result = try await tool.call(arguments: .init(path: path, content: "mutated", append: nil))
        #expect(result == "ERROR: Operation denied by user.")
        let after = try String(contentsOfFile: path, encoding: .utf8)
        #expect(after == "original")
    }
}
