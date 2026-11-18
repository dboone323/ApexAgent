import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Outcome-First Eval Harness Gate Tests")
struct OutcomeFirstEvalHarnessTests {

    // MARK: - Requirement 1: Suite Versioning & SemVer

    @Test("Suite versioning parses SemVer strings and handles version bumps")
    func suiteVersioningAndBumpSemVer() {
        let v1 = EvalSuiteVersion(parsing: "1.0.0")
        #expect(v1 != nil)
        #expect(v1?.major == 1)
        #expect(v1?.minor == 0)
        #expect(v1?.patch == 0)
        #expect(v1?.description == "1.0.0")

        let v1_patch = v1?.bumpPatch()
        #expect(v1_patch?.description == "1.0.1")
        #expect(v1! < v1_patch!)

        let v1_minor = v1?.bumpMinor()
        #expect(v1_minor?.description == "1.1.0")
        #expect(v1_patch! < v1_minor!)

        let v2 = v1?.bumpMajor()
        #expect(v2?.description == "2.0.0")
        #expect(v1_minor! < v2!)

        // Versioning in task suite
        let suiteV1 = EvalTaskSuite.standardP0Suite
        #expect(suiteV1.version == EvalSuiteVersion(major: 1, minor: 0, patch: 0))

        let suiteV2 = EvalTaskSuite(
            suiteId: suiteV1.suiteId,
            version: suiteV1.version.bumpMinor(),
            title: suiteV1.title,
            description: "Updated suite with additional benchmark coverage",
            tasks: suiteV1.tasks
        )
        #expect(suiteV2.version == EvalSuiteVersion(major: 1, minor: 1, patch: 0))
        #expect(suiteV1.version < suiteV2.version)
    }

    // MARK: - Requirement 2: Grader Correctness (Known-Good vs Known-Bad)

    @Test("Deterministic grader passes known-good outcome and rejects known-bad outcome")
    func deterministicGraderCorrectness() async throws {
        let grader = DeterministicGrader(mode: .exact)
        let expected = EvalExpectedOutcome(
            description: "Test deterministic stdout match",
            expectedStdout: "42",
            expectedExitCode: 0
        )

        // Known-good trial: exact stdout match and exit code 0
        let goodTrial = EvalTrialExecution(
            trialId: "trial-good-1",
            taskId: "task-test",
            trialIndex: 1,
            containerId: "container-test-1",
            stdout: "42\n",
            exitCode: 0
        )
        let goodVerdict = try await grader.grade(trial: goodTrial, expected: expected)
        #expect(goodVerdict.isPassed == true)
        #expect(goodVerdict.score == 1.0)

        // Known-bad trial: mismatched stdout
        let badTrialOutput = EvalTrialExecution(
            trialId: "trial-bad-1",
            taskId: "task-test",
            trialIndex: 1,
            containerId: "container-test-1",
            stdout: "99\n",
            exitCode: 0
        )
        let badVerdictOutput = try await grader.grade(trial: badTrialOutput, expected: expected)
        #expect(badVerdictOutput.isPassed == false)
        #expect(badVerdictOutput.score == 0.0)
        #expect(badVerdictOutput.reason.contains("Stdout does not contain expected output"))

        // Known-bad trial: non-zero exit code
        let badTrialExit = EvalTrialExecution(
            trialId: "trial-bad-2",
            taskId: "task-test",
            trialIndex: 1,
            containerId: "container-test-1",
            stdout: "42\n",
            exitCode: 137
        )
        let badVerdictExit = try await grader.grade(trial: badTrialExit, expected: expected)
        #expect(badVerdictExit.isPassed == false)
        #expect(badVerdictExit.reason.contains("Exit code mismatch"))
    }

    // MARK: - Requirement 3: Structural RunTrace Validation

