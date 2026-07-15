import Testing
import Foundation
import SwiftData
import SharedKit
@testable import ApexAgentCore

@MainActor
@Suite("FileSearchToolTests") final class FileSearchToolTests {
    
    @Test func testFileSearchSuccess() async throws {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        let tool = FileSearchTool(orchestrator: orchestrator)
        
        let fm = FileManager.default
        let resolvedTempPath = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let tempDir = URL(fileURLWithPath: resolvedTempPath).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempDir)
        }
        
        // Write mock files with target search terms
        let mockFile1 = tempDir.appendingPathComponent("target1.txt")
        try "TargetKeyPhraseOne is here".write(to: mockFile1, atomically: true, encoding: .utf8)
        let mockFile2 = tempDir.appendingPathComponent("target2.txt")
        try "Standard context message".write(to: mockFile2, atomically: true, encoding: .utf8)
        
        let args = FileSearchTool.Arguments(
            query: "TargetKeyPhraseOne",
            directory: tempDir.path,
            filePattern: "*.txt"
        )
        
        let result = try await tool.call(arguments: args)
        print("DEBUG RESULT: '\(result)'")
        #expect(result.contains("target1.txt"))
        #expect(result.contains("TargetKeyPhraseOne"))
        #expect(!(result.contains("target2.txt")))
    }
}
