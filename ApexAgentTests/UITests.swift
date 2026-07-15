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
        
        #expect(contentView != nil)
        
        let sidebar = SidebarView(
            conversations: [],
            selectedConversation: nil,
            onSelectConversation: { _ in },
            onDeleteConversations: { _ in }
        )
        .environment(orchestrator)
        #expect(sidebar != nil)
        
        #expect(!(orchestrator.isGenerating))
    }
    
    @MainActor
    @Test func testChatViewAndMessageBubble() throws {
        let orchestrator = AgentOrchestrator()
        let msg = ChatMessage(role: .user, content: "Hello **world**!")
        orchestrator.appendMessage(msg)
        
        let chatView = ChatView()
            .environment(orchestrator)
        #expect(chatView != nil)
        
        let bubble = MessageBubble(message: msg)
        let view = bubble.environment(orchestrator)
        #expect(view != nil)
        
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
        #expect(settingsView != nil)
    }
    
    @MainActor
    @Test func testPlanDashboardAndToolActivityViews() throws {
        let orchestrator = AgentOrchestrator()
        let planView = PlanDashboardView()
            .environment(orchestrator)
        #expect(planView != nil)
        
        let toolActivityView = ToolActivityView()
            .environment(orchestrator)
        #expect(toolActivityView != nil)
    }
    
    @MainActor
    @Test func testTerminalAndDiagnosticsViews() throws {
        let orchestrator = AgentOrchestrator()
        let terminalView = TerminalView()
            .environment(orchestrator)
        #expect(terminalView != nil)
        
        let diagnosticsView = DiagnosticsView()
            .environment(orchestrator)
        #expect(diagnosticsView != nil)
    }
}
