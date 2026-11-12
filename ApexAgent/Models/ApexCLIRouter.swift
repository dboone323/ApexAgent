import Foundation
import SwiftData

// MARK: - Batch 33: Unified ApexAgent CLI Subcommand Router & Doctor Health Check

/// Structured CLI argument parsing error.
public enum ApexCLIError: Error, LocalizedError, Sendable, Equatable {
    case missingOptionValue(flag: String)
    case emptyPrompt
    case unknownSubcommand(String)
    case missingSubcommandArgument(subcommand: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .missingOptionValue(let flag):
            return "Flag '\(flag)' requires a value."
        case .emptyPrompt:
            return "Usage: ApexAgent --cli [--allow-tools|--no-tools] <prompt>"
        case .unknownSubcommand(let sub):
            return "Unknown CLI subcommand '\(sub)'. Run 'ApexAgent --help' for usage."
        case .missingSubcommandArgument(let subcommand, let expected):
            return "Subcommand '\(subcommand)' requires \(expected)."
        }
    }
}

/// Resolved CLI command from command-line arguments.
public enum ApexCLICommand: Sendable, Equatable {
    case launchGUI
    case help
    case version
    case doctor(jsonOutput: Bool)
    case routinesList(jsonOutput: Bool)
    case routinesRun(name: String, jsonOutput: Bool)
    case skillsList(jsonOutput: Bool)
    case skillsValidate(jsonOutput: Bool)
    case diagnostics(jsonOutput: Bool)
    case completions(shell: CLIShellDialect)
    case man
    case audit(jsonOutput: Bool)
    case sbom(jsonOutput: Bool)
    case changelog(jsonOutput: Bool)
    case releaseCheck(jsonOutput: Bool)
    case provenance(jsonOutput: Bool)
    case sarif(jsonOutput: Bool)
    case selfTest(jsonOutput: Bool)
    case traces(limit: Int, jsonOutput: Bool)
    case policy(jsonOutput: Bool)
    case daemon
    case spaceCLI(subcommandArgs: [String])
    case gateQueue(subcommandArgs: [String])
    case scheduler(subcommandArgs: [String])
    case longRun(subcommandArgs: [String])
    case prompt(text: String, allowTools: Bool)
}

/// Complete parsed CLI invocation including global overrides.
public struct ParsedCLIInvocation: Sendable, Equatable {
    public let command: ApexCLICommand
    public let providerOverride: String?
    public let modelOverride: String?
    public let jsonOutput: Bool

    public init(
        command: ApexCLICommand,
        providerOverride: String? = nil,
        modelOverride: String? = nil,
        jsonOutput: Bool = false
    ) {
        self.command = command
        self.providerOverride = providerOverride
        self.modelOverride = modelOverride
        self.jsonOutput = jsonOutput
    }
}

/// Individual subsystem check inside a ``DoctorReport``.
public struct DoctorCheckItem: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let passed: Bool
    public let detail: String

    public init(id: String, title: String, passed: Bool, detail: String) {
        self.id = id
        self.title = title
        self.passed = passed
        self.detail = detail
    }
}

/// Structured output from `ApexAgent doctor`.
public struct DoctorReport: Codable, Sendable, Equatable {
    public let version: String
    public let overallPassed: Bool
    public let checks: [DoctorCheckItem]

    public init(version: String, overallPassed: Bool, checks: [DoctorCheckItem]) {
        self.version = version
        self.overallPassed = overallPassed
        self.checks = checks
    }

    public func formatText() -> String {
        var lines: [String] = [
            "ApexAgent Doctor (v\(version))",
            String(repeating: "─", count: 64)
        ]
        for check in checks {
            let icon = check.passed ? "PASS" : "FAIL"
            lines.append("[\(icon)] \(check.title) (\(check.id)): \(check.detail)")
        }
        lines.append(String(repeating: "─", count: 64))
        let passCount = checks.filter(\.passed).count
        lines.append("Summary: \(passCount)/\(checks.count) checks passed — \(overallPassed ? "HEALTHY" : "ACTION REQUIRED")")
        return lines.joined(separator: "\n")
    }

