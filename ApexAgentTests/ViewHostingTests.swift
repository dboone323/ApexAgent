import Testing
import Foundation
import SwiftUI
import AppKit
@testable import ApexAgentCore

// MARK: - Phase 3: SwiftUI view-body coverage via real NSHostingView hosting.
// Pattern (xcode27-real-tests §5): host in NSHostingView inside NSWindow,
// layoutSubtreeIfNeeded + displayIfNeeded, pump the run loop briefly so
// .task/.onAppear fire. Branches driven by real state permutations — no mocks.

@MainActor
enum ViewHost {
    /// Hosts a SwiftUI view in a real window and pumps the run loop.
    @discardableResult
    static func host<V: View>(_ view: V, size: NSSize = NSSize(width: 800, height: 600), pump: TimeInterval = 0.05) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: pump))
        window.orderOut(nil)
        return hosting
    }
}

@Suite("ViewHostingTests", .serialized) @MainActor final class ViewHostingTests {

    init() {
        setenv("APEX_TEST_MODE", "1", 1)
    }

    // MARK: Leaf components (no environment needed)

    @Test func testEmptyStateWithAndWithoutAction() {
        var tapped = false
        ViewHost.host(EmptyState(
            icon: "tray",
            title: "Nothing here",
            message: "No content yet",
            actionTitle: "Reload",
            action: { tapped = true }
        ))
        ViewHost.host(EmptyState(
            icon: "tray",
            title: "Nothing here",
            message: "No content yet",
            actionTitle: nil,
            action: nil
        ))
        #expect(tapped == false) // hosted, not clicked — rendering only
    }

    @Test func testSectionHeaderVariants() {
        ViewHost.host(VStack {
            SectionHeader(title: "General", icon: "gear", subtitle: "App-wide settings")
            SectionHeader(title: "Bare", icon: nil, subtitle: nil)
        })
    }

    @Test func testAppCardRendersContent() {
        ViewHost.host(AppCard { Text("card body") })
    }

    @Test func testDiagnosticCardRenders() {
        ViewHost.host(VStack {
            DiagnosticCard(title: "CPU", subtitle: "Load", status: "ok", message: "12%")
            DiagnosticCard(title: "Net", subtitle: "Ping", status: "fail", message: "timeout")
        })
    }

    @Test func testAgentAndUserAvatars() {
        ViewHost.host(HStack { AgentAvatar(); UserAvatar() })
    }

    @Test func testTypingIndicatorAnimates() {
        ViewHost.host(TypingIndicator(), pump: 0.15)
    }

    @Test func testBubbleShapeBothOrientations() {
        let user = BubbleShape(isUser: true).path(in: CGRect(x: 0, y: 0, width: 100, height: 40))
        let agent = BubbleShape(isUser: false).path(in: CGRect(x: 0, y: 0, width: 100, height: 40))
        #expect(!user.isEmpty)
        #expect(!agent.isEmpty)
        #expect(user.description != agent.description)
    }

    // MARK: DiffView — real diff computation across branches

    @Test func testDiffViewAddDeleteContext() {
        let old = "line1\nline2\nline3"
        let new = "line1\nline2changed\nline3\nline4"
        ViewHost.host(DiffView(oldContent: old, newContent: new), pump: 0.1)
    }

    @Test func testDiffViewEmptyToContent() {
        ViewHost.host(DiffView(oldContent: "", newContent: "brand new file"), pump: 0.1)
    }

    @Test func testDiffViewIdenticalContent() {
        ViewHost.host(DiffView(oldContent: "same", newContent: "same"), pump: 0.1)
    }

    // MARK: MessageBubble / MarkdownText / CodeBlock

    @Test func testMessageBubbleUserPlain() {
        let msg = ChatMessage(role: .user, content: "hello agent")
        ViewHost.host(MessageBubble(message: msg))
    }

    @Test func testMessageBubbleAssistantMarkdownAndCode() {
        let content = """
        Here is **bold** and a list:
        - item one
        - item two

        ```swift
        let x = 42
        ```

        ## A heading
        > a quote
        """
        let msg = ChatMessage(role: .assistant, content: content)
        ViewHost.host(MessageBubble(message: msg), pump: 0.1)
    }

    @Test func testMessageBubbleStreamingShowsTyping() {
        let msg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        ViewHost.host(MessageBubble(message: msg), pump: 0.1)
    }

