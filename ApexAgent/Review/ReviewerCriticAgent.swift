import Foundation
import SharedModels

// MARK: - Review Artifact & Claim Types (Issue #103, G3)

/// Represents a concrete artifact produced during an execution turn or task.
public struct ReviewArtifact: Codable, Sendable, Equatable {
    public let id: String
    public let path: String
    public let content: String
    public let section: String?

    public init(id: String = UUID().uuidString, path: String, content: String, section: String? = nil) {
        self.id = id
        self.path = path
        self.content = content
        self.section = section
    }
}

/// Represents an explicit claim made in the user request or task goal to be verified against artifacts.
public struct ReviewClaim: Codable, Sendable, Equatable {
    public let id: String
    public let claimText: String
    public let requiredArtifactPath: String?
    public let expectedPattern: String?
    public let contradictionPattern: String?

    public init(
        id: String = UUID().uuidString,
        claimText: String,
        requiredArtifactPath: String? = nil,
        expectedPattern: String? = nil,
        contradictionPattern: String? = nil
    ) {
        self.id = id
        self.claimText = claimText
        self.requiredArtifactPath = requiredArtifactPath
        self.expectedPattern = expectedPattern
        self.contradictionPattern = contradictionPattern
    }
}

/// The input request package for the Reviewer/Critic Agent.
public struct ReviewRequest: Codable, Sendable {
    public let requestDescription: String
    public let claims: [ReviewClaim]
    public let requiredArtifactPaths: [String]
    public let artifacts: [ReviewArtifact]
    public let workspacePath: String?

    public init(
        requestDescription: String,
        claims: [ReviewClaim] = [],
        requiredArtifactPaths: [String] = [],
        artifacts: [ReviewArtifact] = [],
        workspacePath: String? = nil
    ) {
        self.requestDescription = requestDescription
        self.claims = claims
        self.requiredArtifactPaths = requiredArtifactPaths
        self.artifacts = artifacts
        self.workspacePath = workspacePath
    }
}

// MARK: - Verdict & Finding Enums

public enum ReviewVerdict: String, Codable, Sendable, Equatable {
    case pass = "pass"
    case fail = "fail"
}

public enum FindingSeverity: String, Codable, Sendable, Equatable {
    case error = "error"
    case warning = "warning"
}

public enum FindingKind: String, Codable, Sendable, Equatable {
    case unsupportedClaim = "unsupportedClaim"
    case contradictoryArtifact = "contradictoryArtifact"
    case missingRequiredArtifact = "missingRequiredArtifact"
    case evaluationFailure = "evaluationFailure"
}

/// A structured finding citing the artifact and its exact location (file + line, or artifact id + section).
public struct ReviewerFinding: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let artifactPath: String
    public let location: String // e.g. "CacheManager.swift:42" or "artifactId#section"
    public let claim: String
    public let reason: String
    public let severity: FindingSeverity
    public let kind: FindingKind

    public init(
        id: String = UUID().uuidString,
        artifactPath: String,
        location: String,
        claim: String,
        reason: String,
        severity: FindingSeverity = .error,
        kind: FindingKind
    ) {
        self.id = id
        self.artifactPath = artifactPath
        self.location = location
        self.claim = claim
        self.reason = reason
        self.severity = severity
        self.kind = kind
    }
}

/// The final report produced by the Reviewer/Critic Agent.
public struct ReviewReport: Codable, Sendable, Equatable {
    public let verdict: ReviewVerdict
    public let summary: String
    public let findings: [ReviewerFinding]
    public let evaluatedAt: Date

    public var isPassed: Bool { verdict == .pass }

    public init(
        verdict: ReviewVerdict,
        summary: String,
        findings: [ReviewerFinding] = [],
        evaluatedAt: Date = Date()
    ) {
        self.verdict = verdict
        self.summary = summary
        self.findings = findings
        self.evaluatedAt = evaluatedAt
    }
}

// MARK: - Reviewer / Critic Agent

/// An independent agent that verifies artifacts against request claims before work is called done.
/// Implements the Bugbot pattern and mirrors the verify-first-hand rule in-app (Issue #103, G3).
public final class ReviewerAgent: Sendable {

