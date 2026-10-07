import SwiftUI
import AppKit

@Observable @MainActor
public final class GhostCursorController {
    public static let shared = GhostCursorController()
    private var overlayPanel: NSPanel?
    public var cursorPosition: CGPoint = .zero
    public var isVisible: Bool = false
    public var isClicking: Bool = false
    
    private var inactivityTask: Task<Void, Never>?
    
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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private let reduceMotionOverride: Bool?
    @State private var pulseScale: CGFloat = 1.0
    @State private var rippleScale: CGFloat = 0
    @State private var rippleOpacity: Double = 0

    public init(reduceMotion: Bool? = nil) {
        self.reduceMotionOverride = reduceMotion
    }

    public var effectiveReduceMotion: Bool {
        reduceMotionOverride ?? accessibilityReduceMotion
    }

    public static func pulseAnimationEnabled(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    public static func clickRippleScale(isClicking: Bool, reduceMotion: Bool) -> CGFloat {
        guard isClicking else { return 1.0 }
        return reduceMotion ? 1.3 : 2.0
    }

    public var accessibilityLabelText: String {
        GhostCursorController.shared.isClicking ? "Agent cursor clicking" : "Agent cursor"
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
                .frame(width: 24, height: 24)
                .scaleEffect(effectiveReduceMotion ? 1.0 : pulseScale)
                .onAppear {
                    guard Self.pulseAnimationEnabled(reduceMotion: effectiveReduceMotion) else {
                        pulseScale = 1.0
                        return
                    }
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
                    .scaleEffect(
                        effectiveReduceMotion
                            ? Self.clickRippleScale(isClicking: true, reduceMotion: true)
                            : rippleScale
                    )
                    .opacity(effectiveReduceMotion ? 0.85 : rippleOpacity)
                    .onChange(of: GhostCursorController.shared.isClicking) { _, newValue in
                        guard !effectiveReduceMotion else { return }
                        if newValue {
                            withAnimation(.easeOut(duration: 0.4)) {
                                rippleScale = Self.clickRippleScale(isClicking: true, reduceMotion: false)
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
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("ghostCursorOverlay")
        .accessibilityLabel(accessibilityLabelText)
    }
}

