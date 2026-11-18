import Foundation
import SharedModels

// MARK: - Eval Grade Verdict

/// The result of evaluating an execution trial against expected outcomes.
public struct EvalGradeVerdict: Codable, Sendable, Equatable {
    public let isPassed: Bool
    public let score: Double // 0.0 (fail) to 1.0 (pass)
    public let reason: String
    public let details: [String: String]

    public init(
        isPassed: Bool,
        score: Double = 0.0,
        reason: String,
        details: [String: String] = [:]
    ) {
        self.isPassed = isPassed
        self.score = score
        self.reason = reason
        self.details = details
    }

    public static func pass(score: Double = 1.0, reason: String = "Passed all checks", details: [String: String] = [:]) -> EvalGradeVerdict {
        EvalGradeVerdict(isPassed: true, score: score, reason: reason, details: details)
    }

    public static func fail(score: Double = 0.0, reason: String, details: [String: String] = [:]) -> EvalGradeVerdict {
        EvalGradeVerdict(isPassed: false, score: score, reason: reason, details: details)
    }
}

// MARK: - Eval Trial Execution

/// The runtime artifact collected from a single trial execution in the harness.
public struct EvalTrialExecution: Sendable {
    public let trialId: String
    public let taskId: String
    public let trialIndex: Int
    public let containerId: String
    public let runTrace: RunTrace?
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let duration: TimeInterval
    public let workspaceFiles: [String: String] // RelativePath: Content

    public init(
        trialId: String,
        taskId: String,
        trialIndex: Int,
        containerId: String,
        runTrace: RunTrace? = nil,
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        duration: TimeInterval = 0.0,
        workspaceFiles: [String: String] = [:]
    ) {
        self.trialId = trialId
        self.taskId = taskId
        self.trialIndex = trialIndex
        self.containerId = containerId
        self.runTrace = runTrace
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.duration = duration
        self.workspaceFiles = workspaceFiles
    }
}

// MARK: - Eval Grader Protocol

/// Protocol implemented by all evaluators (deterministic and LLM judge).
public protocol EvalGrader: Sendable {
    func grade(trial: EvalTrialExecution, expected: EvalExpectedOutcome) async throws -> EvalGradeVerdict
}

// MARK: - Deterministic Grader

/// Deterministic grader for exact matches, regular expressions, structural traces, and files.
public struct DeterministicGrader: EvalGrader, Sendable {

    public enum Mode: Sendable {
        case exact
        case regex
        case trace
        case fileArtifact
        case compound
    }

    public let mode: Mode

    public init(mode: Mode = .exact) {
        self.mode = mode
    }

    public func grade(trial: EvalTrialExecution, expected: EvalExpectedOutcome) async throws -> EvalGradeVerdict {
        var failureReasons: [String] = []
        var details: [String: String] = [:]

        // 1. Exit code check (if specified)
        if let expectedExit = expected.expectedExitCode {
            if trial.exitCode != expectedExit {
                failureReasons.append("Exit code mismatch: expected \(expectedExit), got \(trial.exitCode)")
            }
            details["exitCode"] = "\(trial.exitCode)"
        }

        // 2. Stdout check
        if let expectedStdout = expected.expectedStdout {
            let normalizedActual = trial.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedExpected = expectedStdout.trimmingCharacters(in: .whitespacesAndNewlines)

            switch mode {
            case .exact, .compound, .fileArtifact:
                if normalizedActual != normalizedExpected && !normalizedActual.contains(normalizedExpected) {
                    failureReasons.append("Stdout does not contain expected output: '\(normalizedExpected)' (got '\(normalizedActual)')")
                }
            case .regex:
                if let regex = try? NSRegularExpression(pattern: expectedStdout, options: [.caseInsensitive]) {
                    let range = NSRange(trial.stdout.startIndex..<trial.stdout.endIndex, in: trial.stdout)
                    if regex.firstMatch(in: trial.stdout, options: [], range: range) == nil {
                        failureReasons.append("Stdout failed regex match pattern: '\(expectedStdout)'")
                    }
                } else if !normalizedActual.contains(normalizedExpected) {
                    failureReasons.append("Regex pattern invalid and fallback substring search failed: '\(expectedStdout)'")
                }
            case .trace:
                break
            }
            details["stdoutSnippet"] = String(normalizedActual.prefix(100))
        }

        // 3. Workspace File checks
        if let expectedFiles = expected.expectedFiles {
            for (relPath, expectedPattern) in expectedFiles {
                guard let content = trial.workspaceFiles[relPath] else {
                    failureReasons.append("Missing expected workspace file: '\(relPath)'")
                    continue
                }
                let normContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let normExpected = expectedPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normContent.contains(normExpected) {
                    failureReasons.append("File '\(relPath)' does not contain expected content: '\(normExpected)'")
                }
            }
        }

        if let requiredPaths = expected.requiredFilePaths {
            for path in requiredPaths {
                if trial.workspaceFiles[path] == nil {
                    failureReasons.append("Required file path absent: '\(path)'")
                }
            }
        }

        if let prohibitedPaths = expected.prohibitedFilePaths {
            for path in prohibitedPaths {
                if trial.workspaceFiles[path] != nil {
                    failureReasons.append("Prohibited file path present in workspace: '\(path)'")
                }
            }
        }

        // 4. Structural RunTrace checks
        if let expectedTraceEvents = expected.expectedTraceEvents {
            if let trace = trial.runTrace {
                for req in expectedTraceEvents {
                    let matchingEvents = trace.events.filter { ev in
                        guard ev.kind == req.kind else { return false }
                        if let tn = req.toolName, ev.toolName != tn { return false }
                        if let v = req.verdict, ev.verdict != v { return false }
                        if let st = req.status, ev.toolStatus != st { return false }
                        if let ac = req.argumentsContains, !(ev.argumentsSummary?.contains(ac) ?? false) { return false }
                        if let rc = req.resultContains, !(ev.resultSummary?.contains(rc) ?? false) { return false }
                        return true
                    }

                    let requiredCount = req.requiredCount ?? 1
                    if matchingEvents.count < requiredCount {
                        failureReasons.append("Trace requirement failed: found \(matchingEvents.count) events for kind \(req.kind.rawValue) (tool: \(req.toolName ?? "*")), required \(requiredCount)")
                    }
                }
            } else {
                failureReasons.append("Trial RunTrace is missing but expectedTraceEvents were specified")
            }
        }

        if failureReasons.isEmpty {
            return EvalGradeVerdict.pass(
                score: 1.0,
                reason: "All deterministic checks passed successfully.",
                details: details
            )
        } else {
            return EvalGradeVerdict.fail(
                score: 0.0,
                reason: failureReasons.joined(separator: "; "),
                details: details
            )
        }
    }
}
