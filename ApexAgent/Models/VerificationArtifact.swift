import Foundation

// MARK: - Verification Artifact Kind

/// Distinct categories of verification artifacts produced during execution.
public enum VerificationArtifactKind: String, Codable, Sendable, CaseIterable {
    case plan = "plan"
    case diff = "diff"
    case screenshot = "screenshot"
    case recording = "recording"
    case checklist = "checklist"

    public var displayName: String {
        switch self {
        case .plan: return "Plan"
        case .diff: return "Diff"
        case .screenshot: return "Screenshot"
        case .recording: return "Recording"
        case .checklist: return "Checklist"
        }
    }

    public var systemImage: String {
        switch self {
        case .plan: return "list.bullet.clipboard"
        case .diff: return "arrow.triangle.merge"
        case .screenshot: return "camera"
        case .recording: return "video"
        case .checklist: return "checklist"
        }
    }
}

// MARK: - Verification Artifact Status

/// The evaluation outcome of an artifact.
public enum VerificationArtifactStatus: String, Codable, Sendable, CaseIterable {
    case passed = "passed"
    case failed = "failed"
    case missing = "missing"

    public var displayName: String {
        switch self {
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .missing: return "Missing"
        }
    }
}

// MARK: - Verification Comment

/// A user-attached or reviewer-attached comment on a verification artifact.
public struct VerificationComment: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let author: String
    public let text: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        author: String = "User",
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.timestamp = timestamp
    }
}

// MARK: - Verification Artifact

/// A single verifiable artifact associated with a run and trial execution.
public struct VerificationArtifact: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let runId: String
    public let trialId: String?
    public let kind: VerificationArtifactKind
    public var status: VerificationArtifactStatus
    public var content: String?
    public var path: String?
    public var comments: [VerificationComment]
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        runId: String,
        trialId: String? = nil,
        kind: VerificationArtifactKind,
        status: VerificationArtifactStatus = .passed,
        content: String? = nil,
        path: String? = nil,
        comments: [VerificationComment] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.runId = runId
        self.trialId = trialId
        self.kind = kind
        self.content = content
        self.path = path
        self.comments = comments
        self.metadata = metadata

        // Rule: an artifact with no content (and no existing file at path) is shown as missing, not as passed
        let hasContent = content != nil && !content!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFile = path != nil && !path!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && FileManager.default.fileExists(atPath: path!)
        if !hasContent && !hasFile {
            self.status = .missing
        } else {
            self.status = status
        }
    }

    /// Effective status taking into account content presence.
    public var effectiveStatus: VerificationArtifactStatus {
        let hasContent = content != nil && !content!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFile = path != nil && !path!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && FileManager.default.fileExists(atPath: path!)
        if !hasContent && !hasFile {
            return .missing
        }
        return status
    }
}

// MARK: - Verification Artifact Extractor

/// Extracts verification artifacts from real runtime execution traces and eval harness trials.
public enum VerificationArtifactExtractor {

    /// Extracts verification artifacts from a RunTrace and its events/metadata.
    public static func extractArtifacts(from trace: RunTrace) -> [VerificationArtifact] {
        if !trace.artifacts.isEmpty {
            return trace.artifacts
        }

        var results: [VerificationArtifact] = []

        // 1. Plan artifact
        if let planMeta = trace.metadata["plan"], !planMeta.isEmpty {
            results.append(VerificationArtifact(
                id: "\(trace.id)-plan",
                runId: trace.id,
                kind: .plan,
                status: trace.status == "failed" ? .failed : .passed,
                content: planMeta
            ))
        } else {
            let planPrompts = trace.events.compactMap { ev -> String? in
                if ev.kind == .modelCall, let prompt = ev.promptSummary, !prompt.isEmpty {
                    return prompt
                }
                return nil
            }
            if !planPrompts.isEmpty {
                let planContent = planPrompts.joined(separator: "\n")
                results.append(VerificationArtifact(
                    id: "\(trace.id)-plan",
                    runId: trace.id,
                    kind: .plan,
                    status: .passed,
                    content: planContent
                ))
            }
        }

        // 2. Diff artifact
        if let diffMeta = trace.metadata["diff"], !diffMeta.isEmpty {
            results.append(VerificationArtifact(
                id: "\(trace.id)-diff",
                runId: trace.id,
                kind: .diff,
                status: .passed,
                content: diffMeta
            ))
        } else {
            let diffEvents = trace.events.filter { ev in
                if ev.kind == .toolCall, let t = ev.toolName, ["git_diff", "diff", "apply_patch", "edit_file", "write_file"].contains(t) {
                    return true
                }
                if ev.kind == .memoryWrite { return true }
                return false
            }
            if !diffEvents.isEmpty {
                let diffSummary = diffEvents.map { ev in
                    if let tool = ev.toolName {
                        return "\(tool): args=\(ev.argumentsSummary ?? "") result=\(ev.resultSummary ?? "")"
                    } else if ev.kind == .memoryWrite {
                        return "memoryWrite: [\(ev.memoryTier ?? "")] \(ev.filePath ?? "") (\(ev.bytesTransferred ?? 0) bytes)"
                    }
                    return ev.eventDescription
                }.joined(separator: "\n")
                results.append(VerificationArtifact(
                    id: "\(trace.id)-diff",
                    runId: trace.id,
                    kind: .diff,
                    status: .passed,
                    content: diffSummary
                ))
            }
        }

        // 3. Checklist artifact
        if let checklistMeta = trace.metadata["checklist"], !checklistMeta.isEmpty {
            results.append(VerificationArtifact(
                id: "\(trace.id)-checklist",
                runId: trace.id,
                kind: .checklist,
                status: trace.status == "failed" ? .failed : .passed,
                content: checklistMeta
            ))
        } else {
            let approvalEvents = trace.events.filter { $0.kind == .approval }
            if !approvalEvents.isEmpty {
                let allApproved = approvalEvents.allSatisfy { $0.verdict == "approved" }
                let items = approvalEvents.map { ev in
                    let mark = ev.verdict == "approved" ? "✓" : "✗"
                    return "\(mark) [\(ev.verdict?.uppercased() ?? "")] \(ev.toolName ?? "tool") via \(ev.verdictSource ?? "rule")"
                }.joined(separator: "\n")
                results.append(VerificationArtifact(
                    id: "\(trace.id)-checklist",
                    runId: trace.id,
                    kind: .checklist,
                    status: allApproved ? .passed : .failed,
                    content: items
                ))
            }
        }

        // 4. Screenshot artifact if path in metadata
        if let screenshotPath = trace.metadata["screenshotPath"] ?? trace.metadata["screenshot"], !screenshotPath.isEmpty {
            results.append(VerificationArtifact(
                id: "\(trace.id)-screenshot",
                runId: trace.id,
                kind: .screenshot,
                status: FileManager.default.fileExists(atPath: screenshotPath) ? .passed : .missing,
                path: screenshotPath
            ))
        }

        // 5. Recording artifact if path in metadata
        if let recPath = trace.metadata["recordingPath"] ?? trace.metadata["recording"], !recPath.isEmpty {
            results.append(VerificationArtifact(
                id: "\(trace.id)-recording",
                runId: trace.id,
                kind: .recording,
                status: FileManager.default.fileExists(atPath: recPath) ? .passed : .missing,
                path: recPath
            ))
        }

        return results
    }

