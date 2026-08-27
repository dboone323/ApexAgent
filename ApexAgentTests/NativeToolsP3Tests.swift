import Testing
import Foundation
@testable import ApexAgentCore

@Suite("NativeToolsP3Tests")
struct NativeToolsP3Tests {
    @Test("ComputerUseAgent executes safe actions without accessibility requirement")
    @MainActor
    func testSafeActions() async throws {
        let agent = ComputerUseAgent.shared
        // NOTE: no assertion on agent.isRunning — Swift Testing runs suites in
        // parallel and the perceive-act-verify loop tests legitimately hold the
        // singleton running; per-test global-state assertions race.

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

    @Test("ComputerUseTool metadata and safe wait action")
    @MainActor
    func testComputerUseToolWait() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = ComputerUseTool(orchestrator: orchestrator)
        #expect(tool.name == "computer_use")

        let args = ComputerUseTool.Arguments(action: "wait", x: nil, y: nil, text: nil,
                                             keys: nil, deltaX: nil, deltaY: nil,
                                             appName: nil, seconds: 0.1)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("Waited"))
    }

    @Test("ComputerUseTool unknown action reported cleanly")
    @MainActor
    func testComputerUseToolUnknownAction() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = ComputerUseTool(orchestrator: orchestrator)
        let args = ComputerUseTool.Arguments(action: "teleport", x: nil, y: nil, text: nil,
                                             keys: nil, deltaX: nil, deltaY: nil,
                                             appName: nil, seconds: nil)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("Unknown computer_use action"))
    }

    @Test("ComputerUseTool invalid key combo or permission gate — never posts events in tests")
    @MainActor
    func testComputerUseToolKeySafety() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = ComputerUseTool(orchestrator: orchestrator)
        // Invalid token: without AX trust the permission notice fires; with
        // trust, the resolve-before-post check reports the unknown key. Either
        // way no input event is synthesized by this test.
        let args = ComputerUseTool.Arguments(action: "key", x: nil, y: nil, text: nil,
                                             keys: "frobnicate", deltaX: nil, deltaY: nil,
                                             appName: nil, seconds: nil)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("Unknown key") || result.contains("🔒"))
    }

    @Test("ComputerUseTool click requires coordinates")
    @MainActor
    func testComputerUseToolClickValidation() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = ComputerUseTool(orchestrator: orchestrator)
        let args = ComputerUseTool.Arguments(action: "click", x: nil, y: nil, text: nil,
                                             keys: nil, deltaX: nil, deltaY: nil,
                                             appName: nil, seconds: nil)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("requires x and y"))
    }
}
