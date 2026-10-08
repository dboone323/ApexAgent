import Foundation

// MARK: - Automation Workflows 16–20 (Batch 40: Supply-Chain SBOM, Git Hooks, CLI Completions, Bundle Integrity & xcresult Trend Gate)

extension ApexWorkflows {

    private static var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: 16 — Supply-chain dependency lock & CycloneDX SBOM self-audit
    static func workflow16() async -> WorkflowResult {
        let name = "Supply-chain dependency lock & SBOM audit"
        let report = DependencyLockAuditor.auditRepository(atRepoRoot: repoRootURL)
        let cyclone = report.exportCycloneDXJSON()
        let hasCycloneHeader = cyclone.contains("\"bomFormat\" : \"CycloneDX\"") || cyclone.contains("\"bomFormat\":\"CycloneDX\"")
        let passed = report.passed && report.pins.count >= 20 && hasCycloneHeader
        return WorkflowResult(
            id: 16,
            name: name,
            passed: passed,
            evidence: "pins=\(report.pins.count) violations=\(report.violations.count) cycloneDX=\(hasCycloneHeader)"
        )
    }

    // MARK: 17 — Git pre-commit & commit-msg hook gate verification
    static func workflow17() async -> WorkflowResult {
        let name = "Git pre-commit & Conventional Commit gate"
        let validMsg = GitHookGate.validateCommitMessage("feat(ci): enforce staged diff and commit-msg hygiene")
        let invalidMsg = GitHookGate.validateCommitMessage("bad commit header without type")
        let cleanStaged = GitHookGate.validateStagedFiles([
            (path: "ApexAgent/Models/Clean.swift", byteSize: 512, content: "import Foundation\n")
        ])
        let dirtyStaged = GitHookGate.validateStagedFiles([
            (path: "build/Test.xcresult/Info.plist", byteSize: 1024, content: nil)
        ])

        let passed = validMsg.passed && !invalidMsg.passed && cleanStaged.passed && !dirtyStaged.passed
        return WorkflowResult(
            id: 17,
            name: name,
            passed: passed,
            evidence: "validMsg=\(validMsg.passed) invalidRejected=\(!invalidMsg.passed) stagedBlocked=\(!dirtyStaged.passed)"
        )
    }

    // MARK: 18 — CLI shell completions (zsh/bash/fish) & troff man(1) generator
    static func workflow18() async -> WorkflowResult {
        let name = "CLI shell completions & man(1) generator"
        let zsh = CLICompletionGenerator.generateCompletionScript(for: .zsh)
        let bash = CLICompletionGenerator.generateCompletionScript(for: .bash)
        let fish = CLICompletionGenerator.generateCompletionScript(for: .fish)
        let man = CLICompletionGenerator.generateManPage()

        let passed = zsh.contains("#compdef ApexAgent apexflow")
            && bash.contains("complete -F _apexagent_completions ApexAgent")
            && fish.contains("complete -c ApexAgent")
            && man.contains(".TH APEXAGENT 1")
        return WorkflowResult(
            id: 18,
            name: name,
            passed: passed,
            evidence: "zsh=\(zsh.count)B bash=\(bash.count)B fish=\(fish.count)B man=\(man.count)B"
        )
    }

    // MARK: 19 — Bundle entitlements, apexagent:// scheme & build-graph weak-link parity
    static func workflow19() async -> WorkflowResult {
        let name = "Bundle entitlements & build-graph parity"
        let report = BundleIntegrityVerifier.verifyRepositoryBundleIntegrity(atRepoRoot: repoRootURL)
        return WorkflowResult(
            id: 19,
            name: name,
            passed: report.passed,
            evidence: "checked=\(report.checkedFiles.count) issues=\(report.issues.count)"
        )
    }

    // MARK: 20 — CI pipeline synchronization & xcresult regression trend gate
    static func workflow20() async -> WorkflowResult {
        let name = "CI pipeline sync & xcresult trend gate"
        let ciReport = CIPipelineValidator.validateRepositoryPipeline(atRepoRoot: repoRootURL)
        let baseline = XCResultSummaryReport(result: "Passed", totalTestCount: 1070, passedTests: 1070, failedTests: 0)
        let current = XCResultSummaryReport(result: "Passed", totalTestCount: 1085, passedTests: 1085, failedTests: 0)
        let timings = [
            TestTimingRecord(identifier: "DependencyLockAuditorTests/liveRepositorySupplyChainAuditPasses", durationSeconds: 0.004),
            TestTimingRecord(identifier: "BundleIntegrityVerifierTests/liveRepositoryBundleIntegrityPasses", durationSeconds: 0.002)
        ]
        let trend = XCResultTrendAnalyzer.compare(baseline: baseline, current: current, timings: timings, maxTestDurationSeconds: 5.0)
        let passed = ciReport.passed && trend.passed && trend.testCountDelta == 15
        return WorkflowResult(
            id: 20,
            name: name,
            passed: passed,
            evidence: "ciSync=\(ciReport.passed) delta=+\(trend.testCountDelta) outliers=\(trend.slowOutliers.count)"
        )
    }
}
