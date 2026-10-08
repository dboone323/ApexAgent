import Foundation
import Testing
@testable import ApexAgentCore

@Suite("SARIF v2.1.0 Report Exporter Tests (Batch 46)")
struct SARIFReportExporterTests {

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Live repository exports clean OASIS SARIF v2.1.0 report with 7 registered rules and 0 findings")
    func liveRepositoryExportsCleanSARIFReport() throws {
        let bundle = SARIFReportExporter.exportRepositorySARIF(atRepoRoot: repoRootURL)
        #expect(bundle.passed, "Unexpected SARIF findings: \(bundle.results)")
        #expect(bundle.rules.count == 7)
        #expect(bundle.results.isEmpty)

        let jsonString = bundle.toSARIFJSON()
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any])
        #expect(parsed["$schema"] as? String == "https://json.schemastore.org/sarif-2.1.0.json")
        #expect(parsed["version"] as? String == "2.1.0")
        let runs = try #require(parsed["runs"] as? [[String: Any]])
        #expect(runs.count == 1)

        #expect(bundle.toMarkdown().contains("SARIF v2.1.0 Static Analysis Summary (`PASS`)"))
    }

    @Test("Maps multi-subsystem findings to canonical APEX-* rule IDs and physical locations")
    func mapsMultiSubsystemFindingsToSARIFRulesAndLocations() throws {
        let hygiene = RepoHygieneReport(
            passed: false,
            checkedFileCount: 10,
            findings: [
                RepoHygieneFinding(category: .leakedSecret, file: "ApexAgent/Config.swift", line: 42, message: "Detected API key")
            ],
            durationMs: 1.5
        )
        let lint = SyntaxLintReport(
            passed: false,
            checkedFiles: ["ApexAgent/Broken.swift"],
            issues: [
                SyntaxLintIssue(kind: .unbalancedDelimiter, file: "ApexAgent/Broken.swift", line: 18, message: "Unclosed brace")
            ],
            durationMs: 0.8
        )
        let deps = DependencyLockAuditReport(
            passed: false,
            pins: [],
            violations: [
                DependencyLockViolation(kind: .insecureRepositoryURL, identity: "evil-pkg", message: "Non-HTTPS URL")
            ],
            checkedFiles: ["Package.resolved"]
        )

        let bundle = SARIFReportExporter.buildBundle(
            hygiene: hygiene,
            syntaxLint: lint,
            dependencyLock: deps
        )
        #expect(!bundle.passed)
        #expect(bundle.results.count == 3)
        #expect(bundle.results.map(\.ruleId) == [
            "APEX-HYGIENE-SECRET",
            "APEX-LINT-SYNTAX",
            "APEX-DEPS-LOCK",
        ])
        #expect(bundle.results[0].artifactURI == "ApexAgent/Config.swift")
        #expect(bundle.results[0].startLine == 42)
        #expect(bundle.toMarkdown().contains("SARIF v2.1.0 Static Analysis Summary (`FAIL`)"))
    }

    @Test("ApexCLIRouter parses and renders sarif subcommand")
    @MainActor
    func cliRouterParsesAndRendersSARIF() throws {
        let parsed = try ApexCLIRouter.parse(arguments: ["ApexAgent", "--json", "sarif"])
        #expect(parsed.command == .sarif(jsonOutput: true))

        let rendered = try #require(ApexCLIRouter.renderImmediateSubcommand(.sarif(jsonOutput: true)))
        #expect(rendered.exitCode == 0)
        #expect(rendered.output.contains("https://json.schemastore.org/sarif-2.1.0.json"))
    }
}
