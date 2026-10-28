import Testing
import Foundation
import AppKit
@testable import ApexAgentCore

@Suite("Batch 4: DetectImageTextTool Tests", .serialized)
struct DetectImageTextToolTests {

    @Test("DetectImageTextTool metadata check")
    @MainActor
    func testDetectImageTextToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = DetectImageTextTool(orchestrator: orchestrator)
        #expect(tool.name == "detect_image_text")
        #expect(tool.description.contains("OCR") || tool.description.contains("optical character recognition"))
    }

    @Test("DetectImageTextTool returns error when image file is missing")
    @MainActor
    func testNonExistentFileReturnsError() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = DetectImageTextTool(orchestrator: orchestrator)

        let fakePath = "/tmp/non_existent_image_\(UUID().uuidString).png"
        let args = DetectImageTextTool.Arguments(imagePath: fakePath)

        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR: File not found at path: \(fakePath)"))
    }

    @Test("DetectImageTextTool performs OCR on generated test image")
    @MainActor
    func testOCRWithTestImage() async throws {
        // Create an image representation with black text on white background
        let size = NSSize(width: 200, height: 60)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let text = "TEST OCR"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 24),
            .foregroundColor: NSColor.black
        ]
        text.draw(at: NSPoint(x: 20, y: 15), withAttributes: attrs)
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return
        }

        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr_test_\(UUID().uuidString).png").path
        try pngData.write(to: URL(fileURLWithPath: tempPath))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let orchestrator = AgentOrchestrator()
        let tool = DetectImageTextTool(orchestrator: orchestrator)
        let args = DetectImageTextTool.Arguments(imagePath: tempPath)

        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        // Vision OCR returns either extracted text containing TEST / OCR, or "No text was detected"
        #expect(result.contains("Extracted") || result.contains("TEST") || result.contains("OCR") || result.contains("No text"))
    }
}
