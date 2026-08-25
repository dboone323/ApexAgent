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
        orchestrator.modelContext = ModelContext(container)
        
        let contentView = ContentView()
            .environment(orchestrator)
        
        _ = contentView // view construction succeeded
        
        let sidebar = SidebarView(
            conversations: [],
            selectedConversation: nil,
            onSelectConversation: { _ in },
            onDeleteConversations: { _ in }
        )
        .environment(orchestrator)
        _ = sidebar // view construction succeeded
        
        #expect(!(orchestrator.isGenerating))
    }
    
    @MainActor
    @Test func testChatViewAndMessageBubble() throws {
        let orchestrator = AgentOrchestrator()
        let msg = ChatMessage(role: .user, content: "Hello **world**!")
        orchestrator.appendMessage(msg)
        
        let chatView = ChatView()
            .environment(orchestrator)
        _ = chatView // view construction succeeded
        
        let bubble = MessageBubble(message: msg)
        let view = bubble.environment(orchestrator)
        _ = view // view construction succeeded
        
        let markdownView = MarkdownText(content: msg.content)
        let parsed = markdownView.parseBlocks(msg.content)
        #expect(parsed.count == 1)
        if case .text(let textContent) = parsed[0].type {
            #expect(textContent.contains("Hello **world**!"))
        }
    }
    
    @MainActor
    @Test func testSettingsViewAndKeychain() throws {
        let orchestrator = AgentOrchestrator()
        let settingsView = SettingsView()
            .environment(orchestrator)
        _ = settingsView // view construction succeeded
    }
    
    @MainActor
    @Test func testPlanDashboardAndToolActivityViews() throws {
        let orchestrator = AgentOrchestrator()
        let planView = PlanDashboardView()
            .environment(orchestrator)
        _ = planView // view construction succeeded
        
        let toolActivityView = ToolActivityView()
            .environment(orchestrator)
        _ = toolActivityView // view construction succeeded
    }
    
    @MainActor
    @Test func testTerminalAndDiagnosticsViews() throws {
        let orchestrator = AgentOrchestrator()
        let terminalView = TerminalView()
            .environment(orchestrator)
        _ = terminalView // view construction succeeded
        
        let diagnosticsView = DiagnosticsView()
            .environment(orchestrator)
        _ = diagnosticsView // view construction succeeded
    }
}
