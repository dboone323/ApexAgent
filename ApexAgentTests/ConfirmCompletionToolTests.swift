import Testing
import Foundation
import SwiftData
@testable import ApexAgentCore

@MainActor
@Suite("ConfirmCompletionToolTests") final class ConfirmCompletionToolTests {
    
    @Test func testConfirmCompletionApproved() async throws {
        print("DIAG-CONF APEX_TEST_MODE = \(ProcessInfo.processInfo.environment["APEX_TEST_MODE"] ?? "nil"), XCTest class = \(NSClassFromString("XCTest") != nil)")
        let orchestrator = AgentOrchestrator()
        let tool = ConfirmCompletionTool(orchestrator: orchestrator)
        
        let args = ConfirmCompletionTool.Arguments(
            summary: "Finished fixing strict concurrency warnings",
            filesModified: "AgentEngine.swift",
            verificationResults: "All tests compiled and passed successfully"
        )
        
        let result = try await tool.call(arguments: args)
        #expect(result.contains("SUCCESS"))
        #expect(result.contains("user has approved task completion"))
    }
}
