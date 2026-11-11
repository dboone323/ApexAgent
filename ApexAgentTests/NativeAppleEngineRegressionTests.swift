import XCTest
@testable import ApexAgentCore
import FoundationModels

final class NativeAppleEngineRegressionTests: XCTestCase {
    @MainActor
    func testPromptCancellationHonoredPromptly() async throws {
        // Requirement (a): A cancelled engine call against a slow/never-returning
        // responder stub must return promptly (< 1s) when cancelled, rather than
        // blocking until the responder stub finishes.
        let orch = AgentOrchestrator()
        var engine = NativeAppleEngine(orchestrator: orch)

        let stubDelay: Double = 3.0
        engine.customResponder = { _, _ in
            try await Task.sleep(for: .seconds(stubDelay))
            return "delayed response"
        }

        let start = ContinuousClock.now
        let streamTask = Task { @MainActor in
            try await engine.streamResponse(
                prompt: "test cancellation",
                attachments: [],
                history: [],
                instructions: "",
                toolCallingMode: .disabled,
                onUpdate: { _ in }
            )
        }

        // Allow streamResponse to enter execution and suspend on the responder stub
        try await Task.sleep(for: .milliseconds(100))

        // Cancel the caller task
        streamTask.cancel()

        // Await the task completion
        _ = await streamTask.result
        let elapsed = ContinuousClock.now - start
        let durationSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        print("[TEST REGRESSION a] Cancellation wait duration: \(durationSeconds)s (stubDelay=\(stubDelay)s)")

        // Assert: prompt cancellation must return in < 1.0s, NOT block for stubDelay (3.0s)
        XCTAssertLessThan(
            durationSeconds,
            1.0,
            "Cancelled NativeAppleEngine call must return promptly (< 1s), but took \(durationSeconds)s"
        )
    }

    @MainActor
    func testCallerImposedDeadlineWinsOverDefaultTimeout() async throws {
        // Requirement (b): A caller-imposed deadline (e.g. 0.5s) must win over the engine's
        // default 90s/180s timeout, rather than overrunning the deadline.
        let orch = AgentOrchestrator()
        let deadlineSeconds: TimeInterval = 0.5
        var engine = NativeAppleEngine(orchestrator: orch, timeoutOverride: deadlineSeconds)

        let stubDelay: Double = 3.0
        engine.customResponder = { _, _ in
            try await Task.sleep(for: .seconds(stubDelay))
            return "delayed response"
        }

        let start = ContinuousClock.now
        do {
            try await engine.streamResponse(
                prompt: "test deadline",
                attachments: [],
                history: [],
                instructions: "",
                toolCallingMode: .disabled,
                onUpdate: { _ in }
            )
        } catch {
            // Timeout/cancellation is expected when deadline fires
        }
        let elapsed = ContinuousClock.now - start
        let durationSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        print("[TEST REGRESSION b] Caller deadline duration: \(durationSeconds)s (deadline=\(deadlineSeconds)s, stubDelay=\(stubDelay)s)")

        // Assert: execution must return at approximately the deadline (< 1.0s),
        // and must NOT overrun to the stub's full delay (3.0s).
        XCTAssertLessThan(
            durationSeconds,
            1.0,
            "NativeAppleEngine must honor caller-imposed deadline (\(deadlineSeconds)s), but took \(durationSeconds)s"
        )
        XCTAssertGreaterThanOrEqual(
            durationSeconds,
            0.35,
            "NativeAppleEngine deadline triggered prematurely (\(durationSeconds)s < 0.35s)"
        )
    }
}
