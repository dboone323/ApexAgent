import Testing
import Foundation
import SwiftData
import SharedKit
@testable import ApexAgentCore

@MainActor
@Suite("CodeReviewPersistenceToolsTests") final class CodeReviewPersistenceToolsTests {
    private var orchestrator: AgentOrchestrator!
    private var container: ModelContainer!
    
    init() async throws {
        
        orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
    }
    
    private func makeArgs<T: Decodable>(_ json: String) -> T {
        let data = json.data(using: .utf8)!
        return try! JSONDecoder().decode(T.self, from: data)
    }
    
    @Test func testSaveAndListReviewSession() async throws {
        let saveTool = SaveReviewSessionTool(orchestrator: orchestrator)
        
        let issuesJSON = """
        [
            {"line": 22, "message": "PTY force unwrap", "severity": "error"},
            {"line": 45, "message": "Missing documentation", "severity": "info"}
        ]
        """
        
        // Escape issuesJSON properly for inside JSON string
        let escapedIssues = issuesJSON.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        
        let saveArgs: SaveReviewSessionTool.Arguments = makeArgs("""
        {
            "fileName": "PTYSession.swift",
            "summary": "PTY write validation review",
            "suggestions": ["Check return status of write()", "Add timeout"],
            "issuesJSON": "\(escapedIssues)"
        }
        """)
        
        let saveResult = try await saveTool.call(arguments: saveArgs)
        #expect(saveResult.contains("SUCCESS"))
        
        // Fetch review history
        let listTool = ListReviewSessionsTool(orchestrator: orchestrator)
        let listArgs = ListReviewSessionsTool.Arguments()
        let historyResult = try await listTool.call(arguments: listArgs)
        
        #expect(historyResult.contains("PTYSession.swift"))
        #expect(historyResult.contains("PTY write validation review"))
        #expect(historyResult.contains("PTY force unwrap"))
    }
}
