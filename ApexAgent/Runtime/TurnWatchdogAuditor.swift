import Foundation

// MARK: - Turn Watchdog & Step-Level Deadline Gate (Batch 98)

/// Categories of agent execution steps evaluated for deadline compliance.
public enum AgentStepKind: String, Sendable, Codable, CaseIterable {
    case modelInference = "model_inference"
    case toolExecution = "tool_execution"
    case humanApprovalWait = "approval_wait"
    case perceptionProcessing = "perception_processing"
    case synthesisPlanning = "synthesis_planning"

    /// Default allowable timeout deadline in seconds before triggering a step timeout violation.
    public var defaultDeadlineSeconds: TimeInterval {
        switch self {
        case .modelInference: return 60.0
        case .toolExecution: return 45.0
        case .humanApprovalWait: return 86400.0 // 24 hours (waiting on human is exempt from tight stalls)
        case .perceptionProcessing: return 8.0
        case .synthesisPlanning: return 30.0
        }
    }
}

/// Recorded telemetry for an individual step executed within an agent turn.
public struct StepExecutionMetric: Sendable, Codable, Equatable, Identifiable {
    public var id: String { "\(stepIndex):\(stepKind.rawValue):\(targetName)" }
    public let stepIndex: Int
    public let stepKind: AgentStepKind
    public let targetName: String
    public let durationSeconds: TimeInterval
    public let deadlineSeconds: TimeInterval
    public let isExceeded: Bool

    public init(
        stepIndex: Int,
        stepKind: AgentStepKind,
        targetName: String,
        durationSeconds: TimeInterval,
        deadlineSeconds: TimeInterval? = nil
    ) {
        let deadline = deadlineSeconds ?? stepKind.defaultDeadlineSeconds
        self.stepIndex = stepIndex
        self.stepKind = stepKind
        self.targetName = targetName
        self.durationSeconds = durationSeconds
        self.deadlineSeconds = deadline
        self.isExceeded = (stepKind != .humanApprovalWait) && (durationSeconds > deadline)
    }
}

/// Invocations tracked to identify repeating tool loops.
public struct TrackedToolCall: Sendable, Codable, Equatable {
    public let toolName: String
    public let argumentsHash: String

    public init(toolName: String, argumentsHash: String) {
        self.toolName = toolName
        self.argumentsHash = argumentsHash
    }
}

/// Violation detected during step-level deadline or turn stall evaluation.
public struct TurnWatchdogViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Comprehensive report of turn timing, step deadlines, and runaway loop analysis.
public struct TurnWatchdogReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let violations: [TurnWatchdogViolation]
    public let totalDurationSeconds: TimeInterval
    public let totalActiveDurationSeconds: TimeInterval
    public let exceededStepCount: Int

    public init(
        passed: Bool,
        score: Double,
        violations: [TurnWatchdogViolation],
        totalDurationSeconds: TimeInterval,
        totalActiveDurationSeconds: TimeInterval,
        exceededStepCount: Int
    ) {
        self.passed = passed
        self.score = score
        self.violations = violations
        self.totalDurationSeconds = totalDurationSeconds
        self.totalActiveDurationSeconds = totalActiveDurationSeconds
        self.exceededStepCount = exceededStepCount
    }
}

/// Fine-grained watchdog enforcing step-level deadlines, preventing runaway tool loops, and auditing turn health.
public enum TurnWatchdogAuditor {

    // MARK: - Step-Level Evaluation

    /// Audits an individual execution step against its designated deadline.
    public static func auditStep(
        stepIndex: Int,
        kind: AgentStepKind,
        targetName: String,
        duration: TimeInterval,
        customDeadline: TimeInterval? = nil
    ) -> StepExecutionMetric {
        StepExecutionMetric(
            stepIndex: stepIndex,
            stepKind: kind,
            targetName: targetName,
            durationSeconds: duration,
            deadlineSeconds: customDeadline
        )
    }

    // MARK: - Runaway Tool Loop Detection