    public init() {}

    /// Evaluates a review request against its artifacts, reusing #111's DeterministicGrader.
    public func review(request: ReviewRequest, recordToTrace: Bool = true) async -> ReviewReport {
        var workspaceFiles: [String: String] = [:]

        // 1. Gather all in-memory artifacts
        for artifact in request.artifacts {
            workspaceFiles[artifact.path] = artifact.content
        }

        // 2. Load disk artifacts if workspacePath is provided or path exists on disk
        var pathsToScan = request.requiredArtifactPaths
        for c in request.claims {
            if let p = c.requiredArtifactPath, !pathsToScan.contains(p) {
                pathsToScan.append(p)
            }
        }
        for relPath in pathsToScan where workspaceFiles[relPath] == nil {
            if let fileURL = resolveFile(named: relPath, workspacePath: request.workspacePath) {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    workspaceFiles[relPath] = content
                }
            }
        }

        var findings: [ReviewerFinding] = []

        // 3. Check for Missing Required Artifacts
        for reqPath in request.requiredArtifactPaths {
            if workspaceFiles[reqPath] == nil {
                findings.append(ReviewerFinding(
                    artifactPath: reqPath,
                    location: "\(reqPath):1",
                    claim: "Required artifact must exist",
                    reason: "Missing required artifact '\(reqPath)' — file was not produced or does not exist on disk",
                    severity: .error,
                    kind: .missingRequiredArtifact
                ))
            }
        }

        // 4. Check Claims against Artifacts (unsupported claims & contradictions)
        for claim in request.claims {
            if let reqPath = claim.requiredArtifactPath {
                guard let content = workspaceFiles[reqPath] else {
                    if !findings.contains(where: { $0.artifactPath == reqPath && $0.kind == .missingRequiredArtifact }) {
                        findings.append(ReviewerFinding(
                            artifactPath: reqPath,
                            location: "\(reqPath):1",
                            claim: claim.claimText,
                            reason: "Claim references artifact '\(reqPath)' which is missing",
                            severity: .error,
                            kind: .unsupportedClaim
                        ))
                    }
                    continue
                }

                // Check expected pattern
                if let expectedPattern = claim.expectedPattern, !content.contains(expectedPattern) {
                    findings.append(ReviewerFinding(
                        artifactPath: reqPath,
                        location: "\(reqPath):1",
                        claim: claim.claimText,
                        reason: "Artifact '\(reqPath)' does not contain expected supporting pattern: '\(expectedPattern)'",
                        severity: .error,
                        kind: .unsupportedClaim
                    ))
                }

                // Check contradiction pattern
                if let contradictionPattern = claim.contradictionPattern, content.contains(contradictionPattern) {
                    let lineNum = locateLineNumber(in: content, matching: contradictionPattern)
                    findings.append(ReviewerFinding(
                        artifactPath: reqPath,
                        location: "\(reqPath):\(lineNum)",
                        claim: claim.claimText,
                        reason: "Artifact contradicts request at line \(lineNum): contains forbidden pattern '\(contradictionPattern)'",
                        severity: .error,
                        kind: .contradictoryArtifact
                    ))
                }
            } else if let expectedPattern = claim.expectedPattern {
                // Global pattern check across all artifacts
                let matching = workspaceFiles.first { $0.value.contains(expectedPattern) }
                if matching == nil {
                    findings.append(ReviewerFinding(
                        artifactPath: "unspecified",
                        location: "request:1",
                        claim: claim.claimText,
                        reason: "No artifact provides supporting evidence for claim: '\(expectedPattern)'",
                        severity: .error,
                        kind: .unsupportedClaim
                    ))
                }
            }

            // Global contradiction check if specified without a required path
            if claim.requiredArtifactPath == nil, let contradictionPattern = claim.contradictionPattern {
                for (path, content) in workspaceFiles where content.contains(contradictionPattern) {
                    let lineNum = locateLineNumber(in: content, matching: contradictionPattern)
                    findings.append(ReviewerFinding(
                        artifactPath: path,
                        location: "\(path):\(lineNum)",
                        claim: claim.claimText,
                        reason: "Artifact contradicts request at line \(lineNum): contains forbidden pattern '\(contradictionPattern)'",
                        severity: .error,
                        kind: .contradictoryArtifact
                    ))
                }
            }
        }

