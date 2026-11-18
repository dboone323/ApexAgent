import Foundation

// MARK: - Skill Security Scanner (Issue #107)
//
// Performs static and structural security analysis on a skill's declared manifest
// and script content during install, registration, and update.
// Catches dangerous patterns:
// - Shell exec (unless declared and approved) & catastrophic shell destruction
// - Outbound network transmission / exfiltration (unless declared and approved)
// - Credential access & secret harvesting (strictly forbidden)
// - Path traversal outside workspace boundary (unless declared and approved)

public enum SkillSecurityCategory: String, Codable, Sendable {
    case shellExec = "shell_exec"
    case networkExfiltration = "network_exfiltration"
    case credentialAccess = "credential_access"
    case pathTraversal = "path_traversal"
    case missingManifest = "missing_manifest"
    case undeclaredPermission = "undeclared_permission"
}

public struct SkillSecurityFinding: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(ruleId):\(category.rawValue):\(severity.rawValue):\(message)" }
    public let ruleId: String
    public let category: SkillSecurityCategory
    public let severity: ToolSandboxSeverity
    public let message: String
    public let snippet: String?

    public init(
        ruleId: String,
        category: SkillSecurityCategory,
        severity: ToolSandboxSeverity,
        message: String,
        snippet: String? = nil
    ) {
        self.ruleId = ruleId
        self.category = category
        self.severity = severity
        self.message = message
        self.snippet = snippet
    }
}

public struct SkillScanResult: Codable, Sendable, Equatable {
    public let passed: Bool
    public let skillName: String
    public let findings: [SkillSecurityFinding]
    public let timestamp: Date

    public init(
        passed: Bool,
        skillName: String,
        findings: [SkillSecurityFinding],
        timestamp: Date = Date()
    ) {
        self.passed = passed
        self.skillName = skillName
        self.findings = findings
        self.timestamp = timestamp
    }
}

public struct SkillSecurityError: Error, LocalizedError, Sendable, Equatable {
    public let findings: [SkillSecurityFinding]

    public init(findings: [SkillSecurityFinding]) {
        self.findings = findings
    }

    public var errorDescription: String? {
        findings.map { "[\($0.severity.rawValue)] \($0.ruleId): \($0.message)" }.joined(separator: "\n")
    }
}

public enum SkillSecurityScanner {

