import Foundation

// MARK: - Action Risk Classification (Issue #105)

public enum ActionRiskLevel: String, Codable, Sendable {
    case low = "low"
    case high = "high"
}

public enum ActionRiskCategory: String, Codable, Sendable {
    // Low-risk categories (auto-reviewed and auto-approved)
    case readOnly = "read-only"
    case allowlisted = "allowlisted"
    case wellKnownSafe = "well-known-safe"

    // High-risk categories (must surface for human approval)
    case writeOutsideWorkspace = "write-outside-workspace"
    case networkSend = "network-send"
    case deletion = "deletion"
    case credentialUse = "credential-use"
    case destructive = "destructive"
    case unknownMutation = "unknown-mutation"
}

public struct ActionRiskAssessment: Sendable, Equatable {
    public let level: ActionRiskLevel
    public let category: ActionRiskCategory
    public let reason: String

    public init(level: ActionRiskLevel, category: ActionRiskCategory, reason: String) {
        self.level = level
        self.category = category
        self.reason = reason
    }
}

public struct AutoReviewVerdict: Sendable, Equatable {
    public let shouldAutoApprove: Bool
    public let assessment: ActionRiskAssessment
    public let explanation: String

    public init(shouldAutoApprove: Bool, assessment: ActionRiskAssessment, explanation: String) {
        self.shouldAutoApprove = shouldAutoApprove
        self.assessment = assessment
        self.explanation = explanation
    }
}

// MARK: - Approval Auto-Review Engine (Issue #105)

/// Low-risk auto-review engine that reviews actions before they interrupt the human.
///
/// Auto-approves low-risk actions:
/// - Read-only commands and tools
/// - Previously approved command + directory entries (allowlisted)
/// - Well-known safe inspection operations
///
/// Surfaces high-risk actions:
/// - Writes outside the workspace boundary
/// - Network sends (curl, wget, ssh, scp, rsync, git push)
/// - File deletions (rm, unlink, delete_file)
/// - Credential, secret, and keychain access
/// - Destructive commands
public enum ApprovalAutoReview {

    private static let readOnlyTools: Set<String> = [
        "read_file", "file_read", "list_directory", "list_dir", "directory_tree",
        "find_by_name", "system_info", "process_list", "search_memory", "get_frontmost_app",
        "clipboard_read", "screenshot", "read_resource", "list_resources", "web_search"
    ]

    private static let mutatingTools: Set<String> = [
        "write_file", "file_write", "create_directory", "move_file", "rollback",
        "clipboard_write", "applescript", "store_memory"
    ]

    private static let deletionTools: Set<String> = [
        "delete_file", "file_delete", "remove_file"
    ]

    // Explicit regex patterns for high-risk detection
    private static let credentialPatterns: [String] = [
        #"(^|[\s/"'])\.env(\.|$|["'\s])"#,
        #"\.ssh\/|id_rsa|id_ed25519|authorized_keys"#,
        #"\.aws\/credentials|\.netrc|\.npmrc|\.pypirc|\.docker\/config\.json"#,
        #"security\s+find-(generic|internet)-password|\bkeychain\b"#,
        #"\bcredentials?\.json\b|\bserviceaccount\b|\bprivate_key\b"#
    ]

    private static let networkSendPatterns: [String] = [
        #"(?:^|[|;&\s])(curl|wget|nc|netcat|ssh|scp|sftp|ping|telnet|rsync)\b"#,
        #"\bgit\s+push\b"#,
        #"https?:\/\/"#
    ]

    private static let deletionPatterns: [String] = [
        #"(?:^|[|;&\s])(rm|rmdir|unlink)\b"#,
        #"\bgit\s+clean\s+-[a-zA-Z]*f"#
    ]

    private static let safeInspectionPatterns: [String] = [
        #"^[\w.-]+\s+(--version|-v|-V)\s*$"#,
        #"^(which|type|whereis|sw_vers|uname|whoami)\b"#
    ]

    private static let readOnlyCommandPrefixes: [String] = [
        "ls", "cat", "grep", "egrep", "fgrep", "head", "tail", "wc", "pwd",
        "git status", "git log", "git diff", "git branch", "git show", "git rev-parse",
        "echo", "printf", "diff", "stat", "file"
    ]

    /// Evaluates the risk of an action and classifies it into explicit risk levels.
    public static func assessRisk(
        toolName: String,
        command: String? = nil,
        directory: String,
        workspacePath: String? = nil,
        targetFilePath: String? = nil,
        now: Date = Date(),
        allowlist: ApprovalAllowlist = .shared
    ) -> ActionRiskAssessment {
        let cleanDir = ApprovalAllowlist.standardizeDirectory(directory)
        let effectiveCmd = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 1. Credential / Secret Access (Highest Risk)
        let textToCheck = "\(effectiveCmd) \(targetFilePath ?? "")"
        for pattern in credentialPatterns {
            if textToCheck.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return ActionRiskAssessment(
                    level: .high,
                    category: .credentialUse,
                    reason: "Action accesses sensitive credentials, keys, or security vaults."
                )
            }
        }

        // 2. Destructive Operations Guard
        if ApprovalPolicy.looksDestructive(effectiveCmd) || ApprovalPolicy.looksDestructive(toolName) {
            return ActionRiskAssessment(
                level: .high,
                category: .destructive,
                reason: "Action contains potentially catastrophic or destructive commands."
            )
        }