        // 5. Reuse #111's DeterministicGrader for compound structural validation
        var expectedFilesMap: [String: String] = [:]
        for claim in request.claims {
            if let p = claim.requiredArtifactPath, let exp = claim.expectedPattern {
                expectedFilesMap[p] = exp
            }
        }

        let evalExpected = EvalExpectedOutcome(
            description: "Reviewer artifact verification",
            expectedStdout: nil,
            expectedExitCode: nil,
            expectedFiles: expectedFilesMap.isEmpty ? nil : expectedFilesMap,
            requiredFilePaths: request.requiredArtifactPaths.isEmpty ? nil : request.requiredArtifactPaths,
            prohibitedFilePaths: nil,
            expectedTraceEvents: nil
        )

        let trial = EvalTrialExecution(
            trialId: "review-\(UUID().uuidString)",
            taskId: "reviewer-audit",
            trialIndex: 1,
            containerId: "host",
            runTrace: nil,
            stdout: "",
            stderr: "",
            exitCode: 0,
            duration: 0.01,
            workspaceFiles: workspaceFiles
        )

        let grader = DeterministicGrader(mode: .compound)
        if let gradeVerdict = try? await grader.grade(trial: trial, expected: evalExpected), !gradeVerdict.isPassed {
            // If grader caught something that was not already structured above, surface as evaluationFailure
            if findings.isEmpty {
                findings.append(ReviewerFinding(
                    artifactPath: request.requiredArtifactPaths.first ?? "workspace",
                    location: "\(request.requiredArtifactPaths.first ?? "workspace"):1",
                    claim: "Deterministic artifact validation",
                    reason: gradeVerdict.reason,
                    severity: .error,
                    kind: .evaluationFailure
                ))
            }
        }

        // 6. Determine final verdict
        let hasErrors = findings.contains(where: { $0.severity == .error })
        let verdict: ReviewVerdict = hasErrors ? .fail : .pass
        let summary: String
        if verdict == .pass {
            summary = "Review passed with 0 findings. All claims verified."
        } else {
            summary = "Review failed with \(findings.count) finding(s)."
        }

        let report = ReviewReport(
            verdict: verdict,
            summary: summary,
            findings: findings,
            evaluatedAt: Date()
        )

        // 7. Record to telemetry trace (Checkpoint: pass or fail verdict recorded)
        if recordToTrace {
            RunTraceManager.shared.recordReviewCheckpoint(
                verdict: report.verdict.rawValue,
                findingsCount: report.findings.count,
                findingsSummary: report.summary
            )
            if report.verdict == .pass {
                AgentGovernanceManager.shared.recordWorkCompleted(
                    agentId: "reviewer",
                    verifiedRuns: 1
                )
            }
        }

