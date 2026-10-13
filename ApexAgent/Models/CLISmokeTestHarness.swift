import Foundation

// MARK: - End-to-End CLI Subcommand Smoke-Test Harness & Contract Verifier (Batch 49)

/// Result of executing a single CLI subcommand smoke-test case.
public struct CLISmokeCaseResult: Sendable, Equatable, Codable {
    public let label: String
    public let arguments: [String]
    public let passed: Bool
    public let exitCode: Int32
    public let outputBytes: Int
    public let validJSON: Bool
    public let durationMs: Double
    public let failureReason: String?

    public init(
        label: String,
        arguments: [String],
        passed: Bool,
        exitCode: Int32,
        outputBytes: Int,
        validJSON: Bool,
        durationMs: Double,
        failureReason: String? = nil
    ) {
        self.label = label
        self.arguments = arguments
        self.passed = passed
        self.exitCode = exitCode
        self.outputBytes = outputBytes
        self.validJSON = validJSON
        self.durationMs = durationMs
        self.failureReason = failureReason
    }
}

/// Complete report from running the `CLISmokeTestHarness` subcommand matrix.
public struct CLISmokeSuiteReport: Sendable, Equatable, Codable {
    public let passed: Bool
    public let totalCases: Int
    public let passedCases: Int
    public let failedCases: Int
    public let totalDurationMs: Double
    public let results: [CLISmokeCaseResult]

    public init(
        passed: Bool,
        totalCases: Int,
        passedCases: Int,
        failedCases: Int,
        totalDurationMs: Double,
        results: [CLISmokeCaseResult]
    ) {
        self.passed = passed
        self.totalCases = totalCases
        self.passedCases = passedCases
        self.failedCases = failedCases
        self.totalDurationMs = totalDurationMs
        self.results = results
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## CLI Subcommand Smoke-Test Matrix (`\(badge)`)",
            "",
            String(
                format: "- **Cases Passed**: `%d / %d` (`%.1f ms` total)",
                passedCases,
                totalCases,
                totalDurationMs
            ),
            "",
            "| Case | Exit | Bytes | JSON Valid | Duration (ms) | Status |",
            "| :--- | :---: | :---: | :---: | :---: | :---: |",
        ]
        for item in results {
            lines.append(
                String(
                    format: "| `%@` | %d | %d | %@ | %.2f | %@ |",
                    item.label,
                    item.exitCode,
                    item.outputBytes,
                    item.validJSON ? "YES" : "N/A",
                    item.durationMs,
                    item.passed ? "PASS" : "FAIL"
                )
            )
        }
        return lines.joined(separator: "\n")
    }
}

public enum CLISmokeTestHarness {
    /// Standard matrix of synchronous CLI invocations verified during `ApexAgent self-test`.
    public static let standardMatrix: [(label: String, arguments: [String])] = [
        ("help", ["ApexAgent", "--help"]),
        ("version", ["ApexAgent", "--version"]),
        ("doctor (text)", ["ApexAgent", "doctor"]),
        ("doctor (json)", ["ApexAgent", "--json", "doctor"]),
        ("diagnostics (json)", ["ApexAgent", "--json", "diagnostics"]),
        ("skills validate", ["ApexAgent", "skills", "validate"]),
        ("skills list (json)", ["ApexAgent", "--json", "skills", "list"]),
        ("routines list (json)", ["ApexAgent", "--json", "routines", "list"]),
        ("completions zsh", ["ApexAgent", "completions", "zsh"]),
        ("completions bash", ["ApexAgent", "completions", "bash"]),
        ("completions fish", ["ApexAgent", "completions", "fish"]),
        ("man", ["ApexAgent", "man"]),
        ("audit (json)", ["ApexAgent", "--json", "audit"]),
        ("sbom (json)", ["ApexAgent", "--json", "sbom"]),
        ("changelog (text)", ["ApexAgent", "changelog"]),
        ("changelog (json)", ["ApexAgent", "--json", "changelog"]),
        ("release-check (json)", ["ApexAgent", "--json", "release-check"]),
        ("provenance (json)", ["ApexAgent", "--json", "provenance"]),
        ("sarif (json)", ["ApexAgent", "--json", "sarif"]),
    ]

    /// Runs the full synchronous CLI subcommand matrix and validates exit codes, output non-emptiness, and JSON schemas.
    @MainActor
    public static func runMatrix(
        cases: [(label: String, arguments: [String])] = standardMatrix,
        maxCommandDurationMs: Double = 15000.0
    ) -> CLISmokeSuiteReport {
        var results: [CLISmokeCaseResult] = []
        let suiteStart = DispatchTime.now().uptimeNanoseconds

        for testCase in cases {
            let startNs = DispatchTime.now().uptimeNanoseconds
            let expectsJSON = testCase.arguments.contains("--json")

            do {
                let invocation = try ApexCLIRouter.parse(arguments: testCase.arguments)
                guard let rendered = ApexCLIRouter.renderImmediateSubcommand(invocation.command) else {
                    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
                    results.append(
                        CLISmokeCaseResult(
                            label: testCase.label,
                            arguments: testCase.arguments,
                            passed: false,
                            exitCode: -1,
                            outputBytes: 0,
                            validJSON: false,
                            durationMs: elapsedMs,
                            failureReason: "Subcommand did not return immediate output."
                        )
                    )
                    continue
                }

                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
                let outBytes = rendered.output.utf8.count
                var jsonOK = !expectsJSON
                var failure: String?

                if rendered.exitCode != 0 {
                    failure = "Expected exit code 0, got \(rendered.exitCode)."
                } else if outBytes == 0 {
                    failure = "Subcommand returned empty output."
                } else if expectsJSON {
                    if (try? JSONSerialization.jsonObject(with: Data(rendered.output.utf8))) != nil {
                        jsonOK = true
                    } else {
                        jsonOK = false
                        failure = "Output with --json flag is not valid JSON."
                    }
                }

                if failure == nil && elapsedMs > maxCommandDurationMs {
                    failure = String(format: "Duration %.1fms exceeded %.1fms budget.", elapsedMs, maxCommandDurationMs)
                }

                results.append(
                    CLISmokeCaseResult(
                        label: testCase.label,
                        arguments: testCase.arguments,
                        passed: failure == nil,
                        exitCode: rendered.exitCode,
                        outputBytes: outBytes,
                        validJSON: expectsJSON ? jsonOK : false,
                        durationMs: elapsedMs,
                        failureReason: failure
                    )
                )
            } catch {
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
                results.append(
                    CLISmokeCaseResult(
                        label: testCase.label,
                        arguments: testCase.arguments,
                        passed: false,
                        exitCode: 64,
                        outputBytes: 0,
                        validJSON: false,
                        durationMs: elapsedMs,
                        failureReason: error.localizedDescription
                    )
                )
            }
        }

        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - suiteStart) / 1_000_000.0
        let passedCount = results.filter { $0.passed }.count
        let failedCount = results.count - passedCount

        return CLISmokeSuiteReport(
            passed: failedCount == 0,
            totalCases: results.count,
            passedCases: passedCount,
            failedCases: failedCount,
            totalDurationMs: totalMs,
            results: results
        )
    }
}