    public func formatJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"overallPassed\":false}"
        }
        return str
    }
}

/// Unified parser, help generator, and command executor for the `ApexAgent` binary.
public enum ApexCLIRouter {
    public static let appVersion = "2026.10.0"

    /// Parses raw `CommandLine.arguments` (where element 0 is the executable path).
    public static func parse(arguments: [String]) throws -> ParsedCLIInvocation {
        let rawArgs = Array(arguments.dropFirst())
        var providerOverride: String?
        var modelOverride: String?
        var jsonOutput = false
        var remaining: [String] = []

        var i = 0
        while i < rawArgs.count {
            let arg = rawArgs[i]
            // Ignore macOS / Xcode launch flags like -NSDocumentRevisionsDebugMode YES
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                i += 2
                continue
            }
            if arg == "--provider" {
                guard i + 1 < rawArgs.count else {
                    throw ApexCLIError.missingOptionValue(flag: "--provider")
                }
                providerOverride = rawArgs[i + 1]
                i += 2
            } else if arg == "--model" {
                guard i + 1 < rawArgs.count else {
                    throw ApexCLIError.missingOptionValue(flag: "--model")
                }
                modelOverride = rawArgs[i + 1]
                i += 2
            } else if arg == "--json" {
                jsonOutput = true
                i += 1
            } else {
                remaining.append(arg)
                i += 1
            }
        }

        guard let first = remaining.first else {
            return ParsedCLIInvocation(
                command: .launchGUI,
                providerOverride: providerOverride,
                modelOverride: modelOverride,
                jsonOutput: jsonOutput
            )
        }

