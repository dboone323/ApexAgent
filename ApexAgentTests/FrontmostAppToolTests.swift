import Testing
import Foundation
import AppKit
@testable import ApexAgentCore

@Suite("Batch 3: FrontmostAppTool Tests", .serialized)
struct FrontmostAppToolTests {

    @Test("GetFrontmostAppTool metadata check")
    @MainActor
    func testFrontmostAppToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = GetFrontmostAppTool(orchestrator: orchestrator)
        #expect(tool.name == "get_frontmost_app")
        #expect(tool.description.contains("frontmost") || tool.description.contains("active"))
    }

    @Test("GetFrontmostAppTool extracts active application information cleanly")
    @MainActor
    func testFrontmostAppToolExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = GetFrontmostAppTool(orchestrator: orchestrator)
        let args = GetFrontmostAppTool.Arguments()

        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        // Should contain either the active application details or fallback message if headless
        #expect(
            result.contains("Frontmost App:") ||
            result.contains("Bundle ID:") ||
            result.contains("No frontmost application found")
        )

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            let pid = frontmost.processIdentifier
            #expect(result.contains("PID: \(pid)"))
        }
    }
}
