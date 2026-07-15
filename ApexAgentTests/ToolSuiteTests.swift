import Testing
import Foundation
import SwiftUI
import SwiftData
@testable import ApexAgentCore
import SharedModels

@MainActor
@Suite("ToolSuiteTests") struct ToolSuiteTests {
    let orchestrator: AgentOrchestrator
    let container: ModelContainer
    
    init() async throws {
        
        orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        let perms = AppPermissions()
        perms.musicFolderAllowed = true
        perms.desktopFolderAllowed = true
        perms.documentsFolderAllowed = true
        perms.downloadsFolderAllowed = true
        orchestrator.modelContext?.insert(perms)
        orchestrator.permissions = perms

        
        orchestrator.confirmationGateway = { _, _, _ in
            return true
        }
    }
    
    
    
    @MainActor
    @Test func testShellTool() async throws {
        let shellTool = ShellTool(orchestrator: orchestrator)
        let conv = Conversation(title: "Shell Test")
        orchestrator.currentConversation = conv
        orchestrator.modelContext?.insert(conv)
        
        let echoResult = try await shellTool.call(arguments: ShellTool.Arguments(command: "echo 'Apex Shell Output'"))
        #expect(echoResult.contains("Apex Shell Output"))
    }
    
    // testAppleScriptTool → moved to ApexAgentIntelligenceTests/SystemIntegrationTests.swift
    
    @MainActor
    @Test func testFileSearchAndFileSystemTools() async throws {
        let writeTool = FileWriteTool(orchestrator: orchestrator)
        let searchTool = FileSearchTool(orchestrator: orchestrator)
        let readTool = FileReadTool(orchestrator: orchestrator)
        
        let tempDir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        
        let testFilePath = tempDir + "/test_file.txt"
        let testContent = "Searching for a specific needle in the haystack."
        
        _ = try await writeTool.call(arguments: FileWriteTool.Arguments(path: testFilePath, content: testContent))
        
        let searchResult = try await searchTool.call(arguments: FileSearchTool.Arguments(query: "needle", directory: tempDir))
        #expect(searchResult.contains("test_file.txt"))
        
        let readResult = try await readTool.call(arguments: FileReadTool.Arguments(path: testFilePath))
        #expect(readResult.contains("Searching for a specific needle"))
    }
    
    @MainActor
    @Test func testMemoryTools() async throws {
        let storeTool = StoreMemoryTool(orchestrator: orchestrator)
        let searchTool = SearchMemoryTool(orchestrator: orchestrator)
        
        let memoryKey = "apex_test_memory_key"
        let memoryContent = "Important context about Apex project structure."
        
        _ = try await storeTool.call(arguments: StoreMemoryTool.Arguments(key: memoryKey, value: memoryContent, category: "general"))
        
        let searchResult = try await searchTool.call(arguments: SearchMemoryTool.Arguments(query: "Important context", category: "general"))
        #expect(searchResult.contains(memoryKey))
    }
}
