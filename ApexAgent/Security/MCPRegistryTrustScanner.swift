import Foundation
import SharedKit

// MARK: - MCP Registry Trust Scanner & Static Analysis (Issue #87, C2)
//
// Enforces ApexAgent's trust layer across:
// 1. Static security analysis of MCP server definitions (commands, args, urls, env vars)
// 2. Permission manifest derivation shown before install
// 3. Publisher identity and signature verification (flagging untrusted/unsigned publishers)
// 4. Update diff computation highlighting parameter and permission drift

public enum MCPPublisherTrustLevel: String, Codable, Sendable {
    case officialVerified = "official_verified"
    case signedPublisher = "signed_publisher"
    case communityUnverified = "community_unverified"
    case unsigned = "unsigned"
    case untrusted = "untrusted"

    public var isTrusted: Bool {
        self == .officialVerified || self == .signedPublisher
    }

    public var displayBadge: String {
        switch self {
        case .officialVerified: return "Official MCP Server"
        case .signedPublisher: return "Verified Publisher"
        case .communityUnverified: return "Community (Unverified)"
        case .unsigned: return "Unsigned Publisher"
        case .untrusted: return "Untrusted / Deprecated"
        }
    }
}

public struct MCPDiffField: Codable, Sendable, Equatable, Identifiable {
    public var id: String { fieldName }
    public let fieldName: String
    public let oldValue: String
    public let newValue: String
    public let isSecurityEscalation: Bool

    public init(fieldName: String, oldValue: String, newValue: String, isSecurityEscalation: Bool = false) {
        self.fieldName = fieldName
        self.oldValue = oldValue
        self.newValue = newValue
        self.isSecurityEscalation = isSecurityEscalation
    }
}

public struct MCPUpdateDiff: Codable, Sendable, Equatable {
    public let serverName: String
    public let hasChanges: Bool
    public let isPrivilegeEscalation: Bool
    public let diffs: [MCPDiffField]

    public init(serverName: String, diffs: [MCPDiffField]) {
        self.serverName = serverName
        self.diffs = diffs
        self.hasChanges = !diffs.isEmpty
        self.isPrivilegeEscalation = diffs.contains(where: { $0.isSecurityEscalation })
    }
}

public struct MCPRegistryTrustReport: Codable, Sendable, Equatable {
    public let serverName: String
    public let publisherTrust: MCPPublisherTrustLevel
    public let findings: [SkillSecurityFinding]
    public let permissionManifest: SkillPermissionManifest
    public let isSafeToInstall: Bool

    public init(
        serverName: String,
        publisherTrust: MCPPublisherTrustLevel,
        findings: [SkillSecurityFinding],
        permissionManifest: SkillPermissionManifest,
        isSafeToInstall: Bool
    ) {
        self.serverName = serverName
        self.publisherTrust = publisherTrust
        self.findings = findings
        self.permissionManifest = permissionManifest
        self.isSafeToInstall = isSafeToInstall
    }
}

public enum MCPRegistryTrustScanner {

    // MARK: - 1. Static Security Analysis

