import Foundation
import SharedModels

// MARK: - Eval Trial Result

/// Result of an individual trial run within a task's k trials.
public struct EvalTrialResult: Identifiable, Codable, Sendable, Equatable {
    public var id: String { trialId }
    public let trialId: String
    public let trialIndex: Int
    public let containerId: String
    public let isPassed: Bool
    public let duration: TimeInterval
    public let verdict: EvalGradeVerdict
    public let traceId: String?

    public init(
        trialId: String,
        trialIndex: Int,
        containerId: String,
        isPassed: Bool,
        duration: TimeInterval,
        verdict: EvalGradeVerdict,
        traceId: String? = nil
    ) {
        self.trialId = trialId
        self.trialIndex = trialIndex
        self.containerId = containerId
        self.isPassed = isPassed
        self.duration = duration
        self.verdict = verdict
        self.traceId = traceId
    }
}

// MARK: - Eval Task Gate Result

/// Reliability gate outcome for a single task evaluated with parameter k.
public struct EvalTaskGateResult: Identifiable, Codable, Sendable, Equatable {
    public var id: String { taskId }
    public let taskId: String
    public let taskTitle: String
    /// The named k parameter: the task must pass all k trials to pass the reliability gate.
    public let k: Int
    public let trials: [EvalTrialResult]
    /// Pass^k boolean: True IF AND ONLY IF trials.count == k AND all k trials passed.
    public let isPassed: Bool
    public let trialsPassedCount: Int
    public let trialsTotalCount: Int

    public init(
        taskId: String,
        taskTitle: String,
        k: Int,
        trials: [EvalTrialResult]
    ) {
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.k = k
        self.trials = trials
        self.trialsTotalCount = trials.count
        self.trialsPassedCount = trials.filter { $0.isPassed }.count
        // pass^k rule: all k trials must pass, and trials executed must equal k
        self.isPassed = (trials.count == k) && (self.trialsPassedCount == k)
    }

    public var trialStatusString: String {
        let statuses = trials.map { t in
            "T\(t.trialIndex):\(t.isPassed ? "PASS" : "FAIL")"
        }.joined(separator: ", ")
        return "[\(statuses)]"
    }
}

// MARK: - Pass^k Summary

/// Aggregated summary across all tasks evaluated through the pass^k reliability gate.
public struct PassToTheKSummary: Codable, Sendable, Equatable {
    public let totalTasks: Int
    public let passedTasks: Int
    public let passToTheKRate: Double // 0.0 to 1.0
    public let taskResults: [EvalTaskGateResult]

    public init(taskResults: [EvalTaskGateResult]) {
        self.taskResults = taskResults
        self.totalTasks = taskResults.count
        self.passedTasks = taskResults.filter { $0.isPassed }.count
        self.passToTheKRate = totalTasks > 0 ? (Double(passedTasks) / Double(totalTasks)) : 0.0
    }

    /// Formats the pass^k gate results as a clean Markdown table.
    public func generateMarkdownReport() -> String {
        var md = "### 🛡️ pass^k Reliability Gate Summary\n\n"
        md += "- **Overall pass^k Score**: `\(String(format: "%.1f%%", passToTheKRate * 100))` (\(passedTasks)/\(totalTasks) tasks passed)\n"
        md += "- **Gate Requirement**: Every task must pass all $k$ independent trials to achieve a passing gate verdict.\n\n"
        md += "| Task ID | Task Title | k | Trials Passed | Per-Trial Verdicts | Gate Result |\n"
        md += "|---|---|---|---|---|---|\n"

        for taskRes in taskResults {
            let gateStatus = taskRes.isPassed ? "✅ PASS" : "❌ FAIL"
            let trialStr = taskRes.trialStatusString
            md += "| `\(taskRes.taskId)` | \(taskRes.taskTitle) | `\(taskRes.k)` | `\(taskRes.trialsPassedCount)/\(taskRes.k)` | `\(trialStr)` | \(gateStatus) |\n"
        }

        return md
    }
}

// MARK: - Pass^k Gate Evaluator

public struct PassToTheKGate: Sendable {

    /// Evaluates a single task under the pass^k reliability gate.
    /// Task passes IF AND ONLY IF trials count equals k and every single trial passed.
    public static func evaluateTask(task: EvalTask, trials: [EvalTrialResult]) -> EvalTaskGateResult {
        EvalTaskGateResult(
            taskId: task.id,
            taskTitle: task.title,
            k: task.k,
            trials: trials
        )
    }

    /// Evaluates a collection of task gate results and generates the suite-level pass^k summary.
    public static func evaluateSuite(results: [EvalTaskGateResult]) -> PassToTheKSummary {
        PassToTheKSummary(taskResults: results)
    }
}
