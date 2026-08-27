import Testing
import Foundation
@testable import ApexAgentCore

@Suite("BrowserAndDaemonTests") @MainActor
struct BrowserAndDaemonTests {

    @Test func testBrowserAutomationArgumentParsing() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = BrowserAutomationTool(orchestrator: orchestrator)
        
        #expect(tool.name == "control_browser")
        #expect(tool.description.contains("WebKit-based"))

        // Clear session action
        let clearResult = try await tool.call(arguments: BrowserAutomationTool.Arguments(action: "clear_session"))
        #expect(clearResult.contains("cleared"))

        // Error for missing URL
        let missingUrl = try await tool.call(arguments: BrowserAutomationTool.Arguments(action: "open_url"))
        #expect(missingUrl.contains("ERROR: url is required"))

        // Error for missing script
        let missingScript = try await tool.call(arguments: BrowserAutomationTool.Arguments(action: "evaluate_script"))
        #expect(missingScript.contains("ERROR: textValue containing JavaScript is required"))

        // Unknown action
        let unknownAction = try await tool.call(arguments: BrowserAutomationTool.Arguments(action: "invalid_action"))
        #expect(unknownAction.contains("ERROR: Unknown action"))
    }

    @Test func testLaunchAgentConfigAndPlistGeneration() {
        let config = LaunchAgentConfig(
            label: "com.apexagent.testdaemon",
            programPath: "/usr/local/bin/ApexAgent",
            arguments: ["--daemon", "--port", "8800"],
            runAtLoad: true,
            keepAlive: true
        )
        let xml = LaunchAgentPlist.xml(for: config)
        #expect(xml.contains("<string>com.apexagent.testdaemon</string>"))
        #expect(xml.contains("<string>/usr/local/bin/ApexAgent</string>"))
        #expect(xml.contains("<string>--daemon</string>"))
        #expect(xml.contains("<string>--port</string>"))
        #expect(xml.contains("<string>8800</string>"))
        #expect(xml.contains("<true/>"))
    }

    @Test func testLaunchAgentControllerLifecycle() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        LaunchAgentController.agentsDirectory = tempDir
        let controller = LaunchAgentController(label: "com.apexagent.mockdaemon")

        #expect(!controller.isInstalled)

        try controller.install(programPath: "/path/to/mock", arguments: ["--daemon"])
        #expect(controller.isInstalled)
        #expect(FileManager.default.fileExists(atPath: controller.plistURL.path))

        try controller.uninstall()
        #expect(!controller.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: controller.plistURL.path))
    }
}
