import Foundation
import SharedModels

// MARK: - Outcome-First Eval Harness Live Verifier (Issue #111)

/// Live verifier executing real tasks and real trials in clean containers with pass^k reliability gate.
@MainActor
public enum EvalHarnessLiveVerifier {

    public struct VerificationResult: Sendable {
        public let output: String
        public let passed: Bool
        public let totalTasks: Int
        public let passedTasks: Int
        public let passToTheKRate: Double
    }

    public static func runVerification(jsonOutput: Bool = false) async -> VerificationResult {
        var logs: [String] = []
        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())

        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #111: LIVE OUTCOME-FIRST EVAL HARNESS & PASS^K RELIABILITY GATE")
        logs.append("Timestamp: \(timestamp)")
        logs.append("Host: Darwin arm64 (macOS 27) — Apple Silicon Containerization")
        logs.append("================================================================================")

        let diagnostics = ContainerManager.checkHostCapabilities()
        logs.append("\n[1] Verifying Container Host Diagnostics & Hardware Capabilities:")
        logs.append("  -> Apple Silicon (arm64): \(diagnostics.isAppleSilicon ? "YES" : "NO")")
        logs.append("  -> Virtualization Supported: \(diagnostics.isVirtualizationSupported ? "YES" : "NO")")
        logs.append("  -> macOS Version: \(diagnostics.macOSVersionString)")
        let freeGB = Double(diagnostics.availableDiskSpaceBytes) / (1024 * 1024 * 1024)
        logs.append("  -> Free Disk Space: \(String(format: "%.1f GB", freeGB))")
        logs.append("  -> Status Message: \(diagnostics.statusMessage)")

        // 2. Initialize Harness and Calibrated Judge
        logs.append("\n[2] Initializing Outcome-First Eval Harness & Calibrated LLM Judge:")
        let judge = CalibratedLLMJudge(
            judgeModelName: "apex-p0-calibrated-judge",
            requiredAgreementThreshold: 0.80
        )
        let trialRunner = CleanContainerTrialRunner()

        // 3. Perform Judge Calibration against Labeled Ground-Truth Dataset
        logs.append("\n[3] Executing Judge Calibration on Ground-Truth Labeled Dataset:")
        let calibrationReport: CalibrationReport
        do {
            calibrationReport = try await judge.calibrate(dataset: .standardLabeledSet)
            logs.append("  -> Total Calibration Samples: \(calibrationReport.totalSamples)")
            logs.append("  -> Matching Ground-Truth Verdicts: \(calibrationReport.matchingVerdicts)")
            logs.append("  -> Agreement Rate: \(String(format: "%.1f%%", calibrationReport.agreementRate * 100))")
            logs.append("  -> Required Threshold: \(String(format: "%.0f%%", calibrationReport.requiredThreshold * 100))")
            logs.append("  -> Qualification Verdict: \(calibrationReport.isQualified ? "QUALIFIED" : "DISQUALIFIED")")
            for sampleRes in calibrationReport.sampleResults {
                let matchMark = sampleRes.isAgreement ? "MATCH" : "MISMATCH"
                logs.append("     [\(sampleRes.sampleId)]: Predicted=\(sampleRes.predictedVerdict) GroundTruth=\(sampleRes.groundTruthVerdict) [\(matchMark)]")
            }
        } catch {
            logs.append("  -> Calibration FATAL ERROR: \(error.localizedDescription)")
            return VerificationResult(
                output: logs.joined(separator: "\n") + "\nVERIFICATION RESULT: FAIL\n",
                passed: false,
                totalTasks: 0,
                passedTasks: 0,
                passToTheKRate: 0.0
            )
        }

        // 4. Execute Real Tasks in Versioned P0 Suite with Clean Container Trials
        logs.append("\n[4] Executing Real Versioned Suite '\(EvalTaskSuite.standardP0Suite.suiteId)' (Version \(EvalTaskSuite.standardP0Suite.version)):")
        let suite = EvalTaskSuite.standardP0Suite

        var taskGateResults: [EvalTaskGateResult] = []

