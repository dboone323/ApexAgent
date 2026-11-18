import Foundation
import SharedModels

// MARK: - Eval Harness Configuration

public struct EvalHarnessConfig: Sendable {
    public let requireCleanContainer: Bool
    public let calibrationThreshold: Double

    public init(
        requireCleanContainer: Bool = true,
        calibrationThreshold: Double = 0.80
    ) {
        self.requireCleanContainer = requireCleanContainer
        self.calibrationThreshold = calibrationThreshold
    }
}

// MARK: - Eval Harness Report

public struct EvalHarnessReport: Codable, Sendable, Equatable {
    public let suiteId: String
    public let suiteVersion: EvalSuiteVersion
    public let executedAt: Date
    public let duration: TimeInterval
    public let passToTheKSummary: PassToTheKSummary
    public let calibrationReport: CalibrationReport?
    public let isHarnessPassed: Bool

    public init(
        suiteId: String,
        suiteVersion: EvalSuiteVersion,
        executedAt: Date = Date(),
        duration: TimeInterval,
        passToTheKSummary: PassToTheKSummary,
        calibrationReport: CalibrationReport? = nil
    ) {
        self.suiteId = suiteId
        self.suiteVersion = suiteVersion
        self.executedAt = executedAt
        self.duration = duration
        self.passToTheKSummary = passToTheKSummary
        self.calibrationReport = calibrationReport
        // Overall harness passes if all tasks passed their pass^k gate and (if judge present) judge calibrated
        let judgePassed = (calibrationReport == nil) || (calibrationReport?.isQualified == true)
        self.isHarnessPassed = (passToTheKSummary.passedTasks == passToTheKSummary.totalTasks) && judgePassed
    }

    /// Generates the complete outcome-first evaluation harness report.
    public func generateMarkdownReport() -> String {
        let isoFormatter = ISO8601DateFormatter()
        var md = "# 🏆 ApexAgent Outcome-First Eval Harness Report\n\n"
        md += "- **Suite ID**: `\(suiteId)` (Version: `\(suiteVersion)`)\n"
        md += "- **Execution Date**: \(isoFormatter.string(from: executedAt))\n"
        md += "- **Execution Duration**: \(String(format: "%.2fs", duration))\n"
        md += "- **Overall Gate Verdict**: \(isHarnessPassed ? "✅ PASS" : "❌ FAIL")\n\n"

        if let cal = calibrationReport {
            md += "### ⚖️ LLM Judge Calibration Status\n\n"
            md += "- **Judge Model**: `\(cal.judgeModel)`\n"
            md += "- **Calibration Status**: \(cal.isQualified ? "✅ QUALIFIED" : "❌ DISQUALIFIED")\n"
            md += "- **Agreement Rate on Labeled Ground Truth**: `\(String(format: "%.1f%%", cal.agreementRate * 100))` (\(cal.matchingVerdicts)/\(cal.totalSamples) matching)\n"
            md += "- **Required Threshold**: `\(String(format: "%.0f%%", cal.requiredThreshold * 100))`\n\n"
        }

        md += passToTheKSummary.generateMarkdownReport()
        return md
    }
}

// MARK: - Outcome-First Eval Harness

/// Primary orchestrator for versioned task suites, deterministic graders, calibrated judges,
/// and pass^k reliability gates inside clean container trials.
@MainActor
public final class OutcomeFirstEvalHarness: Sendable {
    public let trialRunner: CleanContainerTrialRunner
    public let config: EvalHarnessConfig

    public init(
        trialRunner: CleanContainerTrialRunner = CleanContainerTrialRunner(),
        config: EvalHarnessConfig = EvalHarnessConfig()
    ) {
        self.trialRunner = trialRunner
        self.config = config
    }

    /// Runs a full evaluation task suite.
    public func runSuite(
        suite: EvalTaskSuite = .standardP0Suite,
        judge: CalibratedLLMJudge? = nil
    ) async throws -> EvalHarnessReport {
        let startTime = Date()
        AppLog.info(.audit, "OutcomeFirstEvalHarness: Starting suite '\(suite.suiteId)' v\(suite.version)")

        // 1. Calibrate Judge if present
        var calibrationReport: CalibrationReport? = nil
        if let judge = judge {
            calibrationReport = try await judge.calibrate()
            if calibrationReport?.isQualified != true {
                AppLog.error(.audit, "OutcomeFirstEvalHarness: LLM judge failed calibration threshold requirement.")
            }
        }

        // 2. Execute trials for each task in suite
        var taskGateResults: [EvalTaskGateResult] = []

        for task in suite.tasks {
            AppLog.info(.audit, "OutcomeFirstEvalHarness: Executing task '\(task.id)' with k=\(task.k)")
            let grader: any EvalGrader = try resolveGrader(for: task, judge: judge)

            var trialResults: [EvalTrialResult] = []
            for trialIndex in 1...task.k {
                let trialExec = try await trialRunner.executeTrial(task: task, trialIndex: trialIndex)
                let verdict = try await grader.grade(trial: trialExec, expected: task.expectedOutcome)

                let trialResult = EvalTrialResult(
                    trialId: trialExec.trialId,
                    trialIndex: trialIndex,
                    containerId: trialExec.containerId,
                    isPassed: verdict.isPassed,
                    duration: trialExec.duration,
                    verdict: verdict,
                    traceId: trialExec.runTrace?.id
                )
                trialResults.append(trialResult)
            }

            let taskGateResult = PassToTheKGate.evaluateTask(task: task, trials: trialResults)
            taskGateResults.append(taskGateResult)
        }

        let passToTheKSummary = PassToTheKGate.evaluateSuite(results: taskGateResults)
        let elapsed = Date().timeIntervalSince(startTime)

        let report = EvalHarnessReport(
            suiteId: suite.suiteId,
            suiteVersion: suite.version,
            executedAt: startTime,
            duration: elapsed,
            passToTheKSummary: passToTheKSummary,
            calibrationReport: calibrationReport
        )

        AppLog.info(.audit, "OutcomeFirstEvalHarness: Finished suite in \(String(format: "%.2f", elapsed))s. Overall pass: \(report.isHarnessPassed)")
        return report
    }

    private func resolveGrader(for task: EvalTask, judge: CalibratedLLMJudge?) throws -> any EvalGrader {
        switch task.graderType {
        case .deterministicExact:
            return DeterministicGrader(mode: .exact)
        case .deterministicRegex:
            return DeterministicGrader(mode: .regex)
        case .deterministicTrace:
            return DeterministicGrader(mode: .trace)
        case .deterministicFileArtifact:
            return DeterministicGrader(mode: .fileArtifact)
        case .deterministicCompound:
            return DeterministicGrader(mode: .compound)
        case .calibratedLLMJudge:
            guard let judge = judge else {
                throw EvalHarnessError.uncalibratedJudge("Task \(task.id) requires calibrated LLM judge, but none was provided.")
            }
            return judge
        }
    }
}
