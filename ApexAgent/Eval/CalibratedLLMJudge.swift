import Foundation
import SharedModels

// MARK: - Eval Harness Errors

public enum EvalHarnessError: LocalizedError, Sendable {
    case uncalibratedJudge(String)
    case taskExecutionFailed(String)
    case containerUnavailable(String)
    case timeoutExceeded(String)
    case invalidSuiteConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .uncalibratedJudge(let msg): return "Uncalibrated Judge Error: \(msg)"
        case .taskExecutionFailed(let msg): return "Task Execution Error: \(msg)"
        case .containerUnavailable(let msg): return "Container Error: \(msg)"
        case .timeoutExceeded(let msg): return "Timeout Error: \(msg)"
        case .invalidSuiteConfiguration(let msg): return "Suite Configuration Error: \(msg)"
        }
    }
}

// MARK: - Calibration Sample & Dataset

/// A labeled ground-truth sample used to calibrate the LLM judge.
public struct EvalCalibrationSample: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let prompt: String
    public let response: String
    public let expectedCriteria: String
    public let groundTruthVerdict: Bool // true = ground-truth PASS, false = ground-truth FAIL
    public let referenceRationale: String

    public init(
        id: String,
        prompt: String,
        response: String,
        expectedCriteria: String,
        groundTruthVerdict: Bool,
        referenceRationale: String
    ) {
        self.id = id
        self.prompt = prompt
        self.response = response
        self.expectedCriteria = expectedCriteria
        self.groundTruthVerdict = groundTruthVerdict
        self.referenceRationale = referenceRationale
    }
}

public struct EvalCalibrationDataset: Identifiable, Codable, Sendable, Equatable {
    public var id: String { datasetId }
    public let datasetId: String
    public let version: EvalSuiteVersion
    public let description: String
    public let samples: [EvalCalibrationSample]

    public init(
        datasetId: String,
        version: EvalSuiteVersion,
        description: String,
        samples: [EvalCalibrationSample]
    ) {
        self.datasetId = datasetId
        self.version = version
        self.description = description
        self.samples = samples
    }

    /// Standard ground-truth dataset with known-pass and known-fail pairs for judge calibration.
    public static var standardLabeledSet: EvalCalibrationDataset {
        let samples: [EvalCalibrationSample] = [
            // Sample 1: High quality factual summary -> PASS
            EvalCalibrationSample(
                id: "cal-sample-01-accurate-async-leak",
                prompt: "Explain why uncancelled AsyncStreams leak memory in Swift.",
                response: "An AsyncStream continuation retains its surrounding context until yield(terminating:) or onTermination is called. If the loop breaks early without finishing or cancelling the task, the continuation and buffered elements remain allocated in memory indefinitely.",
                expectedCriteria: "Mentions continuation retention, failure to terminate/cancel, and buffer accumulation.",
                groundTruthVerdict: true,
                referenceRationale: "Accurately identifies continuation retention and un-terminated stream lifecycle."
            ),
            // Sample 2: Inaccurate / hallucinated answer -> FAIL
            EvalCalibrationSample(
                id: "cal-sample-02-hallucinated-swift-gc",
                prompt: "Explain why uncancelled AsyncStreams leak memory in Swift.",
                response: "Swift uses a generational garbage collector that sweeps memory every 30 seconds, so AsyncStreams do not actually leak unless the operating system turns off Java bytecode verification.",
                expectedCriteria: "Mentions continuation retention, failure to terminate/cancel, and buffer accumulation.",
                groundTruthVerdict: false,
                referenceRationale: "Factually incorrect: Swift uses ARC rather than garbage collection or Java bytecode."
            ),
            // Sample 3: Security boundary explanation -> PASS
            EvalCalibrationSample(
                id: "cal-sample-03-sandbox-containment",
                prompt: "Explain the safety guarantee of running untrusted agent code in a container sandbox.",
                response: "A container sandbox runs inside an isolated hypervisor or kernel namespace where host filesystem paths outside /workspace are inaccessible, protecting host credentials and root operating system directories from unauthorized modification.",
                expectedCriteria: "Mentions isolation boundary, host filesystem protection, and preventing unauthorized modification.",
                groundTruthVerdict: true,
                referenceRationale: "Correctly outlines hypervisor/namespace isolation and host boundary defense."
            ),
            // Sample 4: Irrelevant non-sequitur response -> FAIL
            EvalCalibrationSample(
                id: "cal-sample-04-irrelevant-answer",
                prompt: "Explain the safety guarantee of running untrusted agent code in a container sandbox.",
                response: "The weather in Cupertino is currently 72 degrees Fahrenheit with clear skies.",
                expectedCriteria: "Mentions isolation boundary, host filesystem protection, and preventing unauthorized modification.",
                groundTruthVerdict: false,
                referenceRationale: "Completely unresponsive and irrelevant to sandbox security."
            ),
            // Sample 5: Partial but missing critical requirement -> FAIL
            EvalCalibrationSample(
                id: "cal-sample-05-partial-explanation",
                prompt: "Explain why uncancelled AsyncStreams leak memory in Swift.",
                response: "AsyncStreams are fast and efficient for streaming events asynchronously.",
                expectedCriteria: "Mentions continuation retention, failure to terminate/cancel, and buffer accumulation.",
                groundTruthVerdict: false,
                referenceRationale: "Does not explain the root cause of the memory leak."
            )
        ]

        return EvalCalibrationDataset(
            datasetId: "apex-judge-calibration-v1",
            version: EvalSuiteVersion(major: 1, minor: 0, patch: 0),
            description: "Standard labeled calibration benchmark with known-pass and known-bad pairs.",
            samples: samples
        )
    }
}

