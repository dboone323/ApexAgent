import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 98 — Turn Watchdog & Step-Level Deadline Gate Tests")
struct TurnWatchdogAuditorTests {

    @Test("Valid steps within deadlines pass turn audit with 100% score")
    func validStepsPassTurnAudit() {
        let steps = [
            TurnWatchdogAuditor.auditStep(stepIndex: 1, kind: .synthesisPlanning, targetName: "Plan Decomp", duration: 2.5),
            TurnWatchdogAuditor.auditStep(stepIndex: 2, kind: .toolExecution, targetName: "read_file", duration: 0.8),
            TurnWatchdogAuditor.auditStep(stepIndex: 3, kind: .modelInference, targetName: "gpt-4o", duration: 5.2)
        ]

        let toolCalls = [
            TrackedToolCall(toolName: "read_file", argumentsHash: "hash_a")
        ]

        let report = TurnWatchdogAuditor.auditTurnSequence(steps: steps, toolCalls: toolCalls)

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.exceededStepCount == 0)
        #expect(report.violations.isEmpty)
        #expect(report.totalActiveDurationSeconds > 0)
    }

    @Test("Human approval wait is exempt from step deadline timeout")
    func humanApprovalWaitExemptFromTimeout() {
        let step = TurnWatchdogAuditor.auditStep(
            stepIndex: 1,
            kind: .humanApprovalWait,
            targetName: "Terminal Command Confirmation",
            duration: 1200.0 // 20 minutes
        )

        #expect(!step.isExceeded)
    }

    @Test("Step exceeding deadline produces warning metric")
    func stepExceedingDeadlineProducesWarning() {
        let slowToolStep = TurnWatchdogAuditor.auditStep(
            stepIndex: 1,
            kind: .toolExecution,
            targetName: "xcodebuild",
            duration: 90.0, // Exceeds default 45s
            customDeadline: 45.0
        )

        #expect(slowToolStep.isExceeded)

        let report = TurnWatchdogAuditor.auditTurnSequence(steps: [slowToolStep])

        #expect(report.passed) // Non-fatal step warning allows turn pass
        #expect(report.score == 90.0)
        #expect(report.exceededStepCount == 1)
        #expect(report.violations.contains { $0.code == "STEP_DEADLINE_EXCEEDED" })
    }

    @Test("Runaway tool loop detection catches 3 consecutive identical tool calls")
    func runawayToolLoopDetected() {
        let calls = [
            TrackedToolCall(toolName: "run_command", argumentsHash: "ls_-la"),
            TrackedToolCall(toolName: "run_command", argumentsHash: "ls_-la"),
            TrackedToolCall(toolName: "run_command", argumentsHash: "ls_-la")
        ]

        let violation = TurnWatchdogAuditor.detectRunawayToolLoop(toolCalls: calls, consecutiveThreshold: 3)
        #expect(violation != nil)
        #expect(violation?.code == "RUNAWAY_TOOL_LOOP_DETECTED")
        #expect(violation?.isFatal == true)
    }

    @Test("Alternating tool calls do not trigger runaway tool loop")
    func alternatingToolCallsDoNotTriggerLoop() {
        let calls = [
            TrackedToolCall(toolName: "run_command", argumentsHash: "ls_-la"),
            TrackedToolCall(toolName: "view_file", argumentsHash: "file1.swift"),
            TrackedToolCall(toolName: "run_command", argumentsHash: "ls_-la"),
            TrackedToolCall(toolName: "view_file", argumentsHash: "file1.swift")
        ]

        let violation = TurnWatchdogAuditor.detectRunawayToolLoop(toolCalls: calls, consecutiveThreshold: 3)
        #expect(violation == nil)
    }

    @Test("Exceeding maximum iteration budget trips fatal watchdog violation")
    func maxIterationsExceededFails() {
        let excessiveSteps = (1...35).map { i in
            TurnWatchdogAuditor.auditStep(stepIndex: i, kind: .toolExecution, targetName: "step_\(i)", duration: 0.1)
        }

        let report = TurnWatchdogAuditor.auditTurnSequence(steps: excessiveSteps, maxIterations: 30)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "MAX_ITERATIONS_EXCEEDED" })
    }

    @Test("Exceeding global active turn deadline trips fatal watchdog violation")
    func globalTurnDeadlineExceededFails() {
        let steps = [
            TurnWatchdogAuditor.auditStep(stepIndex: 1, kind: .toolExecution, targetName: "long_job", duration: 350.0, customDeadline: 400.0)
        ]

        let report = TurnWatchdogAuditor.auditTurnSequence(steps: steps, globalTurnDeadlineSeconds: 300.0)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "GLOBAL_TURN_DEADLINE_EXCEEDED" })
    }
}
