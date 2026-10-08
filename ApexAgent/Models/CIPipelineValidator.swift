import Foundation

// MARK: - Batch 35: GitHub Actions CI & xcresult Quality Gate Synchronization

/// Parsed representation of `xcrun xcresulttool get test-results summary` JSON output.
public struct XCResultSummaryReport: Codable, Sendable, Equatable {
    public let result: String
    public let totalTestCount: Int
    public let passedTests: Int
    public let failedTests: Int
    public let skippedTests: Int
    public let expectedFailures: Int

    public init(
        result: String,
        totalTestCount: Int,
        passedTests: Int,
        failedTests: Int,
        skippedTests: Int = 0,
        expectedFailures: Int = 0
    ) {
        self.result = result
        self.totalTestCount = totalTestCount
        self.passedTests = passedTests
        self.failedTests = failedTests
        self.skippedTests = skippedTests
        self.expectedFailures = expectedFailures
    }

    /// True when the test bundle executed at least one test, had zero failures, and reported `"Passed"`.
    public var meetsQualityGate: Bool {
        totalTestCount > 0 && failedTests == 0 && result.lowercased() == "passed"
    }

    /// Pass rate in the range `0.0 ... 100.0`.
    public var passRatePercent: Double {
        guard totalTestCount > 0 else { return 0.0 }
        return (Double(passedTests) * 100.0) / Double(totalTestCount)
    }
}

/// Audit result for synchronizing local `Makefile` targets and `.github/workflows/swift.yml` CI stages.
public struct CIPipelineAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let missingWorkflowSteps: [String]
    public let missingMakefileTargets: [String]
    public let checkedFiles: [String]

    public init(
        passed: Bool,
        missingWorkflowSteps: [String],
        missingMakefileTargets: [String],
        checkedFiles: [String]
    ) {
        self.passed = passed
        self.missingWorkflowSteps = missingWorkflowSteps
        self.missingMakefileTargets = missingMakefileTargets
        self.checkedFiles = checkedFiles
    }

    public func formatSummary() -> String {
        if passed {
            return "PASS: CI pipeline & Makefile targets synchronized (\(checkedFiles.joined(separator: ", ")))."
        }
        var parts: [String] = []
        if !missingWorkflowSteps.isEmpty {
            parts.append("missing workflow steps: \(missingWorkflowSteps.joined(separator: ", "))")
        }
        if !missingMakefileTargets.isEmpty {
            parts.append("missing Makefile targets: \(missingMakefileTargets.joined(separator: ", "))")
        }
        return "FAIL: CI pipeline drift detected — \(parts.joined(separator: "; "))"
    }
}

/// Validator that ensures `.github/workflows/swift.yml`, `Makefile`, and `.xcresult` bundles
/// enforce the same pre-push hygiene, diff lint, `apexflow`, and unit test gates.
public enum CIPipelineValidator {

    /// Required command substrings in `.github/workflows/swift.yml`.
    public static let requiredGitHubWorkflowSteps: [String] = [
        "make hygiene",
        "make lint",
        "apexflow",
        "xcodebuild test",
        "xcresult-report.sh"
    ]

    /// Required `.PHONY` / target definitions in `Makefile`.
    public static let requiredMakefileTargets: [String] = [
        "hygiene",
        "lint",
        "syntax-check",
        "format",
        "pre-push",
        "full",
        "ci",
        "test-deep",
        "xcresult-summary"
    ]

    /// Returns any required CI step substrings missing from the given workflow YAML string.
    public static func validateGitHubWorkflowYAML(_ yaml: String) -> [String] {
        requiredGitHubWorkflowSteps.filter { step in
            !yaml.contains(step)
        }
    }

    /// Returns any required targets missing from the given `Makefile` content.
    public static func validateMakefile(_ makefile: String) -> [String] {
        let lines = makefile.components(separatedBy: .newlines)
        var definedTargets: Set<String> = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("\t"), !line.hasPrefix("\t") else {
                continue
            }
            if let colonIndex = trimmed.firstIndex(of: ":") {
                // Skip `:=` or `?=` variable assignments
                let afterColon = trimmed[trimmed.index(after: colonIndex)...]
                if afterColon.hasPrefix("=") { continue }
                let targetName = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                if !targetName.isEmpty && targetName != ".PHONY" {
                    definedTargets.insert(targetName)
                }
            }
        }

        return requiredMakefileTargets.filter { !definedTargets.contains($0) }
    }

    /// Audits `.github/workflows/swift.yml` and `Makefile` under `repoRoot`.
    public static func validateRepositoryPipeline(atRepoRoot repoRoot: URL) -> CIPipelineAuditReport {
        let workflowRel = ".github/workflows/swift.yml"
        let makefileRel = "Makefile"
        let workflowURL = repoRoot.appendingPathComponent(workflowRel)
        let makefileURL = repoRoot.appendingPathComponent(makefileRel)

        let yaml = (try? String(contentsOf: workflowURL, encoding: .utf8)) ?? ""
        let makefile = (try? String(contentsOf: makefileURL, encoding: .utf8)) ?? ""

        let missingSteps = validateGitHubWorkflowYAML(yaml)
        let missingTargets = validateMakefile(makefile)
        let passed = missingSteps.isEmpty && missingTargets.isEmpty

        return CIPipelineAuditReport(
            passed: passed,
            missingWorkflowSteps: missingSteps,
            missingMakefileTargets: missingTargets,
            checkedFiles: [workflowRel, makefileRel]
        )
    }

    /// Parses `xcrun xcresulttool get test-results summary` JSON output into an ``XCResultSummaryReport``.
    public static func parseXCResultSummaryJSON(_ jsonString: String) throws -> XCResultSummaryReport {
        guard let data = jsonString.data(using: .utf8) else {
            throw CocoaError(.coderReadCorrupt)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let result = (obj["result"] as? String) ?? "Unknown"
        let total = (obj["totalTestCount"] as? Int) ?? 0
        let passed = (obj["passedTests"] as? Int) ?? 0
        let failed = (obj["failedTests"] as? Int) ?? 0
        let skipped = (obj["skippedTests"] as? Int) ?? 0
        let expectedFailures = (obj["expectedFailures"] as? Int) ?? 0

        return XCResultSummaryReport(
            result: result,
            totalTestCount: total,
            passedTests: passed,
            failedTests: failed,
            skippedTests: skipped,
            expectedFailures: expectedFailures
        )
    }
}