    @Test func testMessageBubbleWithToolEvents() {
        var event = ToolEvent(toolName: "run_command", arguments: #"{"cmd":"ls"}"#)
        event.status = .success
        event.result = "file1\nfile2"
        var failed = ToolEvent(toolName: "write_file", arguments: "{}")
        failed.status = .failed("permission denied")
        let msg = ChatMessage(role: .assistant, content: "done", toolEvents: [event, failed])
        ViewHost.host(MessageBubble(message: msg), pump: 0.1)
    }

    @Test func testCodeBlockRenders() {
        ViewHost.host(CodeBlock(language: "swift", code: "print(\"hi\")"))
    }

    // MARK: ToolActivityView rows

    @Test func testToolActivityAllStatuses() {
        var running = ToolEvent(toolName: "search", arguments: "{}")
        running.status = .running
        var ok = ToolEvent(toolName: "read", arguments: "{}")
        ok.status = .success
        ok.result = "content"
        var failed = ToolEvent(toolName: "exec", arguments: "{}")
        failed.status = .failed("boom")
        var waiting = ToolEvent(toolName: "rm", arguments: "{}")
        waiting.status = .awaitingConfirmation
        var denied = ToolEvent(toolName: "sudo", arguments: "{}")
        denied.status = .denied
        ViewHost.host(
            VStack {
                ToolEventRow(event: running)
                ToolEventRow(event: ok)
                ToolEventRow(event: failed)
                ToolEventRow(event: waiting)
                ToolEventRow(event: denied)
            },
            pump: 0.1
        )
    }

    // MARK: PlanStep components

    @Test func testPlanStepRowAllStatuses() {
        let steps = PlanStepStatus.allCases.enumerated().map { idx, status in
            PlanStep(title: "Step \(idx)", status: status, result: status == .completed ? "ok" : nil, error: status == .failed ? "err" : nil)
        }
        ViewHost.host(
            VStack {
                ForEach(steps) { step in
                    PlanStepRow(step: step, index: 0) {}
                }
            },
            pump: 0.1
        )
    }

    @Test func testPlanStepDetailView() {
        let step = PlanStep(title: "Build", status: .failed, result: "partial", error: "exit 65")
        ViewHost.host(PlanStepDetailView(step: step))
    }

    // MARK: TerminalStateView + toolbar

    @Test func testTerminalStateViewAllStates() {
        ViewHost.host(VStack {
            TerminalStateView(state: .idle, message: nil)
            TerminalStateView(state: .running, message: "building…")
            TerminalStateView(state: .error, message: "exit 65")
        })
    }

    @Test func testPlayPauseButtonBothStates() {
        ViewHost.host(HStack {
            PlayPauseButton(isPaused: true) {}
            PlayPauseButton(isPaused: false) {}
        })
    }

    // MARK: Environment-dependent views (real AgentOrchestrator injected)

    @Test func testTerminalViewWithRealOutput() {
        let orchestrator = AgentOrchestrator()
        orchestrator.activeTerminalOutput = "plain\n\u{001B}[32mgreen line\u{001B}[0m\nafter"
        ViewHost.host(TerminalView().environment(orchestrator), pump: 0.15)
    }

    @Test func testTerminalViewEmpty() {
        let orchestrator = AgentOrchestrator()
        ViewHost.host(TerminalView().environment(orchestrator), pump: 0.1)
    }

    @Test func testPlanDashboardEmptyAndPopulated() {
        let orchestrator = AgentOrchestrator()
        ViewHost.host(PlanDashboardView().environment(orchestrator), pump: 0.1)

        orchestrator.updatePlan(steps: [
            PlanStep(title: "Audit", status: .completed, result: "done"),
            PlanStep(title: "Implement", status: .running),
            PlanStep(title: "Verify", status: .queued),
            PlanStep(title: "Ship", status: .failed, error: "CI red"),
        ])
        ViewHost.host(PlanDashboardView().environment(orchestrator), pump: 0.1)
    }

    @Test func testConfirmationOverlayRendersPendingRequest() {
        let orchestrator = AgentOrchestrator()
        orchestrator.pendingConfirmation = ConfirmationRequest(
            toolName: "write_file",
            arguments: #"{"path":"/tmp/x"}"#,
            riskDescription: "Writes a file to disk",
            oldContent: "old",
            newContent: "new",
            filePath: "/tmp/x",
            continuation: nil
        )
        ViewHost.host(ConfirmationOverlay().environment(orchestrator), pump: 0.2)
        // Clear so the overlay's countdown task ends with the host.
        orchestrator.pendingConfirmation = nil
    }

    @Test func testSidebarViewEmptyAndPopulated() {
        ViewHost.host(SidebarView(
            conversations: [],
            selectedConversation: nil,
            onSelectConversation: { _ in },
            onDeleteConversations: { _ in }
        ), pump: 0.1)

        let convo = Conversation(title: "Test chat")
        ViewHost.host(SidebarView(
            conversations: [convo],
            selectedConversation: convo,
            onSelectConversation: { _ in },
            onDeleteConversations: { _ in }
        ), pump: 0.1)
    }

    @Test func testDiagnosticsViewRuns() {
        ViewHost.host(DiagnosticsView(), pump: 0.4)
    }

    @Test func testQuickPromptViewRenders() {
        let orchestrator = AgentOrchestrator()
        ViewHost.host(QuickPromptView(panel: nil, orchestrator: orchestrator), pump: 0.1)
    }
}
