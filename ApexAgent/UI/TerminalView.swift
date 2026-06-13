import SwiftUI

struct TerminalView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    
    var body: some View {
        VStack(spacing: 0) {
            // Terminal Toolbar Header
            HStack(spacing: 12) {
                Label("Terminal Console", systemImage: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button(action: copyAll) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                
                Button(action: clearConsole) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                
                if let conversation = orchestrator.currentConversation {
                    Button(action: { orchestrator.resetPTYSession(for: conversation.id) }) {
                        Label("Reset Shell", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Console text area
            ScrollViewReader { proxy in
                ScrollView {
                    let segments = ANSIColorParser.parse(orchestrator.activeTerminalOutput)
                    
                    if segments.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "terminal")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                            Text("Terminal Session Idle")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("zsh persistent console logs will output here in real-time.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                    } else {
                        formattedText(segments: segments)
                            .font(.system(size: 11, design: .monospaced))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id("console_text_bottom")
                    }
                }
                .background(Color.black)
                .onChange(of: orchestrator.activeTerminalOutput) {
                    proxy.scrollTo("console_text_bottom", anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 140)
    }
    
    private func formattedText(segments: [StyledSegment]) -> Text {
        var combined = Text("")
        for segment in segments {
            // Map standard black/dark colors to bright colors for readability on black background
            var color = segment.foregroundColor
            if color == .black {
                color = .gray
            } else if color == .primary {
                color = .white
            }
            
            var text = Text(segment.text)
                .foregroundColor(color)
            if segment.isBold {
                text = text.bold()
            }
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
}
