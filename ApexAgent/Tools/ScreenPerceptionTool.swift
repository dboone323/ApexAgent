import Foundation
import FoundationModels
import AppKit
import Vision
import CoreGraphics
import ScreenCaptureKit

// MARK: - ScreenPerceptionTool

struct ScreenPerceptionTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "screen_perception"
    public let description = """
    Inspect current screen visual context, extract on-screen UI text, identify error dialogs/compiler failures, and highlight bounding boxes on displays.
    """

    @Generable
    public struct Arguments: Decodable {
        @Guide(description: "Action to perform: 'capture_and_analyze', 'list_displays', or 'highlight_region'. Defaults to 'capture_and_analyze'.")
        public var action: String?

        @Guide(description: "Normalized X coordinate [0..1] for highlight_region")
        public var highlightX: Double?

        @Guide(description: "Normalized Y coordinate [0..1] for highlight_region")
        public var highlightY: Double?

        @Guide(description: "Normalized width [0..1] for highlight_region")
        public var highlightWidth: Double?

        @Guide(description: "Normalized height [0..1] for highlight_region")
        public var highlightHeight: Double?

        public init(
            action: String? = "capture_and_analyze",
            highlightX: Double? = nil,
            highlightY: Double? = nil,
            highlightWidth: Double? = nil,
            highlightHeight: Double? = nil
        ) {
            self.action = action
            self.highlightX = highlightX
            self.highlightY = highlightY
            self.highlightWidth = highlightWidth
            self.highlightHeight = highlightHeight
        }
    }

    public func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let action = arguments.action ?? "capture_and_analyze"

            switch action {
            case "list_displays":
                let screens = await MainActor.run {
                    NSScreen.screens.enumerated().map { index, screen in
                        "Display \(index): frame=\(screen.frame), visibleFrame=\(screen.visibleFrame), scale=\(screen.backingScaleFactor)"
                    }.joined(separator: "\n")
                }
                return "Active Displays:\n\(screens)"

            case "highlight_region":
                guard let x = arguments.highlightX, let y = arguments.highlightY,
                      let w = arguments.highlightWidth, let h = arguments.highlightHeight else {
                    return "Error: highlight_region requires highlightX, highlightY, highlightWidth, highlightHeight."
                }

                let mainFrame = await MainActor.run { NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080) }
                let box = VisualBoundingBox(x: x, y: y, width: w, height: h, label: "Target", confidence: 1.0)
                let displayRect = box.toDisplayRect(displayBounds: mainFrame)

                await MainActor.run {
                    ScreenHighlightOverlayController.shared.highlightRects([displayRect])
                }
                return "Highlighted screen region: \(displayRect) on display bounds \(mainFrame)"

            case "capture_and_analyze":
                fallthrough
            default:
                let streamer = await MainActor.run { ScreenStreamer.shared }
                var cgImage: CGImage? = await MainActor.run {
                    streamer.circularBuffer.last?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }

                if cgImage == nil {
                    // Fallback to screencapture CLI
                    let tempPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("apex_perception_probe.png")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", tempPath]
                    try? process.run()
                    process.waitUntilExit()

                    if let image = NSImage(contentsOfFile: tempPath),
                       let img = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        cgImage = img
                    }
                    try? FileManager.default.removeItem(atPath: tempPath)
                }

                guard let image = cgImage else {
                    return "No screen capture available (verify Screen Recording permissions in System Settings)."
                }

                let findings = await VisualPerceptionObserver.analyzeCGImage(image)
                if findings.isEmpty {
                    return "Visual perception pass completed. No significant UI text or error alerts detected on screen."
                }

                let output = findings.map { finding in
                    var text = "Category: \(finding.category.rawValue)\n"
                    if let suggestion = finding.suggestion {
                        text += "Suggestion: \(suggestion)\n"
                    }
                    text += "Detected Text:\n\(finding.detectedText)\n"
                    text += "Bounding Boxes Count: \(finding.boundingBoxes.count)"
                    return text
                }.joined(separator: "\n---\n")

                return "Visual Perception Results:\n\(output)"
            }
        }
    }
}