        // 3. Deletions
        if deletionTools.contains(toolName.lowercased()) {
            return ActionRiskAssessment(
                level: .high,
                category: .deletion,
                reason: "Tool '\(toolName)' permanently deletes files or directories."
            )
        }
        for pattern in deletionPatterns {
            if effectiveCmd.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return ActionRiskAssessment(
                    level: .high,
                    category: .deletion,
                    reason: "Command performs file deletion ('\(effectiveCmd)')."
                )
            }
        }

        // 4. Network Sends
        for pattern in networkSendPatterns {
            if effectiveCmd.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return ActionRiskAssessment(
                    level: .high,
                    category: .networkSend,
                    reason: "Command initiates outbound network connections or repository pushes."
                )
            }
        }

        // 5. Writes Outside the Workspace
        if let ws = workspacePath, !ws.isEmpty {
            let cleanWorkspace = ApprovalAllowlist.standardizeDirectory(ws)

            // Check target file path
            if let tf = targetFilePath, !tf.isEmpty {
                let cleanTarget = ApprovalAllowlist.standardizeDirectory(tf)
                if !cleanTarget.hasPrefix(cleanWorkspace) {
                    return ActionRiskAssessment(
                        level: .high,
                        category: .writeOutsideWorkspace,
                        reason: "File modification target '\(cleanTarget)' is outside workspace '\(cleanWorkspace)'."
                    )
                }
            }

            // Check execution directory
            if mutatingTools.contains(toolName.lowercased()) && !cleanDir.hasPrefix(cleanWorkspace) {
                return ActionRiskAssessment(
                    level: .high,
                    category: .writeOutsideWorkspace,
                    reason: "State-mutating operation occurs outside workspace directory '\(cleanWorkspace)'."
                )
            }

            // Check shell output redirection into outside paths
            if effectiveCmd.contains(">") {
                let parts = effectiveCmd.components(separatedBy: ">")
                if parts.count > 1 {
                    let destCandidate = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: " ").first.map(String.init) ?? ""
                    if !destCandidate.isEmpty {
                        let fullDest: String
                        if destCandidate.hasPrefix("/") || destCandidate.hasPrefix("~") {
                            fullDest = ApprovalAllowlist.standardizeDirectory(destCandidate)
                        } else {
                            fullDest = ApprovalAllowlist.standardizeDirectory("\(cleanDir)/\(destCandidate)")
                        }
                        if !fullDest.hasPrefix(cleanWorkspace) {
                            return ActionRiskAssessment(
                                level: .high,
                                category: .writeOutsideWorkspace,
                                reason: "Command redirects output to '\(fullDest)' outside workspace '\(cleanWorkspace)'."
                            )
                        }
                    }
                }
            }
        }

        // 6. Allowlisted Command in this exact Directory
        if !effectiveCmd.isEmpty && allowlist.isAllowed(command: effectiveCmd, directory: cleanDir, now: now) {
            return ActionRiskAssessment(
                level: .low,
                category: .allowlisted,
                reason: "Exact command and directory match an active allowlist grant."
            )
        }

        // 7. Well-known Safe Inspection Operations
        for pattern in safeInspectionPatterns {
            if effectiveCmd.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return ActionRiskAssessment(
                    level: .low,
                    category: .wellKnownSafe,
                    reason: "Well-known safe inspection command: '\(effectiveCmd)'."
                )
            }
        }

        // 8. Read-only Tools and Commands
        if readOnlyTools.contains(toolName.lowercased()) {
            return ActionRiskAssessment(
                level: .low,
                category: .readOnly,
                reason: "Tool '\(toolName)' is strictly read-only."
            )
        }

        // Check if command is a read-only shell command with no redirections or pipes to mutations
        if !effectiveCmd.isEmpty && !effectiveCmd.contains(">") {
            let trimmed = effectiveCmd.trimmingCharacters(in: .whitespaces)
            let isPrefixReadOnly = readOnlyCommandPrefixes.contains { prefix in
                trimmed == prefix || trimmed.hasPrefix(prefix + " ")
            }
            if isPrefixReadOnly {
                // Ensure no chained commands containing dangerous/mutating keywords
                let subCommands = trimmed.components(separatedBy: CharacterSet(charactersIn: ";|&"))
                let allSubReadOnly = subCommands.allSatisfy { sub in
                    let s = sub.trimmingCharacters(in: .whitespaces)
                    if s.isEmpty { return true }
                    return readOnlyCommandPrefixes.contains { prefix in
                        s == prefix || s.hasPrefix(prefix + " ")
                    } || safeInspectionPatterns.contains { pat in
                        s.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil
                    }
                }
                if allSubReadOnly {
                    return ActionRiskAssessment(
                        level: .low,
                        category: .readOnly,
                        reason: "Read-only shell inspection command: '\(effectiveCmd)'."
                    )
                }
            }
        }

        // 9. Default Fallback: Unknown or mutating actions are high-risk and surface for approval
        return ActionRiskAssessment(
            level: .high,
            category: .unknownMutation,
            reason: "Action is state-mutating, unclassified, or outside safety boundaries."
        )
    }

    /// Evaluates whether an action should be auto-approved by the low-risk auto-reviewer.
    public static func review(
        toolName: String,
        command: String? = nil,
        directory: String,
        workspacePath: String? = nil,
        targetFilePath: String? = nil,
        now: Date = Date(),
        allowlist: ApprovalAllowlist = .shared
    ) -> AutoReviewVerdict {
        let assessment = assessRisk(
            toolName: toolName,
            command: command,
            directory: directory,
            workspacePath: workspacePath,
            targetFilePath: targetFilePath,
            now: now,
            allowlist: allowlist
        )

        let autoApprove = (assessment.level == .low)
        let explanation: String
        if autoApprove {
            explanation = "Auto-approved by low-risk reviewer [\(assessment.category.rawValue)]: \(assessment.reason)"
        } else {
            explanation = "Surfacing for human approval [\(assessment.category.rawValue)]: \(assessment.reason)"
        }

        return AutoReviewVerdict(
            shouldAutoApprove: autoApprove,
            assessment: assessment,
            explanation: explanation
        )
    }
}