    private static func makeRegex(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern, options: options)) ?? NSRegularExpression()
    }

    // Catastrophic shell destruction patterns — ALWAYS blocked regardless of declared permissions.
    private static let catastrophicShellPatterns: [(regex: NSRegularExpression, ruleId: String, description: String)] = [
        (makeRegex(#"\brm\s+(-[a-z]*\s+)*-[a-z]*[rf]\s+[/~]"#), "SH-CATA-001", "Catastrophic recursive root or home deletion (rm -rf /)"),
        (makeRegex(#"\bmkfs\b"#), "SH-CATA-002", "Disk partition formatting command (mkfs)"),
        (makeRegex(#"\bdd\s+[^|]*\bof=/dev/"#), "SH-CATA-003", "Raw block device overwrite (dd of=/dev/)"),
        (makeRegex(#":\(\)\s*\{.*\}\s*;?\s*:"#), "SH-CATA-004", "Shell fork-bomb denial-of-service attack"),
        (makeRegex(#"\bsudo\s+"#), "SH-CATA-005", "Privilege escalation via sudo"),
        (makeRegex(#"\bchmod\s+(-[a-z]*\s+)*-R\s+777"#), "SH-CATA-006", "Insecure global permission grant (chmod -R 777)"),
        (makeRegex(#">\s*/etc/"#), "SH-CATA-007", "Direct overwrite of system configuration directory"),
        (makeRegex(#">\s*/System/"#), "SH-CATA-008", "Direct overwrite of system root directory")
    ]

    // General shell execution patterns (flagged if allowShell == false)
    private static let shellExecPatterns: [(regex: NSRegularExpression, ruleId: String, description: String)] = [
        (makeRegex(#"\b(sh|bash|zsh)\s+-c\b"#), "SH-EXEC-001", "Subshell command interpolation (sh/bash/zsh -c)"),
        (makeRegex(#"\b(eval|exec)\s+"#), "SH-EXEC-002", "Dynamic command execution via eval or exec"),
        (makeRegex(#"/bin/(sh|bash|zsh)\b"#), "SH-EXEC-003", "Direct interpreter invocation")
    ]

    // Network exfiltration & outbound access patterns (flagged if allowNetwork == false)
    private static let networkPatterns: [(regex: NSRegularExpression, ruleId: String, description: String)] = [
        (makeRegex(#"\b(curl|wget|nc|netcat|ssh|scp|sftp|telnet|nmap)\b"#), "NET-001", "Outbound network CLI utility detected"),
        (makeRegex(#"https?://"#), "NET-002", "HTTP/HTTPS endpoint detected"),
        (makeRegex(#"ftp://"#), "NET-003", "FTP endpoint detected")
    ]

    // Credential access & secret harvesting — ALWAYS blocked regardless of declared permissions.
    private static let credentialPatterns: [(regex: NSRegularExpression, ruleId: String, description: String)] = [
        (makeRegex(#"\.ssh/"#), "CRED-001", "SSH directory access"),
        (makeRegex(#"\b(id_rsa|id_ed25519|authorized_keys)\b"#), "CRED-002", "SSH private or authorized keys access"),
        (makeRegex(#"\.aws/credentials\b"#), "CRED-003", "AWS credentials access"),
        (makeRegex(#"\b(\.netrc|\.npmrc|\.pypirc|\.docker/config\.json)\b"#), "CRED-004", "Package manager or registry credential file access"),
        (makeRegex(#"security\s+find-(generic|internet)-password"#), "CRED-005", "macOS Keychain query via security CLI"),
        (makeRegex(#"\bkeychain\b"#), "CRED-006", "System keychain reference"),
        (makeRegex(#"\b(credentials?\.json|serviceaccount)\b"#), "CRED-007", "Service account or credentials JSON access"),
        (makeRegex(#"(^|[\s/"'@=])\.env(\.|$|["'\s])"#), "CRED-008", "Environment secrets file access (.env)")
    ]

    // Path traversal outside workspace boundary
    private static let pathTraversalPatterns: [(regex: NSRegularExpression, ruleId: String, description: String)] = [
        (makeRegex(#"\.\./\.\."#), "PATH-001", "Directory traversal sequence (../..)"),
        (makeRegex(#"~/\.(ssh|aws|config|gnupg)"#), "PATH-002", "User secret configuration directory access"),
        (makeRegex(#"^/(System|Library|usr|bin|sbin|etc|var|private|dev)(/|\b)"#), "PATH-003", "System root directory access")
    ]

    /// Scans a skill manifest and script content against security rules.
    public static func scan(
        manifest: SkillPermissionManifest?,
        scriptContent: String,
        workspacePath: String? = nil
    ) -> SkillScanResult {
        guard let manifest = manifest else {
            return SkillScanResult(
                passed: false,
                skillName: "unknown",
                findings: [
                    SkillSecurityFinding(
                        ruleId: "MAN-001",
                        category: .missingManifest,
                        severity: .critical,
                        message: "Registration refused: missing permission manifest"
                    )
                ]
            )
        }

        var findings: [SkillSecurityFinding] = []
        let sanitizedName = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // 0. Validate manifest sanity
        if sanitizedName.isEmpty {
            findings.append(SkillSecurityFinding(
                ruleId: "MAN-002",
                category: .missingManifest,
                severity: .critical,
                message: "Registration refused: skill name is empty"
            ))
        }

        // 1. Prepare script body (strip first line if it's standard shebang)
        let lines = scriptContent.components(separatedBy: .newlines)
        var bodyLines: [String] = []
        for (index, line) in lines.enumerated() {
            if index == 0 && line.trimmingCharacters(in: .whitespaces).hasPrefix("#!") {
                continue
            }
            bodyLines.append(line)
        }
        let scriptBody = bodyLines.joined(separator: "\n")

        // 2. Catastrophic shell destruction scan (always forbidden)
        for pattern in catastrophicShellPatterns {
            let range = NSRange(scriptContent.startIndex..., in: scriptContent)
            if let match = pattern.regex.firstMatch(in: scriptContent, range: range) {
                let snippet = extractSnippet(from: scriptContent, range: match.range)
                findings.append(SkillSecurityFinding(
                    ruleId: pattern.ruleId,
                    category: .shellExec,
                    severity: .critical,
                    message: "Catastrophic command detected: \(pattern.description)",
                    snippet: snippet
                ))
            }
        }

        // 3. Credential access scan (always forbidden)
        for pattern in credentialPatterns {
            let range = NSRange(scriptContent.startIndex..., in: scriptContent)
            if let match = pattern.regex.firstMatch(in: scriptContent, range: range) {
                let snippet = extractSnippet(from: scriptContent, range: match.range)
                findings.append(SkillSecurityFinding(
                    ruleId: pattern.ruleId,
                    category: .credentialAccess,
                    severity: .critical,
                    message: "Credential theft or secret access detected: \(pattern.description)",
                    snippet: snippet
                ))
            }
        }

        // 4. Shell execution scan (forbidden unless allowShell is declared)
        if !manifest.permissions.allowShell {
            for pattern in shellExecPatterns {
                let range = NSRange(scriptBody.startIndex..., in: scriptBody)
                if let match = pattern.regex.firstMatch(in: scriptBody, range: range) {
                    let snippet = extractSnippet(from: scriptBody, range: match.range)
                    findings.append(SkillSecurityFinding(
                        ruleId: pattern.ruleId,
                        category: .shellExec,
                        severity: .high,
                        message: "Undeclared shell execution pattern: \(pattern.description) (manifest must declare allow_shell: true)",
                        snippet: snippet
                    ))
                }
            }
        }

        // 5. Network exfiltration scan (forbidden unless allowNetwork is declared)
        if !manifest.permissions.allowNetwork {
            for pattern in networkPatterns {
                let range = NSRange(scriptContent.startIndex..., in: scriptContent)
                if let match = pattern.regex.firstMatch(in: scriptContent, range: range) {
                    let snippet = extractSnippet(from: scriptContent, range: match.range)
                    findings.append(SkillSecurityFinding(
                        ruleId: pattern.ruleId,
                        category: .networkExfiltration,
                        severity: .high,
                        message: "Undeclared network access pattern: \(pattern.description) (manifest must declare allow_network: true)",
                        snippet: snippet
                    ))
                }
            }
        }

        // 6. Path traversal scan
        let allowedPaths = Set(manifest.permissions.filesystemPaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardized.path
        })

        for pattern in pathTraversalPatterns {
            let range = NSRange(scriptContent.startIndex..., in: scriptContent)
            if let match = pattern.regex.firstMatch(in: scriptContent, range: range) {
                let snippet = extractSnippet(from: scriptContent, range: match.range)
                findings.append(SkillSecurityFinding(
                    ruleId: pattern.ruleId,
                    category: .pathTraversal,
                    severity: .high,
                    message: "Path traversal or unauthorized system path access: \(pattern.description)",
                    snippet: snippet
                ))
            }
        }

        // Workspace boundary check: if absolute paths are mentioned outside workspace
        if let ws = workspacePath, !ws.isEmpty {
            let cleanWS = URL(fileURLWithPath: ws).standardized.path
            let absPathRegex = makeRegex(#"/(Users|var|tmp|private)/[a-zA-Z0-9_\-\./]+"#)
            let range = NSRange(scriptContent.startIndex..., in: scriptContent)
            let matches = absPathRegex.matches(in: scriptContent, range: range)
            for match in matches {
                if let r = Range(match.range, in: scriptContent) {
                    let matchedPath = URL(fileURLWithPath: String(scriptContent[r])).standardized.path
                    let isUnderWS = matchedPath == cleanWS || matchedPath.hasPrefix(cleanWS + "/")
                    let isExplicitlyAllowed = allowedPaths.contains { allowed in
                        matchedPath == allowed || matchedPath.hasPrefix(allowed + "/")
                    }
                    if !isUnderWS && !isExplicitlyAllowed {
                        findings.append(SkillSecurityFinding(
                            ruleId: "PATH-WS-001",
                            category: .pathTraversal,
                            severity: .high,
                            message: "Filesystem access outside workspace boundary '\(cleanWS)' to '\(matchedPath)' without declared permission",
                            snippet: matchedPath
                        ))
                    }
                }
            }
        }

        let hasBlockingFindings = findings.contains { $0.severity >= .high }
        return SkillScanResult(
            passed: !hasBlockingFindings,
            skillName: sanitizedName,
            findings: findings
        )
    }

    private static func extractSnippet(from text: String, range: NSRange) -> String? {
        guard let r = Range(range, in: text) else { return nil }
        let start = text.index(r.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 20, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
