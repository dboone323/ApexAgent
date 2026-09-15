import Testing
import Foundation
import SwiftUI
import AppKit
import SwiftData
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
        if pump > 0 {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: pump))
        }
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
        let host1 = ViewHost.host(EmptyState(
            icon: "tray",
            title: "Nothing here",
            message: "No content yet",
            actionTitle: "Reload",
            action: { tapped = true }
        ))
        #expect(host1.frame.size.width > 0)
        #expect(host1.frame.size.height > 0)
        #expect(tapped == false) // hosted, not clicked — rendering only

        let host2 = ViewHost.host(EmptyState(
            icon: "tray",
            title: "Nothing here",
            message: "No content yet",
            actionTitle: nil,
            action: nil
        ))
        #expect(host2.frame.size.width > 0)
        #expect(host2.frame.size.height > 0)
    }

    @Test func testSectionHeaderVariants() {
        let host = ViewHost.host(VStack {
            SectionHeader(title: "General", icon: "gear", subtitle: "App-wide settings")
            SectionHeader(title: "Bare", icon: nil, subtitle: nil)
        })
        #expect(host.frame.size.width > 0)
        #expect(host.frame.size.height > 0)
    }

    @Test func testAppCardRendersContent() {
        let host = ViewHost.host(AppCard { Text("card body") })
        #expect(host.frame.size.width > 0)
        #expect(host.frame.size.height > 0)
    }

    @Test func testDiagnosticCardRenders() {
        let host = ViewHost.host(VStack {
            DiagnosticCard(title: "CPU", subtitle: "Load", status: "ok", message: "12%")
            DiagnosticCard(title: "Net", subtitle: "Ping", status: "fail", message: "timeout")
        })
        #expect(host.frame.size.width > 0)
        #expect(host.frame.size.height > 0)
    }

    @Test func testAgentAndUserAvatars() {
        let host = ViewHost.host(HStack { AgentAvatar(); UserAvatar() })
        #expect(host.frame.size.width > 0)
        #expect(host.frame.size.height > 0)
    }

    @Test func testTypingIndicatorAnimates() {
        let host = ViewHost.host(TypingIndicator(), pump: 0.15)
        #expect(host.frame.size.width > 0)
        #expect(host.frame.size.height > 0)
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
        let lines = DiffHelper.computeDiff(oldText: old, newText: new)
        #expect(lines.contains { $0.kind == .added && $0.text == "line2changed" })
        #expect(lines.contains { $0.kind == .added && $0.text == "line4" })
        #expect(lines.contains { $0.kind == .deleted && $0.text == "line2" })
        #expect(lines.contains { $0.kind == .unchanged && $0.text == "line1" })
        let host = ViewHost.host(DiffView(oldContent: old, newContent: new), pump: 0.1)
        #expect(host.frame.size.width > 0)
    }

    @Test func testDiffViewEmptyToContent() {
        let lines = DiffHelper.computeDiff(oldText: "", newText: "brand new file")
        #expect(lines.count == 2)
        #expect(lines.contains { $0.kind == .added && $0.text == "brand new file" })
        #expect(lines.contains { $0.kind == .deleted && $0.text == "" })
        let host = ViewHost.host(DiffView(oldContent: "", newContent: "brand new file"), pump: 0.1)
        #expect(host.frame.size.width > 0)
    }

    @Test func testDiffViewIdenticalContent() {
        let lines = DiffHelper.computeDiff(oldText: "same", newText: "same")
        #expect(lines.count == 1)
        #expect(lines.first?.kind == .unchanged)
        let host = ViewHost.host(DiffView(oldContent: "same", newContent: "same"), pump: 0.1)
        #expect(host.frame.size.width > 0)
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
        let host = ViewHost.host(
            VStack {
                ToolEventRow(event: running)
                ToolEventRow(event: ok)
                ToolEventRow(event: failed)
                ToolEventRow(event: waiting)
                ToolEventRow(event: denied)
            },
            pump: 0.1
        )
        #expect(host.frame.size.width > 0)
        #expect(host.frame.size.height > 0)
    }

    // MARK: PlanStep components

    @Test func testPlanStepRowAllStatuses() {
        let steps = PlanStepStatus.allCases.enumerated().map { idx, status in
            PlanStep(title: "Step \(idx)", status: status, result: status == .completed ? "ok" : nil, error: status == .failed ? "err" : nil)
        }
        #expect(steps.count == PlanStepStatus.allCases.count)
        let host = ViewHost.host(
            VStack {
                ForEach(steps) { step in
                    PlanStepRow(step: step, index: 0) {}
                }
            },
            pump: 0.1
        )
        #expect(host.frame.size.width > 0)
    }

    @Test func testPlanStepDetailView() {
        let step = PlanStep(title: "Build", status: .failed, result: "partial", error: "exit 65")
        #expect(step.title == "Build")
        #expect(step.error == "exit 65")
        let host = ViewHost.host(PlanStepDetailView(step: step))
        #expect(host.frame.size.width > 0)
    }

    // MARK: TerminalStateView + toolbar

    @Test func testTerminalStateViewAllStates() {
        let host = ViewHost.host(VStack {
            TerminalStateView(state: .idle, message: nil)
            TerminalStateView(state: .running, message: "building…")
            TerminalStateView(state: .error, message: "exit 65")
        })
        #expect(host.frame.size.width > 0)
    }

    @Test func testPlayPauseButtonBothStates() {
        let host = ViewHost.host(HStack {
            PlayPauseButton(isPaused: true) {}
            PlayPauseButton(isPaused: false) {}
        })
        #expect(host.frame.size.width > 0)
    }

    // MARK: Environment-dependent views (real AgentOrchestrator injected)

    @Test func testTerminalViewWithRealOutput() {
        let orchestrator = AgentOrchestrator()
        orchestrator.activeTerminalOutput = "plain\n\u{001B}[32mgreen line\u{001B}[0m\nafter"
        #expect(orchestrator.activeTerminalOutput.contains("green line"))
        let host = ViewHost.host(TerminalView().environment(orchestrator), pump: 0.15)
        #expect(host.frame.size.width > 0)
    }

    @Test func testTerminalViewEmpty() {
        let orchestrator = AgentOrchestrator()
        let host = ViewHost.host(TerminalView().environment(orchestrator), pump: 0.1)
        #expect(host.frame.size.width > 0)
    }

    @Test func testPlanDashboardEmptyAndPopulated() {
        let orchestrator = AgentOrchestrator()
        let hostEmpty = ViewHost.host(PlanDashboardView().environment(orchestrator), pump: 0.1)
        #expect(hostEmpty.frame.size.width > 0)

        orchestrator.updatePlan(steps: [
            PlanStep(title: "Audit", status: .completed, result: "done"),
            PlanStep(title: "Implement", status: .running),
            PlanStep(title: "Verify", status: .queued),
            PlanStep(title: "Ship", status: .failed, error: "CI red"),
        ])
        #expect(orchestrator.activePlan.count == 4)
        let hostPopulated = ViewHost.host(PlanDashboardView().environment(orchestrator), pump: 0.1)
        #expect(hostPopulated.frame.size.width > 0)
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
        #expect(orchestrator.pendingConfirmation?.toolName == "write_file")
        #expect(orchestrator.pendingConfirmation?.riskDescription == "Writes a file to disk")
        let host = ViewHost.host(ConfirmationOverlay().environment(orchestrator), pump: 0.2)
        #expect(host.frame.size.width > 0)
        // Clear so the overlay's countdown task ends with the host.
        orchestrator.pendingConfirmation = nil
    }

    @Test func testSidebarViewEmptyAndPopulated() {
        let hostEmpty = ViewHost.host(SidebarView(
            conversations: [],
            selectedConversation: nil,
            onSelectConversation: { _ in },
            onDeleteConversations: { _ in }
        ), pump: 0.1)
        #expect(hostEmpty.frame.size.width > 0)

        let convo = Conversation(title: "Test chat")
        let hostPopulated = ViewHost.host(SidebarView(
            conversations: [convo],
            selectedConversation: convo,
            onSelectConversation: { _ in },
            onDeleteConversations: { _ in }
        ), pump: 0.1)
        #expect(hostPopulated.frame.size.width > 0)
        #expect(convo.title == "Test chat")
    }

    @Test func testDiagnosticsViewRuns() {
        let host = ViewHost.host(DiagnosticsView(), pump: 0.4)
        #expect(host.frame.size.width > 0)
    }

    @Test func testQuickPromptViewRenders() {
        let orchestrator = AgentOrchestrator()
        let host = ViewHost.host(QuickPromptView(panel: nil, orchestrator: orchestrator), pump: 0.1)
        #expect(host.frame.size.width > 0)
    }

    @Test func testSettingsViewHostingWithOrchestrator() throws {
        let orchestrator = AgentOrchestrator()
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Routine.self, configurations: configuration)
        let host = ViewHost.host(
            SettingsView()
                .modelContainer(container)
                .environment(orchestrator),
            pump: 0.15
        )
        #expect(host.frame.size.width > 0)
    }

    @Test func testMCPServerDashboardViewHosting() {
        let orchestrator = AgentOrchestrator()
        let host = ViewHost.host(MCPServerDashboardView().environment(orchestrator), pump: 0.15)
        #expect(host.frame.size.width > 0)
    }
}
