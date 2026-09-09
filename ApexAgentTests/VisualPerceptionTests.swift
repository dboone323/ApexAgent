import XCTest
import AppKit
import CoreGraphics
import Vision
@testable import ApexAgentCore

@MainActor
final class VisualPerceptionTests: XCTestCase {

    /// Helper to synthesize a real CGImage containing rendered text.
    private func createTestImage(withText text: String, width: Int = 400, height: Int = 200) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // Draw white background
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw black text via CoreGraphics / CTFont
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)

        context.textPosition = CGPoint(x: 20, y: height / 2)
        CTLineDraw(line, context)

        return context.makeImage()
    }

    func testVisualBoundingBoxToDisplayRectConversion() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Normalized Vision box: origin at (0.1, 0.2), size (0.5, 0.3)
        // Vision origin is bottom-left.
        let box = VisualBoundingBox(x: 0.1, y: 0.2, width: 0.5, height: 0.3, label: "Alert", confidence: 0.95)
        let displayRect = box.toDisplayRect(displayBounds: displayBounds)

        XCTAssertEqual(displayRect.origin.x, 192.0, accuracy: 0.01)
        // AppKit top-left Y: (1.0 - 0.2 - 0.3) * 1080 = 0.5 * 1080 = 540.0
        XCTAssertEqual(displayRect.origin.y, 540.0, accuracy: 0.01)
        XCTAssertEqual(displayRect.width, 960.0, accuracy: 0.01)
        XCTAssertEqual(displayRect.height, 324.0, accuracy: 0.01)
        XCTAssertEqual(box.label, "Alert")
        XCTAssertEqual(box.confidence, 0.95, accuracy: 0.001)
    }

    func testTextClassificationCategories() {
        XCTAssertEqual(
            VisualPerceptionObserver.classifyTextContent("fatal error: index out of range"),
            .terminalPanic
        )
        XCTAssertEqual(
            VisualPerceptionObserver.classifyTextContent("error: Build failed in AppDelegate.swift:42"),
            .buildFailure
        )
        XCTAssertEqual(
            VisualPerceptionObserver.classifyTextContent("An error occurred while saving the file"),
            .errorDialog
        )
        XCTAssertEqual(
            VisualPerceptionObserver.classifyTextContent("Notification: Would you like to proceed?"),
            .promptNotification
        )
        XCTAssertEqual(
            VisualPerceptionObserver.classifyTextContent("Normal user text on document"),
            .generalInfo
        )
    }

    func testRealVisionTextRecognitionOnSynthesizedImage() async {
        guard let testImage = createTestImage(withText: "Build Failed") else {
            XCTFail("Failed to synthesize test CGImage")
            return
        }

        let findings = await VisualPerceptionObserver.analyzeCGImage(testImage)
        XCTAssertFalse(findings.isEmpty, "Vision should detect rendered text in CGImage")

        if let firstFinding = findings.first {
            XCTAssertTrue(firstFinding.detectedText.localizedCaseInsensitiveContains("Build") ||
                          firstFinding.detectedText.localizedCaseInsensitiveContains("Failed"),
                          "Detected text should contain synthesized words: \(firstFinding.detectedText)")
            XCTAssertFalse(firstFinding.boundingBoxes.isEmpty)
        }
    }

    /// Shared orchestrator to avoid MCP client lifecycle collisions when multiple
    /// orchestrators initialise/teardown concurrently in the same test process.
    private static let sharedOrchestrator = AgentOrchestrator()

    func testScreenPerceptionToolListDisplays() async throws {
        let tool = ScreenPerceptionTool(orchestrator: Self.sharedOrchestrator)
        let args = ScreenPerceptionTool.Arguments(action: "list_displays")

        let result = try await tool.call(arguments: args)
        XCTAssertTrue(result.contains("Active Displays:"), "Tool should return list of active displays")
    }

    func testScreenPerceptionToolHighlightRegion() async throws {
        let tool = ScreenPerceptionTool(orchestrator: Self.sharedOrchestrator)
        let args = ScreenPerceptionTool.Arguments(
            action: "highlight_region",
            highlightX: 0.1,
            highlightY: 0.2,
            highlightWidth: 0.3,
            highlightHeight: 0.4
        )

        let result = try await tool.call(arguments: args)
        XCTAssertTrue(result.contains("Highlighted screen region:"), "Tool should report highlight action output")
        ScreenHighlightOverlayController.shared.dismiss()
    }

    func testVisualPerceptionObserverLifecycle() async {
        let observer = VisualPerceptionObserver.shared
        XCTAssertFalse(observer.isObserving)

        observer.startObserving(intervalSeconds: 10.0)
        XCTAssertTrue(observer.isObserving)

        observer.stopObserving()
        XCTAssertFalse(observer.isObserving)
    }
}