    @Test("Deterministic grader verifies structural RunTrace event requirements")
    func deterministicGraderStructuralTrace() async throws {
        let grader = DeterministicGrader(mode: .trace)
        let expected = EvalExpectedOutcome(
            description: "Security tool execution requirement",
            expectedTraceEvents: [
                ExpectedTraceEventRequirement(
                    kind: .toolCall,
                    toolName: "file_search",
                    status: "success",
                    requiredCount: 1
                ),
                ExpectedTraceEventRequirement(
                    kind: .approval,
                    toolName: "file_search",
                    verdict: "approved",
                    requiredCount: 1
                )
            ]
        )

        // Valid trace with required events
        let validTrace = RunTrace(
            id: "trace-001",
            status: "completed",
            events: [
                RunTraceEvent.toolCall(
                    sequence: 1,
                    toolName: "file_search",
                    arguments: "query: test",
                    result: "found",
                    status: "success"
                ),
                RunTraceEvent.approval(
                    sequence: 2,
                    toolName: "file_search",
                    approved: true,
                    source: .autoReview
                )
            ]
        )

        let passTrial = EvalTrialExecution(
            trialId: "trial-trace-pass",
            taskId: "task-trace",
            trialIndex: 1,
            containerId: "container-trace",
            runTrace: validTrace,
            exitCode: 0
        )
        let passVerdict = try await grader.grade(trial: passTrial, expected: expected)
        #expect(passVerdict.isPassed == true)

        // Missing approval event in trace
        let invalidTrace = RunTrace(
            id: "trace-002",
            status: "completed",
            events: [
                RunTraceEvent.toolCall(
                    sequence: 1,
                    toolName: "file_search",
                    arguments: "query: test",
                    result: "found",
                    status: "success"
                )
            ]
        )

        let failTrial = EvalTrialExecution(
            trialId: "trial-trace-fail",
            taskId: "task-trace",
            trialIndex: 1,
            containerId: "container-trace",
            runTrace: invalidTrace,
            exitCode: 0
        )
        let failVerdict = try await grader.grade(trial: failTrial, expected: expected)
        #expect(failVerdict.isPassed == false)
        #expect(failVerdict.reason.contains("Trace requirement failed"))
    }

    // MARK: - Requirement 4: Judge Calibration & Agreement Rate

    @Test("Calibrated LLM judge computes agreement rate and reports calibration status")
    func judgeCalibrationAgreementRate() async throws {
        let judge = CalibratedLLMJudge(
            judgeModelName: "test-calibrated-judge",
            requiredAgreementThreshold: 0.80
        )

        #expect(judge.status == .uncalibrated)

        let report = try await judge.calibrate(dataset: .standardLabeledSet)
        #expect(report.totalSamples == 5)
        #expect(report.matchingVerdicts >= 4) // At least 80% agreement on standard dataset
        #expect(report.agreementRate >= 0.80)
        #expect(report.isQualified == true)
        #expect(judge.status.isCalibrated == true)
    }

    // MARK: - Requirement 5: Uncalibrated Judge Rejection

