import Foundation

// MARK: - MCP Tool Permissions & Host Sandboxing Security Gate (Batch 52)

/// Severity of an MCP policy violation.
public enum MCPViolationSeverity: String, Codable, Sendable, Comparable {
    case info = "INFO"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case critical = "CRITICAL"

    private var rank: Int {
        switch self {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: MCPViolationSeverity, rhs: MCPViolationSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A specific rule violation detected during MCP policy auditing.
public struct MCPPolicyViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(serverName):\(ruleId):\(message)" }
    public let serverName: String
    public let ruleId: String
    public let severity: MCPViolationSeverity
    public let message: String
    public let remediation: String

    public init(
        serverName: String,
        ruleId: String,
        severity: MCPViolationSeverity,
        message: String,
        remediation: String
    ) {
        self.serverName = serverName
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// The aggregated report of an MCP policy security audit.
public struct MCPPolicyAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedServers: Int
    public let violations: [MCPPolicyViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        evaluatedServers: Int,
        violations: [MCPPolicyViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedServers = evaluatedServers
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## MCP Tool Permissions & Sandboxing Policy Audit (`\(badge)`)",
            "",
            "- **Compliance Score**: `\(String(format: "%.1f", score))/100.0`",
            "- **Servers Evaluated**: `\(evaluatedServers)`",
            "- **Violations Detected**: `\(violations.count)`",
            ""
        ]

        if !violations.isEmpty {
            lines.append("### Violations")
            lines.append("| Server | Rule ID | Severity | Violation | Remediation |")
            lines.append("| :--- | :--- | :---: | :--- | :--- |")
            for v in violations {
                lines.append("| `\(v.serverName)` | `\(v.ruleId)` | `\(v.severity.rawValue)` | \(v.message) | \(v.remediation) |")
            }
            lines.append("")
        }

        if !recommendations.isEmpty {
            lines.append("### Hardening Recommendations")
            for r in recommendations {
                lines.append("- \(r)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

/// Security auditor for Model Context Protocol (MCP) server configurations.
public enum MCPPolicyAuditor {
    private static let forbiddenShellCommands: Set<String> = [
        "bash", "sh", "zsh", "csh", "tcsh", "fish", "sudo", "su", "pkexec"
    ]

    private static let sensitivePathPrefixes: [String] = [
        "/etc", "/var", "/private/etc", "/System", "/usr/bin", "/usr/sbin",
        "~/.ssh", "~/.aws", "~/.gnupg", "~/.kube", "~/.config"
    ]

    /// Evaluates an array of MCP server configurations against sandbox and security policies.
    public static func audit(servers: [MCPServerConfig]) -> MCPPolicyAuditReport {
        var violations: [MCPPolicyViolation] = []
        var recommendations: [String] = []

        for server in servers {
            violations.append(contentsOf: auditServer(server))
        }

        // Calculate score (100 base, deduction based on violation severity)
        var deduction = 0.0
        for v in violations {
            switch v.severity {
            case .critical: deduction += 35.0
            case .high: deduction += 20.0
            case .medium: deduction += 10.0
            case .low: deduction += 5.0
            case .info: deduction += 1.0
            }
        }

        let finalScore = max(0.0, 100.0 - deduction)
        let hasCriticalOrHigh = violations.contains(where: { $0.severity == .critical || $0.severity == .high })
        let passed = finalScore >= 70.0 && !hasCriticalOrHigh

        if !violations.isEmpty {
            recommendations.append("Enforce least-privilege directory mounting for all filesystem MCP servers.")
            recommendations.append("Disallow raw interactive shell commands as MCP entrypoints; use targeted wrappers.")
            recommendations.append("Require TLS (HTTPS/WSS) for all non-loopback network transports.")
        } else {
            recommendations.append("All MCP server configurations comply with sandbox baseline policies.")
        }

        return MCPPolicyAuditReport(
            passed: passed,
            score: finalScore,
            evaluatedServers: servers.count,
            violations: violations,
            recommendations: recommendations
        )
    }

    /// Evaluates an individual server configuration.
    public static func auditServer(_ server: MCPServerConfig) -> [MCPPolicyViolation] {
        var issues: [MCPPolicyViolation] = []

        // 1. Command validation
        let trimmedCommand = server.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCommand.isEmpty {
            issues.append(
                MCPPolicyViolation(
                    serverName: server.name,
                    ruleId: "mcp_empty_command",
                    severity: .critical,
                    message: "Command executable is blank or undefined.",
                    remediation: "Provide a valid executable path or binary name."
                )
            )
        } else {
            let binaryName = URL(fileURLWithPath: trimmedCommand).lastPathComponent.lowercased()
            if forbiddenShellCommands.contains(binaryName) {
                issues.append(
                    MCPPolicyViolation(
                        serverName: server.name,
                        ruleId: "mcp_unconstrained_shell",
                        severity: .critical,
                        message: "Executable '\(binaryName)' executes an unconstrained shell directly.",
                        remediation: "Invoke the target tool binary directly instead of wrapping in a bare shell."
                    )
                )
            }
        }

        // 2. Transport & Network endpoint security
        let transport = server.transport.lowercased()
        if transport == "sse" || transport == "http" || transport == "websocket" || transport == "ws" {
            if let endpoint = server.endpointURL, let url = URL(string: endpoint) {
                let scheme = url.scheme?.lowercased() ?? ""
                let host = url.host?.lowercased() ?? ""
                let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"

                if scheme == "http" && !isLoopback {
                    issues.append(
                        MCPPolicyViolation(
                            serverName: server.name,
                            ruleId: "mcp_insecure_transport_scheme",
                            severity: .high,
                            message: "Cleartext HTTP transport configured for non-loopback host '\(host)'.",
                            remediation: "Upgrade endpoint URL to HTTPS/TLS."
                        )
                    )
                } else if scheme != "https" && scheme != "wss" && !isLoopback {
                    issues.append(
                        MCPPolicyViolation(
                            serverName: server.name,
                            ruleId: "mcp_unknown_transport_scheme",
                            severity: .medium,
                            message: "Insecure or unrecognized protocol scheme '\(scheme)'.",
                            remediation: "Use https:// or wss:// for remote MCP endpoints."
                        )
                    )
                }
            } else {
                issues.append(
                    MCPPolicyViolation(
                        serverName: server.name,
                        ruleId: "mcp_missing_endpoint_url",
                        severity: .high,
                        message: "Network transport '\(server.transport)' configured without an endpoint URL.",
                        remediation: "Specify an endpoint URL or change transport to 'stdio'."
                    )
                )
            }
        }

        // 3. Filesystem Sandboxing & Sensitive Directory Traversal
        for arg in server.arguments {
            let lower = arg.lowercased()
            if lower == "/" {
                issues.append(
                    MCPPolicyViolation(
                        serverName: server.name,
                        ruleId: "mcp_root_filesystem_mount",
                        severity: .critical,
                        message: "Server mounts root filesystem ('/') directly.",
                        remediation: "Restrict allowed filesystem access to a specific project directory."
                    )
                )
            }

            for prefix in sensitivePathPrefixes {
                let p = prefix.lowercased()
                let isMatch: Bool
                if p.hasPrefix("~") {
                    let suffix = p.replacingOccurrences(of: "~", with: "")
                    isMatch = lower.hasPrefix(p) || lower.contains(suffix)
                } else {
                    isMatch = lower == p || lower.hasPrefix(p + "/")
                }

                if isMatch {
                    issues.append(
                        MCPPolicyViolation(
                            serverName: server.name,
                            ruleId: "mcp_sensitive_path_exposure",
                            severity: .high,
                            message: "Argument exposes sensitive system or user credential directory '\(arg)'.",
                            remediation: "Isolate MCP directory access to non-sensitive project paths."
                        )
                    )
                    break
                }
            }

            // Flag suspicious eval/command arguments
            if arg == "-c" || arg == "-e" || arg.contains("eval ") {
                issues.append(
                    MCPPolicyViolation(
                        serverName: server.name,
                        ruleId: "mcp_inline_eval_argument",
                        severity: .high,
                        message: "Server argument specifies inline script evaluation ('\(arg)').",
                        remediation: "Pass arguments as structured parameter arrays to dedicated binaries."
                    )
                )
            }
        }

        return issues
    }
}