    /// Detects runaway repetition where the exact same tool is called consecutively with identical parameters.
    public static func detectRunawayToolLoop(
        toolCalls: [TrackedToolCall],
        consecutiveThreshold: Int = 3
    ) -> TurnWatchdogViolation? {
        guard toolCalls.count >= consecutiveThreshold else { return nil }

        var currentTool = ""
        var currentHash = ""
        var consecutiveCount = 0

        for call in toolCalls {
            if call.toolName == currentTool && call.argumentsHash == currentHash {
                consecutiveCount += 1
                if consecutiveCount >= consecutiveThreshold {
                    return TurnWatchdogViolation(
                        code: "RUNAWAY_TOOL_LOOP_DETECTED",
                        message: "Tool '\(call.toolName)' was invoked \(consecutiveCount) consecutive times with identical arguments, triggering infinite loop prevention."
                    )
                }
            } else {
                currentTool = call.toolName
                currentHash = call.argumentsHash
                consecutiveCount = 1
            }
        }

        return nil
    }

    // MARK: - Comprehensive Turn Sequence Audit

    /// Audits an entire sequence of turn steps for step timeouts, cumulative turn duration, and loop runaway.
    public static func auditTurnSequence(
        steps: [StepExecutionMetric],
        toolCalls: [TrackedToolCall] = [],
        maxIterations: Int = 30,
        globalTurnDeadlineSeconds: TimeInterval = 300.0,
        consecutiveLoopThreshold: Int = 3
    ) -> TurnWatchdogReport {
        var violations: [TurnWatchdogViolation] = []

        // 1. Max iteration count check
        if steps.count > maxIterations {
            violations.append(TurnWatchdogViolation(
                code: "MAX_ITERATIONS_EXCEEDED",
                message: "Turn executed \(steps.count) steps, exceeding maximum allowable iteration budget of \(maxIterations)."
            ))
        }

        // 2. Step-level deadline check
        var exceededCount = 0
        for step in steps where step.isExceeded {
            exceededCount += 1
            violations.append(TurnWatchdogViolation(
                code: "STEP_DEADLINE_EXCEEDED",
                message: "Step #\(step.stepIndex) (\(step.stepKind.rawValue): \(step.targetName)) took \(String(format: "%.1f", step.durationSeconds))s, exceeding deadline of \(String(format: "%.1f", step.deadlineSeconds))s.",
                isFatal: false // Step slowness warns unless cumulative turn or loop fails
            ))
        }

        // 3. Runaway tool loop check
        if let loopViolation = detectRunawayToolLoop(toolCalls: toolCalls, consecutiveThreshold: consecutiveLoopThreshold) {
            violations.append(loopViolation)
        }

        // 4. Cumulative turn duration check (excluding human wait time)
        let totalDuration = steps.reduce(0.0) { $0 + $1.durationSeconds }
        let activeDuration = steps
            .filter { $0.stepKind != .humanApprovalWait }
            .reduce(0.0) { $0 + $1.durationSeconds }

        if activeDuration > globalTurnDeadlineSeconds {
            violations.append(TurnWatchdogViolation(
                code: "GLOBAL_TURN_DEADLINE_EXCEEDED",
                message: "Active turn execution time (\(String(format: "%.1f", activeDuration))s) exceeded global turn ceiling of \(String(format: "%.1f", globalTurnDeadlineSeconds))s."
            ))
        }

        let fatalViolations = violations.filter(\.isFatal)
        let nonFatalViolations = violations.filter { !$0.isFatal }
        let passed = fatalViolations.isEmpty

        var score = 100.0 - Double(fatalViolations.count) * 30.0 - Double(nonFatalViolations.count) * 10.0
        score = max(0.0, min(100.0, score))

        return TurnWatchdogReport(
            passed: passed,
            score: score,
            violations: violations,
            totalDurationSeconds: totalDuration,
            totalActiveDurationSeconds: activeDuration,
            exceededStepCount: exceededCount
        )
    }
}
