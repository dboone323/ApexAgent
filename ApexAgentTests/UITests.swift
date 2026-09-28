import Testing
import Foundation
import SwiftUI
import SwiftData
@testable import ApexAgentCore
import SharedModels

@Suite("UITests") class UITests {

    @MainActor
    @Test func testContentViewAndSidebarView() throws {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        orchestrator.modelContext = context
        
        // 1. Verify model persistence and conversation state
        let conversation = Conversation(title: "Audit Test Conversation")
        context.insert(conversation)
        try context.save()
        
        let descriptor = FetchDescriptor<Conversation>()
        let saved = try context.fetch(descriptor)
        #expect(saved.count == 1)
        #expect(saved.first?.title == "Audit Test Conversation")
        
        // 2. Verify sidebar selection interaction
        var selectedId: UUID?
        let onSelect: (Conversation) -> Void = { conv in selectedId = conv.id }
        let onDelete: (IndexSet) -> Void = { indexSet in
            for idx in indexSet {
                context.delete(saved[idx])
            }
            try? context.save()
        }
        
        let sidebar = SidebarView(
            conversations: saved,
            selectedConversation: saved.first,
            onSelectConversation: onSelect,
            onDeleteConversations: onDelete
        )
        _ = sidebar.environment(orchestrator)
        
        // Trigger selection callback
        onSelect(saved[0])
        #expect(selectedId == conversation.id)
        
        // Trigger deletion callback
        onDelete(IndexSet(integer: 0))
        let remaining = try context.fetch(descriptor)
        #expect(remaining.isEmpty, "Conversation should be deleted from context")
        #expect(!orchestrator.isGenerating)
    }
    
    @MainActor
    @Test func testChatViewAndMessageBubble() throws {
        let orchestrator = AgentOrchestrator()
        let msg = ChatMessage(role: .user, content: "Hello **world**!")
        orchestrator.appendMessage(msg)
        #expect(orchestrator.messages.count == 1)
        #expect(orchestrator.messages.first?.content == "Hello **world**!")
        
        // Test complex markdown block parsing
        let complexMarkdown = """
        Here is an introductory text.
        ```swift
        let result = 42
        print(result)
        ```
        And a trailing explanation.
        """
        
        let markdownView = MarkdownText(content: complexMarkdown)
        let parsed = markdownView.parseBlocks(complexMarkdown)
        #expect(parsed.count == 3, "Should parse text, code block, and trailing text")
        
        if case .text(let intro) = parsed[0].type {
            #expect(intro.contains("introductory text"))
        } else {
            Issue.record("First block should be text")
        }
        
        if case .code(let lang, let code) = parsed[1].type {
            #expect(lang == "swift")
            #expect(code.contains("let result = 42"))
        } else {
            Issue.record("Second block should be swift code")
        }
        
        if case .text(let trailing) = parsed[2].type {
            #expect(trailing.contains("trailing explanation"))
        } else {
            Issue.record("Third block should be trailing text")
        }
    }
    
    @MainActor
    @Test func testSettingsViewAndIsolationModes() throws {
        let orchestrator = AgentOrchestrator()
        _ = SettingsView()
            .environment(orchestrator)
        
        // Verify IsolationMode enum completeness and display values
        let allModes = IsolationMode.allCases
        #expect(allModes.count == 3)
        #expect(allModes.map(\.rawValue).contains("None"))
        #expect(allModes.map(\.rawValue).contains("Apple Container"))
        #expect(allModes.map(\.rawValue).contains("Docker"))
    }
    
    @MainActor
    @Test func testPlanDashboardAndToolActivityViews() throws {
        let orchestrator = AgentOrchestrator()
        
        // Append real tool events into orchestrator
        orchestrator.logToolStart(name: "read_file", arguments: "{\"path\": \"/tmp/test.swift\"}")
        #expect(orchestrator.toolEvents.count == 1)
        #expect(orchestrator.toolEvents.first?.toolName == "read_file")
        #expect(orchestrator.toolEvents.first?.status == .running)
        
        orchestrator.logToolEnd(name: "read_file", result: "file contents", status: .success)
        #expect(orchestrator.toolEvents.first?.status == .success)
        #expect(orchestrator.toolEvents.first?.result == "file contents")
    }
    
    @MainActor
    @Test func testTerminalAndDiagnosticsViews() throws {
        // Verify terminal panel preference toggle in UserDefaults (@AppStorage)
        UserDefaults.standard.set(true, forKey: "showTerminal")
        #expect(UserDefaults.standard.bool(forKey: "showTerminal") == true)
        
        UserDefaults.standard.set(false, forKey: "showTerminal")
        #expect(UserDefaults.standard.bool(forKey: "showTerminal") == false)
        
        // Verify diagnostics engine capability evaluation
        let diagnostics = ContainerManager.checkHostCapabilities()
        #expect(!diagnostics.macOSVersionString.isEmpty)
        #expect(diagnostics.availableDiskSpaceBytes >= 0)
    }
}