    /// Extracts verification artifacts from a real eval trial execution and task.
    public static func extractArtifacts(
        from trial: EvalTrialExecution,
        task: EvalTask,
        verdict: EvalGradeVerdict? = nil
    ) -> [VerificationArtifact] {
        var results: [VerificationArtifact] = []
        let runId = trial.runTrace?.id ?? "trial-\(trial.trialId)"

        // 1. Plan artifact: from task prompt and expected outcome description
        let planContent = """
        Task: \(task.title) [\(task.id)]
        Prompt: \(task.prompt)
        Expected: \(task.expectedOutcome.description)
        """
        results.append(VerificationArtifact(
            id: "\(runId)-plan",
            runId: runId,
            trialId: trial.trialId,
            kind: .plan,
            status: .passed,
            content: planContent
        ))

        // 2. Diff artifact: from trial workspaceFiles
        if !trial.workspaceFiles.isEmpty {
            var diffText = "Modified Files in Trial Workspace (\(trial.workspaceFiles.count)):\n"
            for (path, content) in trial.workspaceFiles.sorted(by: { $0.key < $1.key }) {
                diffText += "--- a/\(path)\n+++ b/\(path)\n"
                diffText += content.components(separatedBy: "\n").map { "+ \($0)" }.joined(separator: "\n")
                diffText += "\n"
            }
            results.append(VerificationArtifact(
                id: "\(runId)-diff",
                runId: runId,
                trialId: trial.trialId,
                kind: .diff,
                status: .passed,
                content: diffText
            ))
        }

        // 3. Checklist artifact: from expected requirements & grading verdict
        var checklistLines: [String] = []
        if let expExit = task.expectedOutcome.expectedExitCode {
            let pass = (trial.exitCode == expExit)
            checklistLines.append("\(pass ? "✓" : "✗") Exit Code \(trial.exitCode) == \(expExit)")
        }
        if let reqFiles = task.expectedOutcome.requiredFilePaths {
            for rf in reqFiles {
                let exists = trial.workspaceFiles[rf] != nil
                checklistLines.append("\(exists ? "✓" : "✗") Required file exists: \(rf)")
            }
        }
        if let verdict = verdict {
            checklistLines.append("\(verdict.isPassed ? "✓" : "✗") Grader: \(task.graderType.rawValue) -> \(verdict.reason)")
        }
        let checklistPassed = verdict?.isPassed ?? (trial.exitCode == 0)
        results.append(VerificationArtifact(
            id: "\(runId)-checklist",
            runId: runId,
            trialId: trial.trialId,
            kind: .checklist,
            status: checklistPassed ? .passed : .failed,
            content: checklistLines.joined(separator: "\n")
        ))

        return results
    }

    /// Extracts verification artifacts from an EvalHarnessReport summary.
    public static func extractArtifacts(from report: EvalHarnessReport) -> [VerificationArtifact] {
        var results: [VerificationArtifact] = []
        let runId = "suite-\(report.suiteId)-v\(report.suiteVersion)"

        // Plan
        let planContent = "Suite ID: \(report.suiteId) (v\(report.suiteVersion))\nTasks in Suite: \(report.passToTheKSummary.totalTasks)\nDuration: \(String(format: "%.2fs", report.duration))"
        results.append(VerificationArtifact(
            id: "\(runId)-plan",
            runId: runId,
            kind: .plan,
            status: .passed,
            content: planContent
        ))

        // Checklist: Pass^k task summary
        var checklistLines: [String] = []
        for taskResult in report.passToTheKSummary.taskResults {
            let mark = taskResult.isPassed ? "✓" : "✗"
            checklistLines.append("\(mark) [\(taskResult.taskId)] pass^\(taskResult.k) (\(taskResult.trialStatusString))")
        }
        results.append(VerificationArtifact(
            id: "\(runId)-checklist",
            runId: runId,
            kind: .checklist,
            status: report.isHarnessPassed ? .passed : .failed,
            content: checklistLines.joined(separator: "\n")
        ))

        return results
    }
}