    @Test("Uncalibrated judge rejects grading attempts with explicit error")
    func uncalibratedJudgeRejection() async {
        let uncalibratedJudge = CalibratedLLMJudge(
            judgeModelName: "raw-uncalibrated-judge",
            requiredAgreementThreshold: 0.90
        )

        let trial = EvalTrialExecution(
            trialId: "trial-uncal-1",
            taskId: "task-semantic",
            trialIndex: 1,
            containerId: "container-1",
            stdout: "Sample explanation of ARC memory management."
        )
        let expected = EvalExpectedOutcome(
            description: "ARC explanation",
            semanticRubric: "Must discuss ARC reference counts."
        )

        do {
            _ = try await uncalibratedJudge.grade(trial: trial, expected: expected)
            Issue.record("Grading with uncalibrated judge must throw uncalibratedJudge error")
        } catch let error as EvalHarnessError {
            switch error {
            case .uncalibratedJudge(let reason):
                #expect(reason.contains("An uncalibrated judge is not a grader"))
            default:
                Issue.record("Expected uncalibratedJudge error, got: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Requirement 6: pass^k Reliability Gate Math

    @Test("pass^k reliability gate math: k=3 with 2 passes + 1 fail = task fail")
    func passToTheKGateMathFailWhenAnyTrialFails() {
        let task = EvalTask(
            id: "eval_unit_pass_k_3_fail",
            title: "Task with k=3 Reliability Requirement",
            prompt: "Execute reliable computation",
            expectedOutcome: EvalExpectedOutcome(description: "Reliable output"),
            k: 3
        )

        let trials: [EvalTrialResult] = [
            EvalTrialResult(
                trialId: "t1",
                trialIndex: 1,
                containerId: "c1",
                isPassed: true,
                duration: 0.5,
                verdict: .pass()
            ),
            EvalTrialResult(
                trialId: "t2",
                trialIndex: 2,
                containerId: "c2",
                isPassed: true,
                duration: 0.4,
                verdict: .pass()
            ),
            EvalTrialResult(
                trialId: "t3",
                trialIndex: 3,
                containerId: "c3",
                isPassed: false, // Trial 3 fails!
                duration: 0.6,
                verdict: .fail(reason: "Transient failure in trial 3")
            )
        ]

        let gateResult = PassToTheKGate.evaluateTask(task: task, trials: trials)
        #expect(gateResult.k == 3)
        #expect(gateResult.trialsTotalCount == 3)
        #expect(gateResult.trialsPassedCount == 2)
        // CRITICAL: 2 passes + 1 fail for k=3 must equal task FAIL
        #expect(gateResult.isPassed == false)
    }

    @Test("pass^k reliability gate math: k=3 with 3 passes = task pass")
    func passToTheKGateMathPassWhenAllTrialsPass() {
        let task = EvalTask(
            id: "eval_unit_pass_k_3_success",
            title: "Task with k=3 Reliability Requirement",
            prompt: "Execute reliable computation",
            expectedOutcome: EvalExpectedOutcome(description: "Reliable output"),
            k: 3
        )

        let trials: [EvalTrialResult] = [
            EvalTrialResult(
                trialId: "t1",
                trialIndex: 1,
                containerId: "c1",
                isPassed: true,
                duration: 0.5,
                verdict: .pass()
            ),
            EvalTrialResult(
                trialId: "t2",
                trialIndex: 2,
                containerId: "c2",
                isPassed: true,
                duration: 0.4,
                verdict: .pass()
            ),
            EvalTrialResult(
                trialId: "t3",
                trialIndex: 3,
                containerId: "c3",
                isPassed: true,
                duration: 0.4,
                verdict: .pass()
            )
        ]

        let gateResult = PassToTheKGate.evaluateTask(task: task, trials: trials)
        #expect(gateResult.k == 3)
        #expect(gateResult.trialsPassedCount == 3)
        #expect(gateResult.isPassed == true)
    }

    // MARK: - Requirement 7: Full Outcome-First Eval Harness Integration

    @Test("Full outcome-first harness executes suite, calibrates judge, and computes pass^k summary")
    func outcomeFirstHarnessExecution() async throws {
        let harness = OutcomeFirstEvalHarness()
        let judge = CalibratedLLMJudge(judgeModelName: "harness-calibrated-judge")

        // Define a fast, real mini-suite to verify the entire pipeline
        let miniSuite = EvalTaskSuite(
            suiteId: "apex-mini-eval-suite",
            version: EvalSuiteVersion(major: 1, minor: 0, patch: 0),
            title: "Mini Outcome-First Suite",
            description: "Fast integration test suite",
            tasks: [
                EvalTask(
                    id: "eval_mini_01_exact",
                    title: "Exact Output Task",
                    prompt: "Compute echo string",
                    command: "echo 'hello_eval_world'",
                    expectedOutcome: EvalExpectedOutcome(
                        description: "Exact hello string",
                        expectedStdout: "hello_eval_world"
                    ),
                    graderType: .deterministicExact,
                    k: 2 // exercises pass^k with k=2
                ),
                EvalTask(
                    id: "eval_mini_02_trace",
                    title: "Trace Verification Task",
                    prompt: "Verify telemetry trace",
                    expectedOutcome: EvalExpectedOutcome(
                        description: "File search tool trace event",
                        expectedTraceEvents: [
                            ExpectedTraceEventRequirement(
                                kind: .toolCall,
                                toolName: "file_search",
                                status: "success"
                            )
                        ]
                    ),
                    graderType: .deterministicTrace,
                    k: 1
                )
            ]
        )

        let report = try await harness.runSuite(suite: miniSuite, judge: judge)
        #expect(report.suiteId == "apex-mini-eval-suite")
        #expect(report.isHarnessPassed == true)
        #expect(report.passToTheKSummary.totalTasks == 2)
        #expect(report.passToTheKSummary.passedTasks == 2)
        #expect(report.passToTheKSummary.passToTheKRate == 1.0)

        // Verify markdown report generation
        let md = report.generateMarkdownReport()
        #expect(md.contains("# 🏆 ApexAgent Outcome-First Eval Harness Report"))
        #expect(md.contains("pass^k Reliability Gate Summary"))
        #expect(md.contains("eval_mini_01_exact"))
    }
}
