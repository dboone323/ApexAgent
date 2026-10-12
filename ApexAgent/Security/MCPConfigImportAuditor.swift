//
//  MCPConfigImportAuditor.swift
//  ApexAgent
//
//  Created for Batch 107: Claude Desktop & Cursor MCP Config Importer & Security Auditor.
//

import Foundation

// MARK: - MCP Transport & Entry Models

public enum MCPTransportType: String, Sendable, Codable, Equatable {
    case stdio
    case sse
}

public struct MCPServerEntry: Sendable, Codable, Equatable {
    public let name: String
    public let transportType: MCPTransportType
    public let command: String?
    public let args: [String]
    public let env: [String: String]
    public let url: URL?

    public init(
        name: String,
        transportType: MCPTransportType,
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        url: URL? = nil
    ) {
        self.name = name
        self.transportType = transportType
        self.command = command
        self.args = args
        self.env = env
        self.url = url
    }
}

public struct MCPConfigFile: Sendable, Codable, Equatable {
    public let servers: [String: MCPServerEntry]

    public init(servers: [String: MCPServerEntry]) {
        self.servers = servers
    }
}

// MARK: - Audit Violation & Report

public struct MCPConfigViolation: Sendable, Codable, Equatable {
    public let serverName: String
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(serverName: String, code: String, message: String, isFatal: Bool) {
        self.serverName = serverName
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct MCPConfigAuditReport: Sendable, Codable, Equatable {
    public let totalServersCount: Int
    public let stdioServersCount: Int
    public let remoteSSEServersCount: Int
    public let isCompliant: Bool
    public let securityScore: Double
    public let violations: [MCPConfigViolation]
    public let verifiedServers: [MCPServerEntry]

    public init(
        totalServersCount: Int,
        stdioServersCount: Int,
        remoteSSEServersCount: Int,
        isCompliant: Bool,
        securityScore: Double,
        violations: [MCPConfigViolation],
        verifiedServers: [MCPServerEntry]
    ) {
        self.totalServersCount = totalServersCount
        self.stdioServersCount = stdioServersCount
        self.remoteSSEServersCount = remoteSSEServersCount
        self.isCompliant = isCompliant
        self.securityScore = securityScore
        self.violations = violations
        self.verifiedServers = verifiedServers
    }
}

// MARK: - MCP Config Import Auditor

public struct MCPConfigImportAuditor: Sendable {

    private static let dangerousShellCommands: Set<String> = [
        "sh", "bash", "zsh", "csh", "tcsh", "cmd.exe", "powershell", "pwsh"
    ]

    private static let secretKeyKeywords = [
        "API_KEY", "SECRET", "PASSWORD", "AUTH_TOKEN", "PRIVATE_KEY", "ACCESS_TOKEN"
    ]

    public static func parseAndAudit(jsonString: String) -> (config: MCPConfigFile?, report: MCPConfigAuditReport) {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let fatalReport = MCPConfigAuditReport(
                totalServersCount: 0,
                stdioServersCount: 0,
                remoteSSEServersCount: 0,
                isCompliant: false,
                securityScore: 0.0,
                violations: [MCPConfigViolation(serverName: "global", code: "INVALID_JSON", message: "Config file is not valid JSON.", isFatal: true)],
                verifiedServers: []
            )
            return (nil, fatalReport)
        }

        // Support both {"mcpServers": {...}} (Claude/Cursor) and top-level dictionary
        let serversDict = (root["mcpServers"] as? [String: Any]) ?? root

        var parsedServers: [String: MCPServerEntry] = [:]
        var violations: [MCPConfigViolation] = []
        var stdioCount = 0
        var sseCount = 0

        for (name, value) in serversDict {
            guard let serverDef = value as? [String: Any] else { continue }

            let urlStr = serverDef["url"] as? String
            let command = serverDef["command"] as? String
            let args = (serverDef["args"] as? [String]) ?? []
            let env = (serverDef["env"] as? [String: String]) ?? [:]

            if let urlStr = urlStr, let url = URL(string: urlStr) {
                // Remote SSE Server
                sseCount += 1
                let entry = MCPServerEntry(name: name, transportType: .sse, url: url)

                // Audit Remote Endpoint
                let (ssrfAllowed, ssrfReason) = SSRFGuard.validate(url: url, config: WebReaderConfiguration())
                if !ssrfAllowed {
                    violations.append(MCPConfigViolation(
                        serverName: name,
                        code: "SSRF_DISALLOWED_HOST",
                        message: "Remote MCP server URL '\(url.absoluteString)' blocked: \(ssrfReason ?? "Internal address")",
                        isFatal: true
                    ))
                } else if url.scheme?.lowercased() != "https" && url.host != "localhost" && url.host != "127.0.0.1" {
                    violations.append(MCPConfigViolation(
                        serverName: name,
                        code: "INSECURE_REMOTE_MCP_SCHEME",
                        message: "Remote MCP endpoint '\(url.absoluteString)' must use HTTPS.",
                        isFatal: true
                    ))
                }

                parsedServers[name] = entry

            } else if let command = command {
                // Local Stdio Server
                stdioCount += 1
                let entry = MCPServerEntry(name: name, transportType: .stdio, command: command, args: args, env: env)

                // 1. Audit Command for Shell Wrappers
                let cmdBase = (command as NSString).lastPathComponent.lowercased()
                if dangerousShellCommands.contains(cmdBase) {
                    let hasCommandFlag = args.contains("-c") || args.contains("/c")
                    if hasCommandFlag {
                        violations.append(MCPConfigViolation(
                            serverName: name,
                            code: "ARBITRARY_SHELL_EXECUTION",
                            message: "Server executes arbitrary command string via '\(cmdBase) -c'. Specify the executable directly.",
                            isFatal: true
                        ))
                    } else {
                        violations.append(MCPConfigViolation(
                            serverName: name,
                            code: "INTERACTIVE_SHELL_WRAPPER",
                            message: "Server invokes shell interpreter '\(cmdBase)'. Direct binary invocation is recommended.",
                            isFatal: false
                        ))
                    }
                }

                // 2. Audit Arguments for piped commands
                for arg in args {
                    if arg.contains("|") || arg.contains("curl ") || arg.contains("wget ") {
                        violations.append(MCPConfigViolation(
                            serverName: name,
                            code: "SUSPICIOUS_ARGUMENT_PIPELINE",
                            message: "Argument contains pipe or network download command: '\(arg)'.",
                            isFatal: true
                        ))
                    }
                }

                // 3. Audit Environment for Plaintext Secrets
                for (envKey, envVal) in env {
                    let upperKey = envKey.uppercased()
                    for keyword in secretKeyKeywords {
                        if upperKey.contains(keyword) && !envVal.isEmpty {
                            violations.append(MCPConfigViolation(
                                serverName: name,
                                code: "PLAINTEXT_SECRET_IN_CONFIG",
                                message: "Environment key '\(envKey)' contains hardcoded credentials. Use KeychainManager instead.",
                                isFatal: false
                            ))
                            break
                        }
                    }
                }

                parsedServers[name] = entry
            }
        }

        let totalServers = parsedServers.count
        let fatalCount = violations.filter { $0.isFatal }.count
        let warnCount = violations.filter { !$0.isFatal }.count
        let rawScore = 1.0 - (Double(fatalCount) * 0.4) - (Double(warnCount) * 0.1)
        let score = max(0.0, min(1.0, rawScore))
        let compliant = fatalCount == 0

        let verifiedList = parsedServers.values.sorted(by: { $0.name < $1.name })
        let report = MCPConfigAuditReport(
            totalServersCount: totalServers,
            stdioServersCount: stdioCount,
            remoteSSEServersCount: sseCount,
            isCompliant: compliant,
            securityScore: score,
            violations: violations,
            verifiedServers: verifiedList
        )

        return (MCPConfigFile(servers: parsedServers), report)
    }

    public static func formatMCPConfigReportMarkdown(_ report: MCPConfigAuditReport) -> String {
        var md = "### 🔌 MCP Configuration & Security Import Audit\n\n"
        md += "| Metric | Value | Status |\n"
        md += "|---|---|---|\n"
        md += "| Total Servers | `\(report.totalServersCount)` | 📦 Discovered |\n"
        md += "| Stdio Transports | `\(report.stdioServersCount)` | 💻 Local Process |\n"
        md += "| Remote SSE Transports | `\(report.remoteSSEServersCount)` | 🌐 Network SSE |\n"
        md += "| Compliance | \(report.isCompliant ? "✅ Approved" : "❌ Blocked Violations") | Security Gate |\n"
        md += "| Security Score | `\(Int(report.securityScore * 100))%` | \(report.securityScore >= 0.8 ? "🛡️ Solid" : "⚠️ Needs Review") |\n\n"

        if !report.violations.isEmpty {
            md += "#### Findings\n"
            for v in report.violations {
                let badge = v.isFatal ? "🔴 **[FATAL]**" : "🟡 **[WARN]**"
                md += "- \(badge) **[\(v.serverName)]** `\(v.code)`: \(v.message)\n"
            }
            md += "\n"
        }

        if !report.verifiedServers.isEmpty {
            md += "#### Verified MCP Servers\n"
            for s in report.verifiedServers {
                let transport = s.transportType == .stdio ? "💻 Stdio (`\(s.command ?? "")`)" : "🌐 Remote SSE (`\(s.url?.absoluteString ?? "")`)"
                md += "- **\(s.name)**: \(transport)\n"
            }
        }

        return md
    }
}