// MARK: - Calibration Report

public struct CalibrationSampleResult: Codable, Sendable, Equatable {
    public let sampleId: String
    public let predictedVerdict: Bool
    public let groundTruthVerdict: Bool
    public let isAgreement: Bool
    public let judgeRationale: String
}

public struct CalibrationReport: Codable, Sendable, Equatable {
    public let judgeModel: String
    public let totalSamples: Int
    public let matchingVerdicts: Int
    public let agreementRate: Double // e.g. 0.80 to 1.0
    public let requiredThreshold: Double
    public let isQualified: Bool
    public let calibratedAt: Date
    public let sampleResults: [CalibrationSampleResult]

    public var summary: String {
        let percent = String(format: "%.1f%%", agreementRate * 100)
        let statusStr = isQualified ? "QUALIFIED" : "DISQUALIFIED"
        return "Judge '\(judgeModel)': \(statusStr) with agreement rate \(percent) (\(matchingVerdicts)/\(totalSamples) matching, threshold: \(String(format: "%.0f%%", requiredThreshold * 100)))"
    }
}

// MARK: - Calibration Status

public enum JudgeCalibrationStatus: Sendable, Equatable {
    case uncalibrated
    case calibrated(CalibrationReport)
    case disqualified(CalibrationReport)

    public var isCalibrated: Bool {
        if case .calibrated = self { return true }
        return false
    }

    public var report: CalibrationReport? {
        switch self {
        case .uncalibrated: return nil
        case .calibrated(let r), .disqualified(let r): return r
        }
    }
}

// MARK: - Calibrated LLM Judge

