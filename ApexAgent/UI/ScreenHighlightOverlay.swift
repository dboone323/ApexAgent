import SwiftUI
import AppKit

// MARK: - ScreenHighlightOverlayController

@MainActor
public final class ScreenHighlightOverlayController {
    public static let shared = ScreenHighlightOverlayController()

    private var overlayWindows: [NSWindow] = []

    public init() {}

    /// Displays temporary visual bounding box overlays on screen for a specified duration.
    public func highlightRects(_ rects: [CGRect], on displayBounds: CGRect? = nil, duration: TimeInterval = 4.0) {
        dismiss()

        for (index, rect) in rects.enumerated() {
            createOverlayWindow(
                rect: rect,
                view: BoundingBoxOverlayView(boxNumber: index + 1)
            )
        }

        scheduleDismiss(after: duration)
    }

    /// Displays ordered sequence badges with step callouts (e.g. for multi-turn computer use guidance).
    public func highlightSequence(
        _ steps: [(rect: CGRect, label: String, stepNumber: Int)],
        duration: TimeInterval = 4.0
    ) {
        dismiss()

        for step in steps {
            createOverlayWindow(
                rect: step.rect,
                view: BoundingBoxOverlayView(
                    boxNumber: step.stepNumber,
                    label: step.label,
                    actionTitle: "Step \(step.stepNumber): \(step.label)"
                )
            )
        }

        scheduleDismiss(after: duration)
    }

    private func createOverlayWindow<V: View>(rect: CGRect, view: V) {
        let isTesting = getenv("APEX_TEST_MODE") != nil
            || ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("xctest")
            || NSClassFromString("XCTestCase") != nil
        if isTesting {
            return
        }

        let window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let contentView = NSHostingView(rootView: view)
        window.contentView = contentView
        window.orderFrontRegardless()
        overlayWindows.append(window)
    }

    private func scheduleDismiss(after duration: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self.dismiss()
        }
    }

    public func dismiss() {
        for window in overlayWindows {
            window.close()
        }
        overlayWindows.removeAll()
    }
}

// MARK: - BoundingBoxOverlayView

public struct BoundingBoxOverlayView: View {
    public let boxNumber: Int
    public let label: String?
    public let actionTitle: String?

    public init(boxNumber: Int, label: String? = nil, actionTitle: String? = nil) {
        self.boxNumber = boxNumber
        self.label = label
        self.actionTitle = actionTitle
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.5, dash: [6, 3])
                )
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                )

            HStack(spacing: 4) {
                Text("#\(boxNumber)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                if let actionTitle = actionTitle ?? label {
                    Text(actionTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(3)
        }
    }
}
