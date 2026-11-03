import Testing
import Foundation
@testable import ApexAgentCore

@Suite("HardeningCycle3F2Tests") @MainActor
struct HardeningCycle3F2Tests {

    @Test func disabledToolModeReturnsDisabledMessage() async throws {
        let orch = AgentOrchestrator()
        orch.toolCallingMode = .disabled
        let tool = AskBotTool(orchestrator: orch)
        let result = try await tool.call(arguments: .init(targetBot: "Nobody", message: "hi"))
        #expect(result.contains("Tool execution rejected"))
    }

    @Test func deniedToolStaysDeniedAfterModelSwitch() async throws {
        setenv("APEX_FORCE_DENY", "1", 1)
        defer { unsetenv("APEX_FORCE_DENY") }
        let orch = AgentOrchestrator()
        orch.modelPreference = .localSystem
        let tool = AskBotTool(orchestrator: orch)
        let first = try await tool.call(arguments: .init(targetBot: "Nobody", message: "hi"))
        #expect(first == "ERROR: Operation denied by user.")

        orch.modelPreference = .cloudGemini
        let tool2 = AskBotTool(orchestrator: orch)
        let second = try await tool2.call(arguments: .init(targetBot: "Nobody", message: "hi"))
        #expect(second == "ERROR: Operation denied by user.")
    }

    @Test func modelSwitchDoesNotResetConfirmationScope() async throws {
        let orch = AgentOrchestrator()
        orch.requireConfirmationForAll = true
        orch.confirmationDepth = 2
        let requireBefore = orch.requireConfirmationForAll
        let depthBefore = orch.confirmationDepth

        orch.modelPreference = .localSystem
        orch.modelPreference = .cloudGemini
        orch.modelPreference = .autoPicker

        #expect(orch.requireConfirmationForAll == requireBefore)
        #expect(orch.confirmationDepth == depthBefore)
        #expect(ToolConfirmationScope.activeConfirmedToolName == nil)
    }

    @Test func autoFallbackWhenSelectedModelFails() async throws {
        ModelCircuitBreaker.shared.reset()
        let orch = AgentOrchestrator()
        let candidates = [
            ProviderCandidate(provider: .localOllama, reason: "Selected model (expected to fail)"),
            ProviderCandidate(provider: .appleOnDevice, reason: "Fallback provider")
        ]
        let terminal = await ProviderFallbackExecutor.shared.execute(
            candidates: candidates,
            prompt: "ping",
            orchestrator: orch
        )
        switch terminal {
        case .completed, .fallbackExhausted:
            break
        default:
            Issue.record("Unexpected terminal state: \\(terminal)")
        }
    }
    @Test func confirmationDepthResetsAfterDenial() async throws {
        setenv("APEX_FORCE_DENY", "1", 1)
        defer { unsetenv("APEX_FORCE_DENY") }
        let orch = AgentOrchestrator()
        orch.requireConfirmationForAll = true
        let before = orch.confirmationDepth
        let tool = AskBotTool(orchestrator: orch)
        _ = try? await tool.call(arguments: .init(targetBot: "Nobody", message: "hi"))
        #expect(orch.confirmationDepth == before)
    }

    @Test func autoFallbackRecordsProviderFallbackEvent() async throws {
        ModelCircuitBreaker.shared.reset()
        let orch = AgentOrchestrator()
        let candidates = [
            ProviderCandidate(provider: .localOllama, reason: "Selected model (expected to fail)"),
            ProviderCandidate(provider: .appleOnDevice, reason: "Fallback provider")
        ]
        let collector = EventCollector()
        let terminal = await ProviderFallbackExecutor.shared.execute(
            candidates: candidates,
            prompt: "ping",
            orchestrator: orch,
            onEvent: { event in
                collector.append(event)
            }
        )
        switch terminal {
        case .completed, .fallbackExhausted:
            break
        default:
            Issue.record("Unexpected terminal state: \\(terminal)")
        }
        let recorded = collector.snapshot()
        #expect(recorded.contains { event in
            if case .providerFallback(from: .localOllama, to: .appleOnDevice, _) = event {
                return true
            }
            return false
        })
    }
}

final class EventCollector: @unchecked Sendable {
    private var lock = NSLock()
    private var storage: [RuntimeEvent] = []
    func append(_ event: RuntimeEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }
    func snapshot() -> [RuntimeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
