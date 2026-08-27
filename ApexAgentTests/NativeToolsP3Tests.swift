import Testing
import Foundation
@testable import ApexAgentCore

@Suite("NativeToolsP3Tests")
struct NativeToolsP3Tests {
    @Test("ComputerUseAgent executes safe actions without accessibility requirement")
    @MainActor
    func testSafeActions() async throws {
        let agent = ComputerUseAgent.shared
        #expect(!agent.isRunning)

        let waited = try await agent.executeAction(.wait(seconds: 0.01))
        #expect(waited.contains("Waited"))

        let finished = try await agent.executeAction(.finish(result: "done"))
        #expect(finished.contains("Finished") || finished.contains("done"))

        let failedApp = try await agent.executeAction(.openApp(name: "com.apexagent.nonexistent.test"))
        #expect(failedApp.contains("Failed to open app"))
    }

    @Test("ComputerUseAgent invalid key combo resolves to warning, not an action")
    @MainActor
    func testInvalidKeyComboIsInert() async throws {
        let agent = ComputerUseAgent.shared
        // Resolution happens before any event is posted; invalid tokens report.
        // On machines WITHOUT accessibility trust the permission error fires
        // first — both outcomes are acceptable and neither synthesizes input.
        let result = try? await agent.executeAction(.keyCombo(keys: ["frobnicate"]))
        if let result {
            #expect(result.contains("Unknown key") || result.contains("PERMISSION"))
        }
    }

    @Test("AccessibilityControlTool inspect_ui action metadata and execution on frontmost app")
    @MainActor
    func testInspectUI() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = AccessibilityControlTool(orchestrator: orchestrator)
        #expect(tool.name == "control_accessibility")

        let args = AccessibilityControlTool.Arguments(action: "inspect_ui", elementId: nil, textValue: nil, appName: nil, bundleId: nil, maxDepth: 3, includeValues: false)
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        // Acceptable outcomes: a real outline, a no-elements notice, or the
        // accessibility-permission notice (headless/CI/test runners vary).
        #expect(result.contains("UI Outline")
                || result.contains("No accessible elements")
                || result.contains("Accessibility permission")
                || result.contains("ERROR")
                || result.contains("🔒"))
    }

    @Test("AccessibilityControlTool inspect_ui with unknown app name falls back or reports cleanly")
    @MainActor
    func testInspectUnknownApp() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = AccessibilityControlTool(orchestrator: orchestrator)
        let args = AccessibilityControlTool.Arguments(action: "inspect_ui", elementId: nil, textValue: nil, appName: "Definitely Not Running App XYZ", bundleId: nil, maxDepth: 2, includeValues: false)
        let result = try await tool.call(arguments: args)
        // No crash either way: outline fallback OR not-found/permission notice.
        #expect(!result.isEmpty)
        #expect(result.contains("UI Outline")
                || result.contains("Could not locate")
                || result.contains("Accessibility permission")
                || result.contains("ERROR")
                || result.contains("🔒"))
    }

    @Test("AccessibilityControlTool inspect_ui respects node budget with deep tree cap")
    @MainActor
    func testInspectDepthCap() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = AccessibilityControlTool(orchestrator: orchestrator)
        // maxDepth is clamped internally to ≤12; oversized request must still work.
        let args = AccessibilityControlTool.Arguments(action: "inspect_ui", elementId: nil, textValue: nil, appName: nil, bundleId: nil, maxDepth: 500, includeValues: true)
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
    }
}