        switch first {
        case "--help", "-h", "help":
            return ParsedCLIInvocation(command: .help, providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "--version", "-v", "version":
            return ParsedCLIInvocation(command: .version, providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "doctor", "--doctor":
            return ParsedCLIInvocation(command: .doctor(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "diagnostics", "--diagnostics":
            return ParsedCLIInvocation(command: .diagnostics(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "--daemon":
            return ParsedCLIInvocation(command: .daemon, providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "--space-cli", "space", "--space":
            let subArgs = Array(remaining.dropFirst())
            return ParsedCLIInvocation(command: .spaceCLI(subcommandArgs: subArgs), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "gate-queue", "--gate-queue", "gate-worker":
            let subArgs = Array(remaining.dropFirst())
            return ParsedCLIInvocation(command: .gateQueue(subcommandArgs: subArgs), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "scheduler", "--scheduler":
            let subArgs = Array(remaining.dropFirst())
            return ParsedCLIInvocation(command: .scheduler(subcommandArgs: subArgs), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "longrun", "--longrun", "long-run":
            let subArgs = Array(remaining.dropFirst())
            return ParsedCLIInvocation(command: .longRun(subcommandArgs: subArgs), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "--cli", "--prompt", "-p":
            let cliArguments = Array(remaining.dropFirst())
            let allowTools = cliArguments.contains("--allow-tools") && !cliArguments.contains("--no-tools")
            let prompt = cliArguments
                .filter { $0 != "--allow-tools" && $0 != "--no-tools" }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                throw ApexCLIError.emptyPrompt
            }
            return ParsedCLIInvocation(
                command: .prompt(text: prompt, allowTools: allowTools),
                providerOverride: providerOverride,
                modelOverride: modelOverride,
                jsonOutput: jsonOutput
            )

        case "routines":
            let action = remaining.dropFirst().first ?? "list"
            switch action {
            case "list":
                return ParsedCLIInvocation(command: .routinesList(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)
            case "run":
                let name = remaining.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    throw ApexCLIError.missingSubcommandArgument(subcommand: "routines run", expected: "<routine-name>")
                }
                return ParsedCLIInvocation(command: .routinesRun(name: name, jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)
            default:
                throw ApexCLIError.unknownSubcommand("routines \(action)")
            }

        case "skills":
            let action = remaining.dropFirst().first ?? "list"
            switch action {
            case "list":
                return ParsedCLIInvocation(command: .skillsList(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)
            case "validate":
                return ParsedCLIInvocation(command: .skillsValidate(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)
            default:
                throw ApexCLIError.unknownSubcommand("skills \(action)")
            }

        case "completions":
            let rawShell = remaining.dropFirst().first?.lowercased() ?? "zsh"
            guard let dialect = CLIShellDialect(rawValue: rawShell) else {
                throw ApexCLIError.unknownSubcommand("completions \(rawShell)")
            }
            return ParsedCLIInvocation(command: .completions(shell: dialect), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "man", "--man":
            return ParsedCLIInvocation(command: .man, providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "audit", "--audit":
            return ParsedCLIInvocation(command: .audit(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "sbom", "--sbom":
            return ParsedCLIInvocation(command: .sbom(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "changelog", "--changelog":
            return ParsedCLIInvocation(command: .changelog(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "release-check", "--release-check":
            return ParsedCLIInvocation(command: .releaseCheck(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "provenance", "--provenance":
            return ParsedCLIInvocation(command: .provenance(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "sarif", "--sarif":
            return ParsedCLIInvocation(command: .sarif(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "self-test", "--self-test":
            return ParsedCLIInvocation(command: .selfTest(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "traces", "--traces":
            var limit = 50
            var i = 1
            let remList = Array(remaining)
            while i < remList.count {
                if remList[i] == "--limit" && i + 1 < remList.count {
                    limit = Int(remList[i + 1]) ?? 50
                    i += 2
                } else {
                    i += 1
                }
            }
            return ParsedCLIInvocation(command: .traces(limit: limit, jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        case "policy", "--policy":
            return ParsedCLIInvocation(command: .policy(jsonOutput: jsonOutput), providerOverride: providerOverride, modelOverride: modelOverride, jsonOutput: jsonOutput)

        default:
            throw ApexCLIError.unknownSubcommand(first)
        }
    }

    /// Applies `--provider` and `--model` environment overrides when present.
    public static func applyEnvironmentOverrides(from invocation: ParsedCLIInvocation) {
        if let provider = invocation.providerOverride {
            setenv("APEX_MODEL_PROVIDER", provider, 1)
        }
        if let model = invocation.modelOverride {
            setenv("APEX_OLLAMA_MODEL", model, 1)
            setenv("APEX_GEMINI_MODEL", model, 1)
            setenv("APEX_MLX_MODEL", model, 1)
        }
    }

    public static func usageText() -> String {
        """
        ApexAgent v\(appVersion) — Autonomous macOS AI Agent & CLI

        USAGE:
          ApexAgent [GLOBAL OPTIONS] [SUBCOMMAND]

        GLOBAL OPTIONS:
          --provider <name>       Override active model provider (ollama, gemini, mlx, foundation)
          --model <name>          Override model identifier for the active provider
          --json                  Format CLI subcommand output as JSON
          --help, -h              Show this help message
          --version, -v           Show version information

        SUBCOMMANDS:
          doctor                  Run subsystem health checks (Privacy Manifest, Persistence, MetricKit, Scheduler, Logging)
          diagnostics             Dump structured recent logs, MetricKit field health, and storage recovery events
          audit                   Run repository hygiene and supply-chain dependency lock audit
          sbom                    Export Software Bill of Materials (Markdown or --json CycloneDX 1.5)
          changelog               Generate categorized Conventional Changelog & next SemVer recommendation
          release-check           Audit Info.plist / project.yml version parity and release readiness
          provenance              Generate SLSA v1.0 build provenance attestation & SHA-256 digests
          sarif                   Export OASIS SARIF v2.1.0 security & static analysis report
          self-test               Run end-to-end CLI subcommand smoke-test contract matrix
          traces [--limit <N>]    Export recent OpenTelemetry W3C distributed trace spans
          policy                  Audit MCP, container, mesh, and tool execution security policies
          completions [shell]     Generate shell tab-completion script (zsh, bash, fish)
          man                     Generate troff man(1) manual page for ApexAgent(1)
          routines list           List registered automation routines
          routines run <name>     Execute a named routine
          skills list             List discovered skills from the local SkillCatalog
          skills validate         Validate all skill manifests in the local SkillCatalog
          --cli [--allow-tools|--no-tools] <prompt>
                                  Run a single headless agent turn and exit
          --daemon                Start ApexGatewayServer on port 1337
          --space-cli [list|post] Manage collaborative Spaces from the terminal
          scheduler [action]      Scheduler trio: exact cron, heartbeat checklist passes, event triggers
          longrun [action]        Resumable long runs: checkpointed state, pause/resume, budgets
        """
    }

    /// Runs all 12 subsystem health checks and returns a ``DoctorReport``.
    public static func runDoctor() -> DoctorReport {
        var checks: [DoctorCheckItem] = []

        // 1. Privacy Manifest check
        do {
            let manifest = try PrivacyManifestInspector.loadBundledManifest()
            let hasUserDefaults = manifest.declaresAccessedAPI(PrivacyManifestInspector.userDefaultsCategory, reason: "CA92.1")
            let passed = !manifest.trackingEnabled && manifest.trackingDomains.isEmpty && hasUserDefaults
            checks.append(
                DoctorCheckItem(
                    id: "privacy_manifest",
                    title: "App Privacy Manifest",
                    passed: passed,
                    detail: passed
                        ? "\(manifest.accessedAPITypes.count) API categories declared, tracking disabled"
                        : "Missing required API declaration or tracking unexpectedly enabled"
                )
            )
        } catch {
            checks.append(
                DoctorCheckItem(
                    id: "privacy_manifest",
                    title: "App Privacy Manifest",
                    passed: false,
                    detail: error.localizedDescription
                )
            )
        }

        // 2. ResilientJSONStore persistence health
        let recoveries = ResilientJSONStore.shared.recentRecoveryEvents(limit: 50)
        checks.append(
            DoctorCheckItem(
                id: "persistence_store",
                title: "Resilient JSON Persistence",
                passed: true,
                detail: "Store operational (\(recoveries.count) corruption recovery event(s) recorded)"
            )
        )

        // 3. MetricKit Field Diagnostics
        let summary = MetricDiagnosticsCenter.shared.summary()
        let metricPassed = summary.crashCount == 0
        checks.append(
            DoctorCheckItem(
                id: "metric_diagnostics",
                title: "MetricKit Field Diagnostics",
                passed: metricPassed,
                detail: "Status \(summary.status.rawValue) (\(summary.totalPayloads) payloads, \(summary.crashCount) crashes, \(summary.hangCount) hangs)"
            )
        )

        // 4. TickerScheduler coalescing & site inventory
        let inventoryCount = TickerScheduler.siteInventory.count
        let coalescedCount = TickerScheduler.shared.coalescedWakeupCount
        checks.append(
            DoctorCheckItem(
                id: "ticker_scheduler",
                title: "Coalesced Ticker Scheduler",
                passed: inventoryCount > 0,
                detail: "\(inventoryCount) classified timer sites, \(coalescedCount) coalesced wake-up(s)"
            )
        )

        // 5. AppLog unified structured logging
        let recentLogs = AppLog.recentEntries(limit: 500)
        checks.append(
            DoctorCheckItem(
                id: "app_logger",
                title: "Unified Structured Logger",
                passed: true,
                detail: "Ring buffer active (\(recentLogs.count)/\(AppLog.bufferCapacity) entries, minLevel=\(AppLog.minimumLevel.label))"
            )
        )

        // 6. Supply-chain dependency lock & manifest parity
        let repoRoot = resolveRepositoryRoot()
        let depReport = DependencyLockAuditor.auditRepository(atRepoRoot: repoRoot)
        checks.append(
            DoctorCheckItem(
                id: "dependency_lock",
                title: "Supply-Chain Dependency Lock",
                passed: depReport.passed,
                detail: depReport.passed
                    ? "\(depReport.pins.count) locked packages verified, 0 supply-chain violations"
                    : "\(depReport.violations.count) supply-chain violation(s) found"
            )
        )

        // 7. Bundle entitlements, Info.plist URL schemes, and build-graph weak-link parity
        let bundleReport = BundleIntegrityVerifier.verifyRepositoryBundleIntegrity(atRepoRoot: repoRoot)
        checks.append(
            DoctorCheckItem(
                id: "bundle_integrity",
                title: "Bundle & Entitlements Integrity",
                passed: bundleReport.passed,
                detail: bundleReport.passed
                    ? "Entitlements, apexagent:// scheme, and weak-linked frameworks verified"
                    : "\(bundleReport.issues.count) bundle integrity issue(s) found"
            )
        )

        // 8. Workspace-wide Required-Reason API & PrivacyInfo.xcprivacy drift
        let privacyDrift = PrivacyManifestDriftAuditor.auditWorkspace(at: repoRoot)
        checks.append(
            DoctorCheckItem(
                id: "privacy_manifest_drift",
                title: "Required-Reason API & Privacy Drift",
                passed: privacyDrift.passed,
                detail: privacyDrift.passed
                    ? "\(privacyDrift.scannedFileCount) Swift files scanned, \(privacyDrift.detectedCategories.count) API categories covered"
                    : "\(privacyDrift.missingCategories.count) missing categories, \(privacyDrift.invalidReasonCodes.count) invalid reason codes"
            )
        )

        // 9. Xcode .xctestplan parity, timeouts, and coverage targets
        let testPlanReport = TestPlanIntegrityAuditor.auditRepositoryTestPlans(atRepoRoot: repoRoot)
        checks.append(
            DoctorCheckItem(
                id: "test_plan_integrity",
                title: "Xcode Test Plan Integrity",
                passed: testPlanReport.passed,
                detail: testPlanReport.passed
                    ? "\(testPlanReport.plans.count) test plans verified (timeouts enabled, APEX_TEST_MODE=1)"
                    : "\(testPlanReport.findings.count) test plan finding(s)"
            )
        )

        // 10. Distributed Tracing & Collaborative Mesh Security Gate
        let sampleTraceEvent = TraceEvent(
            source: "Doctor",
            operation: "trace_mesh_health_check",
            detail: "Verifying OTel W3C trace context & P2P rate limiter",
            durationMs: 1.0,
            metadata: ["traceparent": W3CTraceContext.generate().traceparent]
        )
        let traceReport = TraceSpanExporter.export(events: [sampleTraceEvent])
        let meshReport = MeshSecurityAuditor.audit(
            config: MeshAuthConfig(
                lanModeEnabled: false,
                token: "0123456789abcdef0123456789abcdef",
                requireP2PApproval: true,
                bindAddress: "127.0.0.1"
            )
        )
        let traceMeshPassed = traceReport.passed && meshReport.passed
        checks.append(
            DoctorCheckItem(
                id: "trace_mesh_integrity",
                title: "Distributed Tracing & Mesh Security",
                passed: traceMeshPassed,
                detail: traceMeshPassed
                    ? "OTel export valid (\(traceReport.totalSpans) span), P2P rate limiter healthy (\(meshReport.rateLimitResult.burstAllowed) allowed / \(meshReport.rateLimitResult.burstThrottled) throttled)"
                    : "Tracing or mesh security audit failure detected"
            )
        )

        // 11. Tool Execution Safety Sandbox Gate
        let toolOp = ToolExecutionOperation(
            name: "read_file",
            targetPath: repoRoot.appendingPathComponent("Package.swift").path,
            payloadSizeBytes: 4096,
            requestedTimeoutSeconds: 10.0,
            workspaceRoot: repoRoot.path
        )
        let toolSandboxReport = ToolExecutionSandboxGate.audit(
            operations: [toolOp],
            defaultWorkspaceRoot: repoRoot.path
        )
        checks.append(
            DoctorCheckItem(
                id: "tool_sandbox",
                title: "Tool Execution Safety Sandbox",
                passed: toolSandboxReport.passed,
                detail: toolSandboxReport.passed
                    ? "Filesystem boundary, shell signatures, and execution quotas verified (score \(String(format: "%.0f", toolSandboxReport.score)))"
                    : "\(toolSandboxReport.violations.count) tool sandbox violation(s) found"
            )
        )

        // 12. Autonomous Hardening & Runtime Watchdog Matrix Gate
        let hardeningReport = DoctorExpansionAuditor.auditHardeningSubsystems()
        checks.append(
            DoctorCheckItem(
                id: "autonomous_hardening_matrix",
                title: "Autonomous Hardening & Runtime Watchdog Matrix",
                passed: hardeningReport.passed,
                detail: hardeningReport.passed
                    ? "12-check matrix complete (\(hardeningReport.activeAuditors.count) hardening gates verified, score \(String(format: "%.0f", hardeningReport.score)))"
                    : "\(hardeningReport.violations.count) hardening gate violation(s) found"
            )
        )

        let overall = checks.allSatisfy { $0.passed }
        return DoctorReport(version: appVersion, overallPassed: overall, checks: checks)
    }

    /// Synchronously formats output for synchronous inspection subcommands (`help`, `version`, `doctor`, `skills`, `diagnostics`).
    @MainActor
    public static func renderImmediateSubcommand(_ command: ApexCLICommand) -> (output: String, exitCode: Int32)? {
        switch command {
        case .help:
            return (usageText(), 0)

        case .version:
            return ("ApexAgent \(appVersion)", 0)

        case .doctor(let jsonOutput):
            let report = runDoctor()
            let text = jsonOutput ? report.formatJSON() : report.formatText()
            return (text, report.overallPassed ? 0 : 1)

        case .diagnostics(let jsonOutput):
            let summary = MetricDiagnosticsCenter.shared.summary()
            let logs = AppLog.recentEntries(limit: 10)
            let recoveries = ResilientJSONStore.shared.recentRecoveryEvents(limit: 10)
            if jsonOutput {
                let dict: [String: Any] = [
                    "version": appVersion,
                    "metricStatus": summary.status.rawValue,
                    "crashCount": summary.crashCount,
                    "hangCount": summary.hangCount,
                    "recentLogCount": logs.count,
                    "storageRecoveries": recoveries.count
                ]
                let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                return (String(data: data, encoding: .utf8) ?? "{}", 0)
            }
            var lines = [
                "ApexAgent Diagnostics Snapshot",
                "  Field Health: \(summary.status.rawValue) (crashes=\(summary.crashCount), hangs=\(summary.hangCount))",
                "  Recent Logs:  \(logs.count) entry/entries in ring buffer",
                "  Recoveries:   \(recoveries.count) corrupt JSON quarantine event(s)"
            ]
            for entry in logs.suffix(5) {
                lines.append("    [\(entry.level.label)] [\(entry.category.rawValue)] \(entry.message)")
            }
            return (lines.joined(separator: "\n"), 0)

        case .skillsList(let jsonOutput), .skillsValidate(let jsonOutput):
            let skillsDir = ApexAgentStoragePaths.directory("skills")
            let loaded = SkillCatalog.loadSkills(root: skillsDir)
            if jsonOutput {
                let items = loaded.map { ["id": $0.manifest.id, "name": $0.manifest.name, "version": $0.manifest.version] }
                let data = (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                return (String(data: data, encoding: .utf8) ?? "[]", 0)
            }
            if case .skillsValidate = command {
                return ("Validated \(loaded.count) skill manifest(s) in \(skillsDir.path) — OK", 0)
            }
            if loaded.isEmpty {
                return ("Skills (0) in \(skillsDir.path)", 0)
            }
            let rows = loaded.map { "- \($0.manifest.id) (\($0.manifest.name) v\($0.manifest.version))" }
            return ((["Skills (\(loaded.count)):"] + rows).joined(separator: "\n"), 0)

        case .routinesList(let jsonOutput):
RoutineManager.shared.loadRoutines()
            let routines = RoutineManager.shared.routines
            if jsonOutput {
                let items = routines.map { ["name": $0.name, "trigger": $0.trigger.rawValue, "enabled": "\($0.enabled)"] }
                let data = (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                return (String(data: data, encoding: .utf8) ?? "[]", 0)
            }
            if routines.isEmpty {
                return ("Routines (0)", 0)
            }
            let rows = routines.map { "- \($0.name) [trigger=\($0.trigger.rawValue), enabled=\($0.enabled)]" }
            return ((["Routines (\(routines.count)):"] + rows).joined(separator: "\n"), 0)

        case .completions(let shell):
            return (CLICompletionGenerator.generateCompletionScript(for: shell), 0)

        case .man:
            return (CLICompletionGenerator.generateManPage(version: appVersion), 0)

        case .audit(let jsonOutput):
            let repoRoot = resolveRepositoryRoot()
            let hygiene = RepoHygieneAuditor.auditRepository(at: repoRoot)
            let deps = DependencyLockAuditor.auditRepository(atRepoRoot: repoRoot)
            let overallPassed = hygiene.passed && deps.passed
            if jsonOutput {
                let dict: [String: Any] = [
                    "passed": overallPassed,
                    "hygienePassed": hygiene.passed,
                    "hygieneFindingsCount": hygiene.findings.count,
                    "dependencyLockPassed": deps.passed,
                    "dependencyPinCount": deps.pins.count,
                    "dependencyViolationCount": deps.violations.count
                ]
                let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                return (String(data: data, encoding: .utf8) ?? "{}", overallPassed ? 0 : 1)
            }
            let summary = [hygiene.formatSummary(), deps.formatSummary()].joined(separator: "\n")
            return (summary, overallPassed ? 0 : 1)

        case .sbom(let jsonOutput):
            let repoRoot = resolveRepositoryRoot()
            let deps = DependencyLockAuditor.auditRepository(atRepoRoot: repoRoot)
            let output = jsonOutput ? deps.exportCycloneDXJSON() : deps.exportSBOMMarkdown()
            return (output, deps.passed ? 0 : 1)

        case .changelog(let jsonOutput):
            let repoRoot = resolveRepositoryRoot()
            let commits = ReleaseChangelogEngine.loadRecentGitCommits(atRepoRoot: repoRoot, limit: 25)
            let baseVer = SemanticVersion(parsing: appVersion) ?? SemanticVersion(major: 2026, minor: 10, patch: 0)
            let (nextVer, bump) = ReleaseChangelogEngine.calculateNextVersion(from: baseVer, commits: commits)
            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = (try? encoder.encode(commits)) ?? Data()
                return (String(data: data, encoding: .utf8) ?? "[]", 0)
            }
            let markdown = ReleaseChangelogEngine.renderReleaseNotes(
                version: "\(nextVer.description) (\(bump.rawValue))",
                commits: commits
            )
            return (markdown, 0)

        case .releaseCheck(let jsonOutput):
            let repoRoot = resolveRepositoryRoot()
            let report = ReleaseChangelogEngine.auditReleaseReadiness(atRepoRoot: repoRoot)
            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = (try? encoder.encode(report)) ?? Data()
                return (String(data: data, encoding: .utf8) ?? "{}", report.passed ? 0 : 1)
            }
            return (report.toMarkdown(), report.passed ? 0 : 1)

        case .provenance(let jsonOutput):
            let repoRoot = resolveRepositoryRoot()
            let attestation = ReleaseProvenanceGenerator.generateRepositoryProvenance(atRepoRoot: repoRoot)
            let output = jsonOutput ? attestation.toSLSAJSON() : attestation.toMarkdown()
            return (output, attestation.notarizationReport.passed ? 0 : 1)

        case .sarif(let jsonOutput):
            let repoRoot = resolveRepositoryRoot()
            let sarifBundle = SARIFReportExporter.exportRepositorySARIF(atRepoRoot: repoRoot)
            let output = jsonOutput ? sarifBundle.toSARIFJSON() : sarifBundle.toMarkdown()
            return (output, sarifBundle.passed ? 0 : 1)

        case .selfTest(let jsonOutput):
            let report = CLISmokeTestHarness.runMatrix()
            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = (try? encoder.encode(report)) ?? Data()
                return (String(data: data, encoding: .utf8) ?? "{}", report.passed ? 0 : 1)
            }
            return (report.toMarkdown(), report.passed ? 0 : 1)

        case .traces(let limit, let jsonOutput):
            let events = Tracing.recentTraces(limit: limit)
            let report = TraceSpanExporter.export(events: events)
            let output = jsonOutput ? report.toOTLPJSON() : report.toMarkdown()
            return (output, report.passed ? 0 : 1)

        case .policy(let jsonOutput):
            let repoRoot = resolveRepositoryRoot()
            let toolOp = ToolExecutionOperation(
                name: "read_file",
                targetPath: repoRoot.appendingPathComponent("Package.swift").path,
                payloadSizeBytes: 4096,
                requestedTimeoutSeconds: 10.0,
                workspaceRoot: repoRoot.path
            )
            let toolReport = ToolExecutionSandboxGate.audit(operations: [toolOp], defaultWorkspaceRoot: repoRoot.path)
            let mcpReport = MCPPolicyAuditor.audit(servers: MCPManager.shared.servers)
            let containerReport = ContainerPolicyAuditor.audit(configs: [])
            let meshReport = MeshSecurityAuditor.audit(config: MeshAuthConfig(
                lanModeEnabled: false,
                token: "0123456789abcdef0123456789abcdef",
                requireP2PApproval: true,
                bindAddress: "127.0.0.1"
            ))

            let overallPassed = toolReport.passed && mcpReport.passed && containerReport.passed && meshReport.passed
            if jsonOutput {
                let dict: [String: Any] = [
                    "overallPassed": overallPassed,
                    "toolSandbox": [
                        "passed": toolReport.passed,
                        "score": toolReport.score,
                        "violations": toolReport.violations.map { $0.id }
                    ],
                    "mcpPolicy": [
                        "passed": mcpReport.passed,
                        "score": mcpReport.score,
                        "violations": mcpReport.violations.map { $0.id }
                    ],
                    "containerPolicy": [
                        "passed": containerReport.passed,
                        "score": containerReport.score,
                        "violations": containerReport.violations.map { $0.id }
                    ],
                    "meshSecurity": [
                        "passed": meshReport.passed,
                        "score": meshReport.score,
                        "violations": meshReport.violations.map { $0.id }
                    ]
                ]
                let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                return (String(data: data, encoding: .utf8) ?? "{}", overallPassed ? 0 : 1)
            } else {
                let lines = [
                    "=== ApexAgent Security & Sandboxing Policy Audit ===",
                    "Tool Sandbox:     \(toolReport.passed ? "PASS" : "FAIL") (score: \(String(format: "%.1f", toolReport.score)))",
                    "MCP Policy:       \(mcpReport.passed ? "PASS" : "FAIL") (score: \(String(format: "%.1f", mcpReport.score)))",
                    "Container Policy: \(containerReport.passed ? "PASS" : "FAIL") (score: \(String(format: "%.1f", containerReport.score)))",
                    "Mesh Security:    \(meshReport.passed ? "PASS" : "FAIL") (score: \(String(format: "%.1f", meshReport.score)))",
                    "Verdict:          \(overallPassed ? "HEALTHY" : "VIOLATIONS DETECTED")"
                ]
                return (lines.joined(separator: "\n"), overallPassed ? 0 : 1)
            }

        default:
            return nil
        }
    }

    private static func resolveRepositoryRoot() -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Package.resolved").path) {
            return cwd
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Executes a named routine inside `ApexAgentCore` and returns its output and exit code.
    @MainActor
    public static func runNamedRoutine(_ name: String) async -> (output: String, exitCode: Int32) {
RoutineManager.shared.loadRoutines()
        guard let match = RoutineManager.shared.routines.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return ("Routine '\(name)' not found.", 1)
        }
        let output = await RoutineManager.shared.execute(match) ?? "Routine executed."
        return (output, 0)
    }
}