        return report
    }

    /// Helper for reviewing task completion right before calling done in ConfirmCompletionTool.
    public func reviewCompletion(
        summary: String,
        filesModified: String?,
        verificationResults: String?,
        workspacePath: String
    ) async -> ReviewReport {
        var parsedFiles: [String] = []
        if let files = filesModified, !files.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsedFiles = files.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.lowercased() != "none" }
        }

        var artifacts: [ReviewArtifact] = []
        var findings: [ReviewerFinding] = []

        // Verify claimed modified files exist on disk
        for file in parsedFiles {
            if let fileURL = resolveFile(named: file, workspacePath: workspacePath) {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    artifacts.append(ReviewArtifact(path: file, content: content))
                }
            } else {
                findings.append(ReviewerFinding(
                    artifactPath: file,
                    location: "\(file):1",
                    claim: "Modified file must exist on disk",
                    reason: "Claimed file '\(file)' does not exist on disk",
                    severity: .error,
                    kind: .missingRequiredArtifact
                ))
            }
        }

        // Check if summary claims modifications but no files exist or were modified
        let lowerSummary = summary.lowercased()
        let claimsModifications = lowerSummary.contains("implemented")
            || lowerSummary.contains("created")
            || lowerSummary.contains("modified")
            || lowerSummary.contains("added")
        if claimsModifications && parsedFiles.isEmpty {
            findings.append(ReviewerFinding(
                artifactPath: "workspace",
                location: "summary:1",
                claim: "Modifications claimed in summary",
                reason: "Summary claims changes were implemented, but no modified files were reported",
                severity: .error,
                kind: .unsupportedClaim
            ))
        }

        // Check for contradiction between verification results and completion summary
        if let v = verificationResults {
            let lowerV = v.lowercased()
            let hasFailure = lowerV.contains("fail") || lowerV.contains("error") || lowerV.contains("exit 1")
            let summaryClaimsSuccess = lowerSummary.contains("success")
                || lowerSummary.contains("pass")
                || lowerSummary.contains("complete")
            if hasFailure && summaryClaimsSuccess {
                findings.append(ReviewerFinding(
                    artifactPath: "verificationResults",
                    location: "verificationResults:1",
                    claim: "Verification matches completion claim",
                    reason: "Verification results show failures ('\(String(v.prefix(100)))'), contradicting completion summary",
                    severity: .error,
                    kind: .contradictoryArtifact
                ))
            }
        }

        // Run full review pass
        let req = ReviewRequest(
            requestDescription: summary,
            claims: [],
            requiredArtifactPaths: parsedFiles,
            artifacts: artifacts,
            workspacePath: workspacePath
        )

        let initialReport = await review(request: req, recordToTrace: false)
        var allFindings = findings + initialReport.findings
        // Deduplicate findings by (artifactPath, kind)
        var seen = Set<String>()
        allFindings = allFindings.filter { f in
            let key = "\(f.artifactPath)#\(f.kind.rawValue)#\(f.location)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        let verdict: ReviewVerdict = allFindings.contains(where: { $0.severity == .error }) ? .fail : .pass
        let summaryText: String
        if verdict == .pass {
            summaryText = "Review passed with 0 findings. All claims verified."
        } else {
            summaryText = "Review failed with \(allFindings.count) finding(s)."
        }

        let finalReport = ReviewReport(
            verdict: verdict,
            summary: summaryText,
            findings: allFindings,
            evaluatedAt: Date()
        )

        // Record trace event
        RunTraceManager.shared.recordReviewCheckpoint(
            verdict: finalReport.verdict.rawValue,
            findingsCount: finalReport.findings.count,
            findingsSummary: finalReport.summary
        )

        return finalReport
    }

    private func locateLineNumber(in text: String, matching pattern: String) -> Int {
        let lines = text.components(separatedBy: .newlines)
        for (idx, line) in lines.enumerated() {
            if line.contains(pattern) {
                return idx + 1
            }
        }
        return 1
    }

    private func resolveFile(named path: String, workspacePath: String?) -> URL? {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let u = URL(fileURLWithPath: expanded)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }

        let fm = FileManager.default
        let prefixes = ["", "ApexAgent", "ApexAgent/Models", "ApexAgent/Tools", "ApexAgent/Review", "ApexAgent/Views", "ApexAgentTests"]

        if let ws = workspacePath, !ws.isEmpty {
            let wsURL = URL(fileURLWithPath: (ws as NSString).expandingTildeInPath)
            for prefix in prefixes {
                let candidate = prefix.isEmpty ? wsURL.appendingPathComponent(path) : wsURL.appendingPathComponent(prefix).appendingPathComponent(path)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }

        let repoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for prefix in prefixes {
            let candidate = prefix.isEmpty ? repoURL.appendingPathComponent(path) : repoURL.appendingPathComponent(prefix).appendingPathComponent(path)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        let cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath)
        for prefix in prefixes {
            let candidate = prefix.isEmpty ? cwdURL.appendingPathComponent(path) : cwdURL.appendingPathComponent(prefix).appendingPathComponent(path)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        return nil
    }
}