        for task in suite.tasks {
            logs.append("\n--- Task: [\(task.id)] \"\(task.title)\" (k=\(task.k), Grader: \(task.graderType.rawValue)) ---")
            logs.append("Prompt: \(task.prompt)")

            let grader: any EvalGrader
            switch task.graderType {
            case .deterministicExact:
                grader = DeterministicGrader(mode: .exact)
            case .deterministicRegex:
                grader = DeterministicGrader(mode: .regex)
            case .deterministicTrace:
                grader = DeterministicGrader(mode: .trace)
            case .deterministicFileArtifact:
                grader = DeterministicGrader(mode: .fileArtifact)
            case .deterministicCompound:
                grader = DeterministicGrader(mode: .compound)
            case .calibratedLLMJudge:
                grader = judge
            }

            var trialResults: [EvalTrialResult] = []
            for trialIndex in 1...task.k {
                do {
                    let trialExec = try await trialRunner.executeTrial(task: task, trialIndex: trialIndex)
                    let verdict = try await grader.grade(trial: trialExec, expected: task.expectedOutcome)

                    logs.append("  -> Trial \(trialIndex)/\(task.k) [Container: \(trialExec.containerId)] (Duration: \(String(format: "%.3fs", trialExec.duration))):")
                    logs.append("     ExitCode: \(trialExec.exitCode), Output: \"\(trialExec.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))\"")
                    logs.append("     Grader Verdict: \(verdict.isPassed ? "PASS" : "FAIL") (Score: \(verdict.score)) — \(verdict.reason)")

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
                } catch {
                    logs.append("  -> Trial \(trialIndex)/\(task.k) ERROR: \(error.localizedDescription)")
                    let failVerdict = EvalGradeVerdict.fail(score: 0.0, reason: error.localizedDescription)
                    let trialResult = EvalTrialResult(
                        trialId: "trial-error-\(trialIndex)",
                        trialIndex: trialIndex,
                        containerId: "container-error",
                        isPassed: false,
                        duration: 0.0,
                        verdict: failVerdict
                    )
                    trialResults.append(trialResult)
                }
            }

            let taskGateResult = PassToTheKGate.evaluateTask(task: task, trials: trialResults)
            taskGateResults.append(taskGateResult)

            let verdictTag = taskGateResult.isPassed ? "PASS" : "FAIL"
            logs.append("VERDICT [TASK: \(task.id)]: \(verdictTag) (k=\(task.k), trials=\(taskGateResult.trialStatusString))")
        }

        let suiteSummary = PassToTheKGate.evaluateSuite(results: taskGateResults)

        logs.append("\n================================================================================")
        logs.append("OUTCOME-FIRST EVAL HARNESS VERIFICATION SUMMARY")
        logs.append("================================================================================")
        logs.append("VERDICT [JUDGE CALIBRATION]: \(calibrationReport.isQualified ? "PASS" : "FAIL") (Agreement: \(String(format: "%.1f%%", calibrationReport.agreementRate * 100)))")
        logs.append("VERDICT [PASS^K RELIABILITY GATE]: \(suiteSummary.passedTasks == suiteSummary.totalTasks ? "PASS" : "FAIL") (\(suiteSummary.passedTasks)/\(suiteSummary.totalTasks) tasks passed pass^k reliability gate)")

        for taskRes in taskGateResults {
            logs.append("VERDICT [\(taskRes.taskId)]: \(taskRes.isPassed ? "PASS" : "FAIL") (k=\(taskRes.k), \(taskRes.trialStatusString))")
        }

        let overallPassed = calibrationReport.isQualified && (suiteSummary.passedTasks == suiteSummary.totalTasks)
        logs.append("\nVERIFICATION RESULT: \(overallPassed ? "PASS" : "FAIL")")
        logs.append("================================================================================")

        try? await ContainerManager.shared.stopContainer()

        let outputText = logs.joined(separator: "\n")
        return VerificationResult(
            output: outputText,
            passed: overallPassed,
            totalTasks: suiteSummary.totalTasks,
            passedTasks: suiteSummary.passedTasks,
            passToTheKRate: suiteSummary.passToTheKRate
        )
    }
}
