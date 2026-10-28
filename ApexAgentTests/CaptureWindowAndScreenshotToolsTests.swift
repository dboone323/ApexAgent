import Testing
import Foundation
import CoreGraphics
@testable import ApexAgentCore

@Suite("Batch 3: CaptureWindowAndScreenshotTools Tests", .serialized)
struct CaptureWindowAndScreenshotToolsTests {

    // MARK: - CaptureWindowImageTool Tests

    @Test("CaptureWindowImageTool metadata check")
    @MainActor
    func testCaptureWindowImageToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = CaptureWindowImageTool(orchestrator: orchestrator)
        #expect(tool.name == "capture_window_image")
        #expect(tool.description.contains("Captures an application window"))
    }

    @Test("CaptureWindowImageTool handles non-existent or invalid window ID gracefully")
    @MainActor
    func testCaptureWindowImageToolInvalidWindowID() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = CaptureWindowImageTool(orchestrator: orchestrator)

        // Pass a synthetic non-existent window ID
        let args = CaptureWindowImageTool.Arguments(appName: nil, windowID: 99999999)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR:") || result.contains("Failed to capture") || result.contains("No matching window"))
    }

    @Test("CaptureWindowImageTool handles empty / non-matching app name gracefully")
    @MainActor
    func testCaptureWindowImageToolNonMatchingAppName() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = CaptureWindowImageTool(orchestrator: orchestrator)

        let args = CaptureWindowImageTool.Arguments(appName: "NonExistentApplication_XYZ_123", windowID: nil)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR: No matching window found") || result.contains("ERROR:"))
    }

    // MARK: - ScreenshotTool Tests

    @Test("ScreenshotTool metadata check")
    @MainActor
    func testScreenshotToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = ScreenshotTool(orchestrator: orchestrator)
        #expect(tool.name == "take_screenshot")
        #expect(tool.description.contains("screenshot"))
    }

    @Test("ScreenshotTool executes argument parsing and checks screen capture permissions")
    @MainActor
    func testScreenshotToolPermissionOrExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = ScreenshotTool(orchestrator: orchestrator)

        let tempSavePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_screenshot_\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: tempSavePath) }

        let args = ScreenshotTool.Arguments(savePath: tempSavePath, windowOnly: false, fast: true)
        let result = try await tool.call(arguments: args)

        #expect(!result.isEmpty)
        // In headless or test environments where screen recording permission is not granted,
        // it must return the descriptive TCC guidance error rather than crashing or throwing unhandled errors.
        if !CGPreflightScreenCaptureAccess() {
            #expect(result.contains("ERROR: Screen Recording is not permitted by macOS"))
        } else {
            #expect(result.contains("Screenshot captured") || result.contains("SUCCESS") || result.contains(tempSavePath))
        }
    }
}