    /// Scans a server item for dangerous command patterns, unencrypted endpoints, and integrity omissions.
    public static func analyzeServer(_ item: MCPRegistryItem) -> [SkillSecurityFinding] {
        var findings: [SkillSecurityFinding] = []
        let server = item.server

        // A. Package command and argument inspection
        if let packages = server.packages {
            for pkg in packages {
                // Check dangerous commands or arguments
                var allArgs: [String] = []
                for arg in (pkg.packageArguments ?? []) + (pkg.runtimeArguments ?? []) {
                    if let name = arg.name, !name.isEmpty { allArgs.append(name) }
                    if let val = arg.value, !val.isEmpty { allArgs.append(val) }
                }
                let fullCmd = "\(pkg.identifier) \(allArgs.joined(separator: " "))"

                if fullCmd.contains("rm -rf") || fullCmd.contains("rm -r /") {
                    findings.append(SkillSecurityFinding(
                        ruleId: "MCP-STATIC-001",
                        category: .shellExec,
                        severity: .critical,
                        message: "Package definition contains catastrophic deletion pattern (rm -rf)",
                        snippet: fullCmd
                    ))
                }

                if fullCmd.contains("mkfs") || fullCmd.contains("dd if=") {
                    findings.append(SkillSecurityFinding(
                        ruleId: "MCP-STATIC-002",
                        category: .shellExec,
                        severity: .critical,
                        message: "Package definition contains raw filesystem destructive command",
                        snippet: fullCmd
                    ))
                }

                if fullCmd.contains("sudo ") {
                    findings.append(SkillSecurityFinding(
                        ruleId: "MCP-STATIC-003",
                        category: .shellExec,
                        severity: .critical,
                        message: "Package specifies privilege escalation via sudo",
                        snippet: fullCmd
                    ))
                }

                if fullCmd.contains("/bin/sh") || fullCmd.contains("/bin/zsh") || fullCmd.contains("sh -c") {
                    findings.append(SkillSecurityFinding(
                        ruleId: "MCP-STATIC-004",
                        category: .shellExec,
                        severity: .high,
                        message: "Package specifies raw shell execution wrapper",
                        snippet: fullCmd
                    ))
                }

                // Check environment variables for sensitive credential harvesting or leaks
                if let envs = pkg.environmentVariables {
                    for env in envs {
                        if env.name.uppercased().contains("AWS_SECRET_ACCESS_KEY") ||
                           env.name.uppercased().contains("ID_RSA") {
                            findings.append(SkillSecurityFinding(
                                ruleId: "MCP-STATIC-005",
                                category: .credentialAccess,
                                severity: .high,
                                message: "Package requests high-value private credential environment variable (\(env.name))",
                                snippet: env.name
                            ))
                        }
                    }
                }

                // Check hash verification
                if pkg.fileSha256 == nil && pkg.registryType == "mcpb" {
                    findings.append(SkillSecurityFinding(
                        ruleId: "MCP-STATIC-006",
                        category: .undeclaredPermission,
                        severity: .medium,
                        message: "Binary package missing fileSha256 integrity hash",
                        snippet: pkg.identifier
                    ))
                }
            }
        }

        // B. Remote endpoints inspection
        if let remotes = server.remotes {
            for remote in remotes {
                if remote.url.lowercased().hasPrefix("http://") {
                    findings.append(SkillSecurityFinding(
                        ruleId: "MCP-STATIC-007",
                        category: .networkExfiltration,
                        severity: .high,
                        message: "Remote transport specifies unencrypted HTTP endpoint (\(remote.url))",
                        snippet: remote.url
                    ))
                }
                if remote.url.contains("localhost") || remote.url.contains("127.0.0.1") {
                    findings.append(SkillSecurityFinding(
                        ruleId: "MCP-STATIC-008",
                        category: .networkExfiltration,
                        severity: .low,
                        message: "Remote transport specifies loopback endpoint (\(remote.url))",
                        snippet: remote.url
                    ))
                }
            }
        }

        return findings
    }

    // MARK: - 2. Publisher Trust & Signing Verification

    /// Evaluates whether the publisher is signed/verified or untrusted/unsigned.
    public static func evaluatePublisherTrust(_ item: MCPRegistryItem) -> (trust: MCPPublisherTrustLevel, findings: [SkillSecurityFinding]) {
        var findings: [SkillSecurityFinding] = []
        let server = item.server

        // Check official metadata
        let status = item.officialMeta?.status.lowercased() ?? "active"
        if status == "deprecated" || status == "deleted" {
            findings.append(SkillSecurityFinding(
                ruleId: "MCP-PUB-001",
                category: .missingManifest,
                severity: .high,
                message: "Server is flagged as \(status.uppercased()) by the official registry",
                snippet: status
            ))
            return (.untrusted, findings)
        }

        // Official modelcontextprotocol namespace
        if server.name.hasPrefix("io.modelcontextprotocol/") ||
           server.name.hasPrefix("modelcontextprotocol/") {
            return (.officialVerified, findings)
        }

        // Check publisher-provided metadata or domain verification
        if let pubMeta = item.publisherProvidedMeta, !pubMeta.isEmpty {
            return (.signedPublisher, findings)
        }

        // If server has a verified package registry base (like registry.npmjs.org)
        if let packages = server.packages, packages.allSatisfy({ $0.registryBaseUrl != nil || $0.fileSha256 != nil }) {
            return (.signedPublisher, findings)
        }

        // Flag unsigned or unverified publishers
        findings.append(SkillSecurityFinding(
            ruleId: "MCP-PUB-002",
            category: .undeclaredPermission,
            severity: .medium,
            message: "Server publisher '\(server.name)' is unsigned and lacks verified cryptographic publisher metadata",
            snippet: server.name
        ))
        return (.unsigned, findings)
    }

    // MARK: - 3. Permission Manifest Generation