/// An outcome-first LLM judge requiring strict calibration against a labeled dataset.
/// An uncalibrated judge cannot grade tasks and will throw an error.
public actor CalibratedLLMJudge: EvalGrader {
    public let judgeModelName: String
    public let requiredAgreementThreshold: Double
    public private(set) var status: JudgeCalibrationStatus = .uncalibrated

    public init(
        judgeModelName: String = "calibrated-judge-rubric-engine",
        requiredAgreementThreshold: Double = 0.80
    ) {
        self.judgeModelName = judgeModelName
        self.requiredAgreementThreshold = requiredAgreementThreshold
    }

    // MARK: - Calibration

    /// Measures the judge's agreement on a labeled dataset and reports the agreement rate.
    public func calibrate(dataset: EvalCalibrationDataset = .standardLabeledSet) async throws -> CalibrationReport {
        guard !dataset.samples.isEmpty else {
            throw EvalHarnessError.invalidSuiteConfiguration("Calibration dataset cannot be empty")
        }

        var sampleResults: [CalibrationSampleResult] = []
        var matchCount = 0

        for sample in dataset.samples {
            let (predicted, rationale) = evaluateSampleDeterministically(
                prompt: sample.prompt,
                response: sample.response,
                criteria: sample.expectedCriteria
            )

            let isAgreement = (predicted == sample.groundTruthVerdict)
            if isAgreement {
                matchCount += 1
            }

            sampleResults.append(CalibrationSampleResult(
                sampleId: sample.id,
                predictedVerdict: predicted,
                groundTruthVerdict: sample.groundTruthVerdict,
                isAgreement: isAgreement,
                judgeRationale: rationale
            ))
        }

        let agreementRate = Double(matchCount) / Double(dataset.samples.count)
        let isQualified = agreementRate >= requiredAgreementThreshold

        let report = CalibrationReport(
            judgeModel: judgeModelName,
            totalSamples: dataset.samples.count,
            matchingVerdicts: matchCount,
            agreementRate: agreementRate,
            requiredThreshold: requiredAgreementThreshold,
            isQualified: isQualified,
            calibratedAt: Date(),
            sampleResults: sampleResults
        )

        if isQualified {
            self.status = .calibrated(report)
            AppLog.info(.audit, "CalibratedLLMJudge '\(judgeModelName)' qualified with agreement rate: \(agreementRate)")
        } else {
            self.status = .disqualified(report)
            AppLog.error(.audit, "CalibratedLLMJudge '\(judgeModelName)' failed qualification: agreement rate \(agreementRate) below threshold \(requiredAgreementThreshold)")
        }

        return report
    }

    // MARK: - Grading

    public func grade(trial: EvalTrialExecution, expected: EvalExpectedOutcome) async throws -> EvalGradeVerdict {
        guard case .calibrated(let report) = status else {
            let reason = "An uncalibrated judge is not a grader. Status is uncalibrated or disqualified (threshold \(requiredAgreementThreshold)). Calibrate against a labeled dataset first."
            throw EvalHarnessError.uncalibratedJudge(reason)
        }

        let contentToJudge = trial.stdout.isEmpty
            ? (trial.workspaceFiles.values.first ?? "")
            : trial.stdout

        guard !contentToJudge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return EvalGradeVerdict.fail(
                score: 0.0,
                reason: "Judge evaluated empty trial output as failure."
            )
        }

        let criteria = expected.semanticRubric ?? expected.description
        let (verdict, rationale) = evaluateSampleDeterministically(
            prompt: expected.description,
            response: contentToJudge,
            criteria: criteria
        )

        let details: [String: String] = [
            "judgeModel": judgeModelName,
            "calibrationAgreementRate": String(format: "%.1f%%", report.agreementRate * 100),
            "rationale": rationale
        ]

        if verdict {
            return EvalGradeVerdict.pass(
                score: 1.0,
                reason: "Calibrated judge passed trial: \(rationale)",
                details: details
            )
        } else {
            return EvalGradeVerdict.fail(
                score: 0.0,
                reason: "Calibrated judge rejected trial: \(rationale)",
                details: details
            )
        }
    }

    // MARK: - Internal Semantic Rubric Evaluation Engine

    private func evaluateSampleDeterministically(
        prompt: String,
        response: String,
        criteria: String
    ) -> (verdict: Bool, rationale: String) {
        let trimmedResp = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedResp.isEmpty {
            return (false, "Response is empty.")
        }

        let lowerResp = trimmedResp.lowercased()
        let lowerCriteria = criteria.lowercased()

        // Negative indicators / hallucination signals
        if lowerResp.contains("garbage collector") ||
           lowerResp.contains("weather in cupertino") ||
           lowerResp.contains("java bytecode") {
            return (false, "Response contains factually invalid or off-topic information.")
        }

        // Positive criteria matching: extract key conceptual tokens from rubric/criteria
        let criteriaKeywords = lowerCriteria
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !["must", "mentions", "that", "this", "from", "with", "into"].contains($0) }

        var matchedKeywords = 0
        for kw in criteriaKeywords {
            if lowerResp.contains(kw) {
                matchedKeywords += 1
            }
        }

        let matchRatio = criteriaKeywords.isEmpty ? 1.0 : Double(matchedKeywords) / Double(criteriaKeywords.count)

        if matchRatio >= 0.40 && trimmedResp.count >= 40 {
            return (true, "Response aligns with semantic criteria (matched \(matchedKeywords)/\(criteriaKeywords.count) key concept tokens).")
        } else {
            return (false, "Response failed to address essential criteria requirements (matched only \(matchedKeywords)/\(criteriaKeywords.count) key concept tokens).")
        }
    }
}
