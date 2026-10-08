import Foundation

// MARK: - Automation Workflows 21–25 (Batch 45: Code Coverage Gate, Privacy Drift, Release Changelog/SemVer & SLSA Provenance)

extension ApexWorkflows {

    private static var loop6RepoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: 21 — Code coverage threshold & changed-file diff gate
    static func workflow21() async -> WorkflowResult {
        let name = "Code coverage threshold & changed-file diff gate"
        let sampleLLVMCov = """
        {
          "data": [
            {
              "totals": {
                "lines": { "count": 400, "covered": 340, "percent": 85.0 },
                "functions": { "count": 60, "covered": 54, "percent": 90.0 }
              },
              "files": [
                {
                  "filename": "/workspace/ApexAgent/Models/CodeCoverageGate.swift",
                  "summary": {
                    "lines": { "count": 120, "covered": 108, "percent": 90.0 },
                    "functions": { "count": 12, "covered": 11, "percent": 91.67 }
                  }
                }
              ]
            }
          ]
        }
        """
        guard let snapshot = try? CodeCoverageGate.parseCoverageJSON(Data(sampleLLVMCov.utf8)) else {
            return WorkflowResult(id: 21, name: name, passed: false, evidence: "parse_failed")
        }
        let evaluation = CodeCoverageGate.evaluate(
            snapshot: snapshot,
            changedFilePaths: ["ApexAgent/Models/CodeCoverageGate.swift"],
            minimumOverallLineCoverage: 70.0,
            minimumOverallFunctionCoverage: 75.0,
            minimumChangedFileCoverage: 80.0
        )
        return WorkflowResult(
            id: 21,
            name: name,
            passed: evaluation.passed,
            evidence: String(
                format: "line=%.1f%% func=%.1f%% changedPassed=%d/%d",
                evaluation.overallLineCoveragePercent,
                evaluation.overallFunctionCoveragePercent,
                evaluation.evaluatedChangedFiles.count - evaluation.underCoveredChangedFiles.count,
                evaluation.evaluatedChangedFiles.count
            )
        )
    }

    // MARK: 22 — Privacy manifest & Required-Reason API drift audit
    static func workflow22() async -> WorkflowResult {
        let name = "Privacy manifest & Required-Reason API drift audit"
        let report = PrivacyManifestDriftAuditor.auditWorkspace(at: loop6RepoRootURL)
        return WorkflowResult(
            id: 22,
            name: name,
            passed: report.passed,
            evidence: "scanned=\(report.scannedFileCount) categories=\(report.detectedCategories.count) missing=\(report.missingCategories.count)"
        )
    }

    // MARK: 23 — Conventional Changelog & SemVer bump calculator
    static func workflow23() async -> WorkflowResult {
        let name = "Conventional Changelog & SemVer bump calculator"
        let commits = ReleaseChangelogEngine.parseLogLines([
            "b9212c9|feat(ci): add CodeCoverageGate for llvm-cov/xccov thresholds",
            "601ba4b|feat(security): add PrivacyManifestDriftAuditor for Required-Reason APIs",
            "a8ccc99|fix(cli): align release-check JSON output formatting",
        ])
        let base = SemanticVersion(major: 2026, minor: 10, patch: 0)
        let (nextVer, bump) = ReleaseChangelogEngine.calculateNextVersion(from: base, commits: commits)
        let notes = ReleaseChangelogEngine.renderReleaseNotes(version: nextVer.description, commits: commits)
        let passed = bump == .minor
            && nextVer == SemanticVersion(major: 2026, minor: 11, patch: 0)
            && notes.contains("### Features")
            && notes.contains("### Security & Supply Chain")
        return WorkflowResult(
            id: 23,
            name: name,
            passed: passed,
            evidence: "base=\(base) next=\(nextVer) bump=\(bump.rawValue) commits=\(commits.count)"
        )
    }

    // MARK: 24 — Release version parity & readiness gate
    static func workflow24() async -> WorkflowResult {
        let name = "Release version parity & readiness gate"
        let report = ReleaseChangelogEngine.auditReleaseReadiness(atRepoRoot: loop6RepoRootURL)
        return WorkflowResult(
            id: 24,
            name: name,
            passed: report.passed,
            evidence: "shortVer=\(report.shortVersionString) build=\(report.bundleVersion) next=\(report.nextSuggestedVersion)"
        )
    }

    // MARK: 25 — SLSA v1.0 build provenance & notarization verification
    static func workflow25() async -> WorkflowResult {
        let name = "SLSA v1.0 build provenance & notarization verification"
        let attestation = ReleaseProvenanceGenerator.generateRepositoryProvenance(atRepoRoot: loop6RepoRootURL)
        let slsaJSON = attestation.toSLSAJSON()
        let passed = attestation.notarizationReport.passed
            && attestation.subjects.count == 6
            && slsaJSON.contains("https://slsa.dev/provenance/v1")
        return WorkflowResult(
            id: 25,
            name: name,
            passed: passed,
            evidence: "subjects=\(attestation.subjects.count) notarizationReady=\(attestation.notarizationReport.passed)"
        )
    }
}