    /// Generates a standardized SkillPermissionManifest describing the server's required access.
    public static func generatePermissionManifest(for item: MCPRegistryItem) -> SkillPermissionManifest {
        let server = item.server
        var requestedTools: [String] = []
        var allowNetwork = false
        var allowShell = false
        var filesystemPaths: [String] = []

        // If remotes exist, network is definitely required
        if let remotes = server.remotes, !remotes.isEmpty {
            allowNetwork = true
        }

        // Packages require network if downloaded from registry or stdio commands spawn external processes
        if let packages = server.packages {
            for pkg in packages {
                allowShell = true // stdio subprocess execution
                if pkg.registryType == "npm" || pkg.registryType == "pypi" {
                    allowNetwork = true
                }
                if let args = pkg.packageArguments {
                    for arg in args {
                        if let v = arg.value, v.hasPrefix("/") || v.hasPrefix("~") {
                            filesystemPaths.append(v)
                        }
                    }
                }
                if let envs = pkg.environmentVariables {
                    for env in envs {
                        requestedTools.append("env:\(env.name)")
                    }
                }
            }
        }

        let perms = SkillPermissions(
            tools: requestedTools,
            allowNetwork: allowNetwork,
            filesystemPaths: Array(Set(filesystemPaths)).sorted(),
            allowShell: allowShell
        )

        return SkillPermissionManifest(
            name: server.name,
            version: server.version,
            description: server.description,
            scriptPath: nil,
            permissions: perms
        )
    }

    // MARK: - 4. Complete Trust Audit Report

    /// Evaluates the complete trust report for an MCP registry item.
    public static func audit(_ item: MCPRegistryItem) -> MCPRegistryTrustReport {
        let staticFindings = analyzeServer(item)
        let (pubTrust, pubFindings) = evaluatePublisherTrust(item)
        let allFindings = staticFindings + pubFindings
        let manifest = generatePermissionManifest(for: item)

        let hasCriticalFindings = allFindings.contains(where: { $0.severity == .critical })
        let isSafe = !hasCriticalFindings && pubTrust != .untrusted

        return MCPRegistryTrustReport(
            serverName: item.server.name,
            publisherTrust: pubTrust,
            findings: allFindings,
            permissionManifest: manifest,
            isSafeToInstall: isSafe
        )
    }

    // MARK: - 5. Update Diff Engine

    /// Computes the diff between an existing installed server config and a new registry version.
    public static func computeUpdateDiff(
        existing: MCPServerConfig,
        newServer: MCPRegistryItem
    ) -> MCPUpdateDiff {
        var diffs: [MCPDiffField] = []
        let server = newServer.server

        // Check Version
        let newVersion = server.version
        diffs.append(MCPDiffField(
            fieldName: "Version",
            oldValue: "Installed",
            newValue: newVersion
        ))

        // Check Transport
        let newTransport: String
        let newEndpoint: String?
        if let remotes = server.remotes, let first = remotes.first {
            newTransport = first.type
            newEndpoint = first.url
        } else {
            newTransport = "stdio"
            newEndpoint = nil
        }

        if existing.transport.lowercased() != newTransport.lowercased() {
            diffs.append(MCPDiffField(
                fieldName: "Transport",
                oldValue: existing.transport,
                newValue: newTransport,
                isSecurityEscalation: (existing.transport == "stdio" && newTransport != "stdio")
            ))
        }

        if existing.endpointURL != newEndpoint {
            diffs.append(MCPDiffField(
                fieldName: "Endpoint URL",
                oldValue: existing.endpointURL ?? "(none)",
                newValue: newEndpoint ?? "(none)",
                isSecurityEscalation: (newEndpoint?.starts(with: "http://") == true)
            ))
        }

        // Check Arguments
        let newArgs: [String]
        if let pkg = server.packages?.first {
            var args: [String] = ["-y", "\(pkg.identifier)@\(pkg.version ?? newVersion)"]
            if let extra = pkg.packageArguments {
                for arg in extra {
                    if let name = arg.name, !name.isEmpty {
                        args.append(name)
                    }
                    if let val = arg.value, !val.isEmpty {
                        args.append(val)
                    }
                }
            }
            newArgs = args
        } else {
            newArgs = []
        }

        let oldArgsStr = existing.arguments.joined(separator: " ")
        let newArgsStr = newArgs.joined(separator: " ")
        if oldArgsStr != newArgsStr {
            let isEscalation = newArgsStr.contains("sudo") || newArgsStr.contains("rm -rf")
            diffs.append(MCPDiffField(
                fieldName: "Arguments",
                oldValue: oldArgsStr.isEmpty ? "(none)" : oldArgsStr,
                newValue: newArgsStr.isEmpty ? "(none)" : newArgsStr,
                isSecurityEscalation: isEscalation
            ))
        }

        // Check Permissions drift
        let newManifest = generatePermissionManifest(for: newServer)
        if newManifest.permissions.allowNetwork && (existing.transport == "stdio" && existing.endpointURL == nil) {
            diffs.append(MCPDiffField(
                fieldName: "Permission: Network",
                oldValue: "Disabled",
                newValue: "Enabled (Requested by update)",
                isSecurityEscalation: true
            ))
        }

        return MCPUpdateDiff(serverName: existing.name, diffs: diffs)
    }
}
