import SwiftUI
import AppKit
import Carbon

private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@Observable @MainActor
public final class GlobalCommandPaletteController {
    public static let shared = GlobalCommandPaletteController()
    private var panel: NSPanel?
    private var eventHandler: EventHandlerRef?
    public var isVisible: Bool = false
    
    public func registerHotKey(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey)) {
        guard eventHandler == nil else { return }
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x41505852) // 'APXR'
        hotKeyID.id = 1
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        
        guard status == noErr else { return }
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in
                GlobalCommandPaletteController.shared.toggle()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }
    
    public func unregisterHotKey() {
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
    
    public func show() {
        if panel == nil {
            let newPanel = CommandPalettePanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 80),
                                               styleMask: [.nonactivatingPanel],
                                               backing: .buffered,
                                               defer: false)
            newPanel.level = .floating
            newPanel.backgroundColor = .clear
            newPanel.isOpaque = false
            newPanel.hasShadow = false
            newPanel.center()
            newPanel.contentView = NSHostingView(rootView: CommandPaletteView())
            self.panel = newPanel
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
    }
    
    public func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }
    
    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }
}

public struct CommandPaletteView: View {
    @State private var inputText: String = ""
    @State private var recentCommands: [String] = []
    public var onSubmit: ((String) -> Void)?
    
    private let suggestedBots = ["@DevOpsBot", "@CoderBot", "@ResearcherBot", "@ChiefOfStaffBot"]
    
    public init(onSubmit: ((String) -> Void)? = nil) {
        self.onSubmit = onSubmit
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Ask Apex or type @Bot...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .onSubmit {
                        dispatchCommand()
                    }
            }
            .padding()
            
            // Bot chips
            HStack(spacing: 8) {
                ForEach(suggestedBots, id: \.self) { bot in
                    Button(action: {
                        if !inputText.contains(bot) {
                            inputText = "\(bot) " + inputText
                        }
                    }) {
                        Text(bot)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            
            if !recentCommands.isEmpty {
                Divider()
                List(recentCommands.prefix(5), id: \.self) { cmd in
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(cmd)
                            .font(.body)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        inputText = cmd
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 120)
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(14)
        .shadow(radius: 10)
        .onKeyPress(.escape) {
            GlobalCommandPaletteController.shared.hide()
            return .handled
        }
    }
    
    private func dispatchCommand() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        if let customSubmit = onSubmit {
            customSubmit(text)
        } else if let delegate = NSApplication.shared.delegate as? AppDelegate {
            delegate.orchestrator.sendMessage(text)
        }
        
        if !recentCommands.contains(text) {
            recentCommands.insert(text, at: 0)
        }
        inputText = ""
        GlobalCommandPaletteController.shared.hide()
    }
}
