import Foundation
import Testing
@testable import ApexAgentCore

@Suite("CLI Smoke-Test Harness & Contract Verifier Tests (Batch 49)", .serialized)
struct CLISmokeTestHarnessTests {

    @Test("Executes full 19-case CLI subcommand contract matrix with 0 failures and valid JSON schemas")
    @MainActor
    func executesFullStandardCLISmokeMatrix() {
        let report = CLISmokeTestHarness.runMatrix()
        #expect(report.passed, "Failed cases: \(report.results.filter { !$0.passed })")
        #expect(report.totalCases == 19)
        #expect(report.passedCases == 19)
        #expect(report.failedCases == 0)
        #expect(report.toMarkdown().contains("CLI Subcommand Smoke-Test Matrix (`PASS`)"))
    }

    @Test("Flags unknown subcommands and non-immediate invocations in custom smoke matrix")
    @MainActor
    func flagsFailingCasesInCustomMatrix() {
        let customCases: [(label: String, arguments: [String])] = [
            ("unknown subcommand", ["ApexAgent", "not-a-command"]),
            ("daemon non-immediate", ["ApexAgent", "--daemon"]),
        ]

        let report = CLISmokeTestHarness.runMatrix(cases: customCases)
        #expect(!report.passed)
        #expect(report.failedCases == 2)
        #expect(report.results[0].exitCode == 64)
        #expect(report.results[1].exitCode == -1)
    }

    @Test("ApexCLIRouter parses and renders self-test subcommand in Markdown and JSON")
    @MainActor
    func cliRouterParsesAndRendersSelfTest() throws {
        let parsed = try ApexCLIRouter.parse(arguments: ["ApexAgent", "--json", "self-test"])
        #expect(parsed.command == .selfTest(jsonOutput: true))

        let rendered = try #require(ApexCLIRouter.renderImmediateSubcommand(.selfTest(jsonOutput: true)))
        #expect(rendered.exitCode == 0)
        let decoded = try JSONDecoder().decode(CLISmokeSuiteReport.self, from: Data(rendered.output.utf8))
        #expect(decoded.passed)
        #expect(decoded.totalCases == 19)
    }
}
