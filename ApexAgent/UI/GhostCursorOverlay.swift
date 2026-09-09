import SwiftUI
import AppKit

@Observable @MainActor
public final class GhostCursorController {
    public static let shared = GhostCursorController()
    private var overlayPanel: NSPanel?
    public var cursorPosition: CGPoint = .zero
    public var isVisible: Bool = false
    public var isClicking: Bool = false
    
    private var inactivityTask: Task<Void, Never>? = nil
    
    public init() {}
    
    public func showCursor(at point: CGPoint) {
        if overlayPanel == nil {
            var allScreensFrame: NSRect = .zero
            for screen in NSScreen.screens {
                allScreensFrame = allScreensFrame.union(screen.frame)
            }
            let newPanel = NSPanel(contentRect: allScreensFrame,
                                   styleMask: [.borderless],
                                   backing: .buffered,
                                   defer: false)
            newPanel.level = .screenSaver
            newPanel.ignoresMouseEvents = true
            newPanel.backgroundColor = .clear
            newPanel.isOpaque = false
            newPanel.hasShadow = false
            
            newPanel.contentView = NSHostingView(rootView: GhostCursorView())
            self.overlayPanel = newPanel
        }
        
        cursorPosition = point
        overlayPanel?.makeKeyAndOrderFront(nil)
        isVisible = true
        resetInactivityTimer()
    }
    
    public func animateClick() {
        isClicking = true
        resetInactivityTimer()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.isClicking = false
        }
    }
    
    private func resetInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard !Task.isCancelled else { return }
            self.hideCursor()
        }
    }
    
    public func hideCursor() {
        inactivityTask?.cancel()
        inactivityTask = nil
        overlayPanel?.orderOut(nil)
        isVisible = false
    }
}

public struct GhostCursorView: View {
    @State private var pulseScale: CGFloat = 1.0
    @State private var rippleScale: CGFloat = 0
    @State private var rippleOpacity: Double = 0
    
    public init() {}
    
    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
                .frame(width: 24, height: 24)
                .scaleEffect(pulseScale)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                        pulseScale = 1.2
                    }
                }
            
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
            
            if GhostCursorController.shared.isClicking {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 24)
                    .scaleEffect(rippleScale)
                    .opacity(rippleOpacity)
                    .onChange(of: GhostCursorController.shared.isClicking) { _, newValue in
                        if newValue {
                            withAnimation(.easeOut(duration: 0.4)) {
                                rippleScale = 2
                                rippleOpacity = 0
                            }
                        } else {
                            rippleScale = 0
                            rippleOpacity = 0.8
                        }
                    }
            }
        }
        .position(x: GhostCursorController.shared.cursorPosition.x, y: GhostCursorController.shared.cursorPosition.y)
    }
}
