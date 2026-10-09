import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 33 — Unified ApexAgent CLI Subcommand Router & Doctor Tests", .serialized)
struct ApexCLIRouterTests {

    @Test("Full CLI argument parsing matrix resolves commands, global flags, and structured errors")
    func cliArgumentParsingMatrix() throws {
        // Default GUI launch (including macOS launch arguments)
        let gui = try ApexCLIRouter.parse(arguments: ["/path/to/ApexAgent", "-NSDocumentRevisionsDebugMode", "YES"])
        #expect(gui.command == .launchGUI)
        #expect(gui.providerOverride == nil)
        #expect(!gui.jsonOutput)

        // Help & Version
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "--help"]).command == .help)
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "-v"]).command == .version)

        // Doctor with global flags
        let doctor = try ApexCLIRouter.parse(arguments: ["ApexAgent", "--provider", "gemini", "--model", "gemini-2.5-pro", "--json", "doctor"])
        #expect(doctor.command == .doctor(jsonOutput: true))
        #expect(doctor.providerOverride == "gemini")
        #expect(doctor.modelOverride == "gemini-2.5-pro")
        #expect(doctor.jsonOutput)

        // Routines & Skills subcommands
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "routines", "list"]).command == .routinesList(jsonOutput: false))
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "routines", "run", "Morning", "Triage"]).command == .routinesRun(name: "Morning Triage", jsonOutput: false))
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "--json", "skills", "validate"]).command == .skillsValidate(jsonOutput: true))
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "diagnostics"]).command == .diagnostics(jsonOutput: false))

        // Traces subcommand
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "traces"]).command == .traces(limit: 50, jsonOutput: false))
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "--json", "traces", "--limit", "100"]).command == .traces(limit: 100, jsonOutput: true))

        // Policy subcommand
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "policy"]).command == .policy(jsonOutput: false))
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "--json", "policy"]).command == .policy(jsonOutput: true))

        // Daemon, Space CLI, and Headless Prompt
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "--daemon"]).command == .daemon)
        #expect(try ApexCLIRouter.parse(arguments: ["ApexAgent", "--space-cli", "list"]).command == .spaceCLI(subcommandArgs: ["list"]))
        let prompt = try ApexCLIRouter.parse(arguments: ["ApexAgent", "--cli", "--allow-tools", "Summarize", "repo"])
        #expect(prompt.command == .prompt(text: "Summarize repo", allowTools: true))

        // Error cases
        #expect(throws: ApexCLIError.emptyPrompt) {
            _ = try ApexCLIRouter.parse(arguments: ["ApexAgent", "--cli", "--allow-tools"])
        }
        #expect(throws: ApexCLIError.missingOptionValue(flag: "--provider")) {
            _ = try ApexCLIRouter.parse(arguments: ["ApexAgent", "--provider"])
        }
        #expect(throws: ApexCLIError.missingSubcommandArgument(subcommand: "routines run", expected: "<routine-name>")) {
            _ = try ApexCLIRouter.parse(arguments: ["ApexAgent", "routines", "run"])
        }
        #expect(throws: ApexCLIError.unknownSubcommand("nonexistent")) {
            _ = try ApexCLIRouter.parse(arguments: ["ApexAgent", "nonexistent"])
        }
    }

    @Test("ApexCLIRouter.runDoctor executes all 12 real subsystem checks and formats text and JSON reports")
    func doctorRunsSubsystemChecksAndFormatsOutput() throws {
        let report = ApexCLIRouter.runDoctor()
        #expect(report.version == ApexCLIRouter.appVersion)
        #expect(report.checks.count == 12)
        #expect(report.checks.map(\.id) == [
            "privacy_manifest",
            "persistence_store",
            "metric_diagnostics",
            "ticker_scheduler",
            "app_logger",
            "dependency_lock",
            "bundle_integrity",
            "privacy_manifest_drift",
            "test_plan_integrity",
            "trace_mesh_integrity",
            "tool_sandbox",
            "autonomous_hardening_matrix"
        ])
        #expect(report.overallPassed)

        let textOutput = report.formatText()
        #expect(textOutput.contains("ApexAgent Doctor"))
        #expect(textOutput.contains("[PASS] App Privacy Manifest"))
        #expect(textOutput.contains("12/12 checks passed — HEALTHY"))

        let jsonString = report.formatJSON()
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: Data(jsonString.utf8))
        #expect(decoded == report)
    }

    @Test("renderImmediateSubcommand renders help, version, doctor, diagnostics, skills, routines, and traces")
    @MainActor
    func renderImmediateSubcommands() throws {
        let help = try #require(ApexCLIRouter.renderImmediateSubcommand(.help))
        #expect(help.exitCode == 0)
        #expect(help.output.contains("SUBCOMMANDS:"))

        let version = try #require(ApexCLIRouter.renderImmediateSubcommand(.version))
        #expect(version.exitCode == 0)
        #expect(version.output == "ApexAgent \(ApexCLIRouter.appVersion)")

        let diagJSON = try #require(ApexCLIRouter.renderImmediateSubcommand(.diagnostics(jsonOutput: true)))
        #expect(diagJSON.exitCode == 0)
        let parsedDiag = try #require(try JSONSerialization.jsonObject(with: Data(diagJSON.output.utf8)) as? [String: Any])
        #expect(parsedDiag["version"] as? String == ApexCLIRouter.appVersion)

        let skillsVal = try #require(ApexCLIRouter.renderImmediateSubcommand(.skillsValidate(jsonOutput: false)))
        #expect(skillsVal.exitCode == 0)
        #expect(skillsVal.output.contains("Validated"))

        let routinesOut = try #require(ApexCLIRouter.renderImmediateSubcommand(.routinesList(jsonOutput: true)))
        #expect(routinesOut.exitCode == 0)
        #expect(routinesOut.output.hasPrefix("["))

        let tracesMD = try #require(ApexCLIRouter.renderImmediateSubcommand(.traces(limit: 10, jsonOutput: false)))
        #expect(tracesMD.exitCode == 0)
        #expect(tracesMD.output.contains("Distributed Trace & OTel Export"))

        let tracesJSON = try #require(ApexCLIRouter.renderImmediateSubcommand(.traces(limit: 10, jsonOutput: true)))
        #expect(tracesJSON.exitCode == 0)
        #expect(tracesJSON.output.contains("resourceSpans"))

        let policyMD = try #require(ApexCLIRouter.renderImmediateSubcommand(.policy(jsonOutput: false)))
        #expect(policyMD.exitCode == 0)
        #expect(policyMD.output.contains("Security & Sandboxing Policy Audit"))

        let policyJSON = try #require(ApexCLIRouter.renderImmediateSubcommand(.policy(jsonOutput: true)))
        #expect(policyJSON.exitCode == 0)
        #expect(policyJSON.output.contains("toolSandbox"))
    }
}
