import Foundation

// MARK: - Automation Workflows 26–30 (Batch 50: SARIF v2.1.0, .xctestplan Audit, Footprint Budget, CLI Smoke Matrix & 9-Check Doctor)

extension ApexWorkflows {

    private static var loop7RepoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: 26 — SARIF v2.1.0 security & static analysis report export
    static func workflow26() async -> WorkflowResult {
        let name = "SARIF v2.1.0 security & static analysis report export"
        let bundle = SARIFReportExporter.exportRepositorySARIF(atRepoRoot: loop7RepoRootURL)
        let json = bundle.toSARIFJSON()
        let passed = bundle.passed
            && bundle.rules.count == 7
            && bundle.results.isEmpty
            && json.contains("https://json.schemastore.org/sarif-2.1.0.json")
        return WorkflowResult(
            id: 26,
            name: name,
            passed: passed,
            evidence: "rules=\(bundle.rules.count) findings=\(bundle.results.count) bytes=\(json.utf8.count)"
        )
    }

    // MARK: 27 — Xcode .xctestplan timeout & coverage target audit
    static func workflow27() async -> WorkflowResult {
        let name = "Xcode .xctestplan timeout & coverage target audit"
        let report = TestPlanIntegrityAuditor.auditRepositoryTestPlans(atRepoRoot: loop7RepoRootURL)
        return WorkflowResult(
            id: 27,
            name: name,
            passed: report.passed,
            evidence: "plans=\(report.plans.count) findings=\(report.findings.count)"
        )
    }

    // MARK: 28 — Workspace source complexity & asset footprint gate
    static func workflow28() async -> WorkflowResult {
        let name = "Workspace source complexity & asset footprint gate"
        let report = ArtifactSizeBudgetGate.auditWorkspaceFootprint(atRepoRoot: loop7RepoRootURL)
        return WorkflowResult(
            id: 28,
            name: name,
            passed: report.passed,
            evidence: "swiftFiles=\(report.totalSwiftFiles) lines=\(report.totalSwiftLines) violations=\(report.violations.count)"
        )
    }

    // MARK: 29 — CLI subcommand contract & JSON smoke-test matrix
    static func workflow29() async -> WorkflowResult {
        let name = "CLI subcommand contract & JSON smoke-test matrix"
        let fastCases: [(label: String, arguments: [String])] = [
            ("help", ["ApexAgent", "--help"]),
            ("version", ["ApexAgent", "--version"]),
            ("completions zsh", ["ApexAgent", "completions", "zsh"]),
            ("man", ["ApexAgent", "man"]),
            ("release-check (json)", ["ApexAgent", "--json", "release-check"]),
            ("provenance (json)", ["ApexAgent", "--json", "provenance"]),
        ]
        let report = CLISmokeTestHarness.runMatrix(cases: fastCases)
        return WorkflowResult(
            id: 29,
            name: name,
            passed: report.passed,
            evidence: "passed=\(report.passedCases)/\(report.totalCases) durationMs=\(String(format: "%.1f", report.totalDurationMs))"
        )
    }

    // MARK: 30 — Full 10-check ApexAgent Doctor subsystem verification
    static func workflow30() async -> WorkflowResult {
        let name = "Full 10-check ApexAgent Doctor subsystem verification"
        let report = ApexCLIRouter.runDoctor()
        let passed = report.overallPassed && report.checks.count == 10
        return WorkflowResult(
            id: 30,
            name: name,
            passed: passed,
            evidence: "checks=\(report.checks.filter { $0.passed }.count)/\(report.checks.count) overall=\(report.overallPassed)"
        )
    }
}
