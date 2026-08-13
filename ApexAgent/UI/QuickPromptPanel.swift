import SwiftUI

class QuickPromptPanel: NSPanel {
    init(orchestrator: AgentOrchestrator) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 60),
            styleMask: [.nonactivatingPanel, .hudWindow, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        self.level = .floating
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.hasShadow = true
        
        let effectView = NSVisualEffectView()
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.material = .hudWindow
        
        let contentView = QuickPromptView(panel: self, orchestrator: orchestrator)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = effectView.bounds
        hostingView.autoresizingMask = [.width, .height]
        effectView.addSubview(hostingView)
        
        self.contentView = effectView
        self.center()
    }
    
    override var canBecomeKey: Bool {
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
    }
}

struct QuickPromptView: View {
    weak var panel: NSPanel?
    let orchestrator: AgentOrchestrator
    @State private var text = ""
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.Palette.accent)
            
            TextField("Ask Apex anything...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isInputFocused)
                .onSubmit {
                    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !prompt.isEmpty else { return }
                    text = ""
                    panel?.orderOut(nil)
                    
                    // Send query to agent
                    orchestrator.sendMessage(prompt)
                    
                    // Show main window to display output progress
                    if let mainWindow = NSApplication.shared.windows.first(where: { !$0.isKind(of: NSPanel.self) }) {
                        mainWindow.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            
            Button {
                panel?.orderOut(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear {
            isInputFocused = true
        }
    }
}
