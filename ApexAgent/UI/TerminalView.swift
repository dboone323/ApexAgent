import SwiftUI

struct TerminalView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @State private var isPaused = false
    @State private var selectedEventID: UUID?
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {
            TerminalToolbar(
                isPaused: $isPaused,
                onCopy: copyAll,
                onClear: clearConsole,
                onReset: resetShell
            )

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    let segments = ANSIColorParser.parse(orchestrator.activeTerminalOutput)
                    if segments.isEmpty {
                        EmptyState(
                            icon: "terminal",
                            title: "Terminal Session Idle",
                            message: "zsh persistent console logs will output here in real-time.",
                            actionTitle: nil,
                            action: nil
                        )
                    } else {
                        formattedText(segments: segments)
                            .font(AppTheme.Font.mono(11))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("console_text_bottom")
                    }
                }
                .background(Color.black)
                .onChange(of: orchestrator.activeTerminalOutput) {
                    if !isPaused { proxy.scrollTo("console_text_bottom", anchor: .bottom) }
                }
                .onChange(of: isPaused) { _ in
                    if !isPaused { proxy.scrollTo("console_text_bottom", anchor: .bottom) }
                }
            }
        }
        .frame(minHeight: 220)
    }

    private func formattedText(segments: [StyledSegment]) -> Text {
        var combined = Text("")
        for segment in segments {
            var color = segment.foregroundColor
            if color == .black { color = .gray }
            else if color == .primary { color = .white }
            var text = Text(segment.text).foregroundColor(color)
            if segment.isBold { text = text.bold() }
            combined = combined + text
        }
        return combined
    }

    private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(orchestrator.activeTerminalOutput, forType: .string)
    }

    private func clearConsole() {
        guard let conversationId = orchestrator.currentConversation?.id else { return }
        orchestrator.terminalOutputs[conversationId] = ""
        orchestrator.activeTerminalOutput = ""
    }

    private func resetShell() {
        guard let conversationId = orchestrator.currentConversation?.id else { return }
        Task {
            await orchestrator.resetPTYSession(for: conversationId)
        }
    }
}
