import Testing
import Foundation
@testable import ApexAgentCore

@Suite("ExternalToolsTests")
@MainActor
struct ExternalToolsTests {

    @Test("MailAutomationTool invalid action returns clear error message")
    func testMailAutomationToolValidation() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = MailAutomationTool(orchestrator: orchestrator)
        
        let args = MailAutomationTool.Arguments(
            action: "invalid_action",
            messageIndex: nil,
            subject: nil,
            to: nil,
            body: nil,
            folder: nil,
            searchQuery: nil,
            limit: 5
        )
        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR") || result.contains("Unknown action") || result.contains("Supported"))
    }

    @Test("DeepLinkTool URL scheme generation and validation")
    func testDeepLinkTool() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = DeepLinkTool(orchestrator: orchestrator)
        
        // 1. Invalid URL scheme action
        let invalidArgs = DeepLinkTool.Arguments(
            action: "open_url",
            title: nil,
            body: nil,
            searchQuery: nil,
            dueDate: nil,
            priority: nil,
            url: "ht tp://invalid url"
        )
        let result = try await tool.call(arguments: invalidArgs)
        #expect(result.contains("ERROR") || result.contains("Invalid URL"))
        
        // 2. Unknown action returns error
        let unknownArgs = DeepLinkTool.Arguments(
            action: "nonexistent_action",
            title: nil,
            body: nil,
            searchQuery: nil,
            dueDate: nil,
            priority: nil,
            url: nil
        )
        let unknownResult = try await tool.call(arguments: unknownArgs)
        #expect(unknownResult.contains("ERROR") || unknownResult.contains("Unknown action") || unknownResult.contains("Supported"))
    }
}
