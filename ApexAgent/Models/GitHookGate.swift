import Foundation

// MARK: - Batch 37: Git Hook Suite (pre-commit, commit-msg) & Staged Diff / Conventional Commit Gate

/// Structured result of validating a git commit message against the Conventional Commits specification.
public struct CommitMessageValidationResult: Codable, Sendable, Equatable {
    public let passed: Bool
    public let commitType: String?
    public let scope: String?
    public let isBreakingChange: Bool
    public let subject: String
    public let errors: [String]

    public init(
        passed: Bool,
        commitType: String?,
        scope: String?,
        isBreakingChange: Bool,
        subject: String,
        errors: [String]
    ) {
        self.passed = passed
        self.commitType = commitType
        self.scope = scope
        self.isBreakingChange = isBreakingChange
        self.subject = subject
        self.errors = errors
    }
}

/// Classification of pre-commit staged file violations.
public enum StagedFileViolationKind: String, Codable, Sendable, CaseIterable {
    case forbiddenArtifactPath
    case oversizedFile
    case leakedSecretInStagedContent
    case mergeConflictMarkerInStagedContent
}

/// A single pre-commit violation on a staged file.
public struct StagedFileViolation: Codable, Sendable, Equatable {
    public let kind: StagedFileViolationKind
    public let path: String
    public let message: String

    public init(kind: StagedFileViolationKind, path: String, message: String) {
        self.kind = kind
        self.path = path
        self.message = message
    }
}

/// Summary report from running ``GitHookGate`` pre-commit checks on staged files.
public struct StagedPreCommitReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let checkedFileCount: Int
    public let violations: [StagedFileViolation]

    public init(passed: Bool, checkedFileCount: Int, violations: [StagedFileViolation]) {
        self.passed = passed
        self.checkedFileCount = checkedFileCount
        self.violations = violations
    }

    public func formatSummary() -> String {
        if passed {
            return "PASS: Pre-commit staged gate clean (\(checkedFileCount) file(s) verified)."
        }
        var lines = [
            "FAIL: Pre-commit staged gate blocked commit (\(violations.count) violation(s) across \(checkedFileCount) file(s)):"
        ]
        for v in violations {
            lines.append("  [\(v.kind.rawValue)] \(v.path) — \(v.message)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Validator for git `commit-msg` (Conventional Commits) and `pre-commit` staged file hygiene.
public enum GitHookGate {

    public static let allowedCommitTypes: Set<String> = [
        "feat", "fix", "chore", "refactor", "test", "docs", "ci", "perf", "build", "revert", "style"
    ]

    public static let defaultMaxStagedFileSizeBytes: Int = 5 * 1024 * 1024 // 5 MB

    /// Validates a commit message string (stripping `#` comment lines).
    public static func validateCommitMessage(_ rawMessage: String) -> CommitMessageValidationResult {
        let nonCommentLines = rawMessage
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }

        let header = nonCommentLines
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !header.isEmpty else {
            return CommitMessageValidationResult(
                passed: false,
                commitType: nil,
                scope: nil,
                isBreakingChange: false,
                subject: "",
                errors: ["Commit message header cannot be empty."]
            )
        }

        // Allow automated git Merge / Revert commit headers
        if header.hasPrefix("Merge ") || header.hasPrefix("Revert \"") {
            return CommitMessageValidationResult(
                passed: true,
                commitType: "merge",
                scope: nil,
                isBreakingChange: false,
                subject: header,
                errors: []
            )
        }

        var errors: [String] = []
        if header.count > 120 {
            errors.append("Commit header exceeds 120 characters (\(header.count) chars).")
        }

        let pattern = #"^([a-z]+)(?:\(([^)]+)\))?(!)?:\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, options: [], range: NSRange(header.startIndex..<header.endIndex, in: header)) else {
            errors.append("Header must follow Conventional Commits format: '<type>[optional (scope)]: <subject>' (allowed types: \(allowedCommitTypes.sorted().joined(separator: ", "))).")
            return CommitMessageValidationResult(
                passed: false,
                commitType: nil,
                scope: nil,
                isBreakingChange: false,
                subject: header,
                errors: errors
            )
        }

        let typeStr = Range(match.range(at: 1), in: header).map { String(header[$0]) } ?? ""
        let scopeStr = Range(match.range(at: 2), in: header).map { String(header[$0]) }
        let bangStr = Range(match.range(at: 3), in: header).map { String(header[$0]) }
        let subjectStr = (Range(match.range(at: 4), in: header).map { String(header[$0]) } ?? "")
            .trimmingCharacters(in: .whitespaces)

        if !allowedCommitTypes.contains(typeStr) {
            errors.append("Unsupported commit type '\(typeStr)'. Allowed: \(allowedCommitTypes.sorted().joined(separator: ", ")).")
        }
        if subjectStr.count < 4 {
            errors.append("Commit subject is too short ('\(subjectStr)'); provide a descriptive summary.")
        }
        if let scope = scopeStr, scope.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Commit scope parentheses cannot be empty.")
        }

        return CommitMessageValidationResult(
            passed: errors.isEmpty,
            commitType: typeStr,
            scope: scopeStr,
            isBreakingChange: bangStr == "!",
            subject: subjectStr,
            errors: errors
        )
    }

    /// Evaluates staged file entries for forbidden build/OS artifacts, oversized binaries, leaked secrets, and merge conflict markers.
    public static func validateStagedFiles(
        _ entries: [(path: String, byteSize: Int, content: String?)],
        maxBytes: Int = defaultMaxStagedFileSizeBytes
    ) -> StagedPreCommitReport {
        var violations: [StagedFileViolation] = []

        for entry in entries {
            let path = entry.path

            // 1. Forbidden artifact paths
            if isForbiddenArtifactPath(path) {
                violations.append(
                    StagedFileViolation(
                        kind: .forbiddenArtifactPath,
                        path: path,
                        message: "Staged path is a forbidden build or OS artifact (.DS_Store, .xcresult, .xcuserdata, .build, DerivedData)."
                    )
                )
            }

            // 2. Oversized file guard
            if entry.byteSize > maxBytes {
                violations.append(
                    StagedFileViolation(
                        kind: .oversizedFile,
                        path: path,
                        message: "Staged file size (\(entry.byteSize) bytes) exceeds limit (\(maxBytes) bytes)."
                    )
                )
            }

            // 3. Content inspection for secrets & merge conflict markers
            if let content = entry.content {
                let secretFindings = RepoHygieneAuditor.scanForSecrets(in: content, filePath: path)
                for finding in secretFindings {
                    violations.append(
                        StagedFileViolation(
                            kind: .leakedSecretInStagedContent,
                            path: path,
                            message: "Line \(finding.line): \(finding.message)"
                        )
                    )
                }

                let conflictPrefixStart = String(repeating: "<", count: 7)
                let conflictPrefixMid = String(repeating: "=", count: 7)
                let conflictPrefixEnd = String(repeating: ">", count: 7)
                for (idx, line) in content.components(separatedBy: .newlines).enumerated() {
                    if line.hasPrefix(conflictPrefixStart) || line.hasPrefix(conflictPrefixMid) || line.hasPrefix(conflictPrefixEnd) {
                        violations.append(
                            StagedFileViolation(
                                kind: .mergeConflictMarkerInStagedContent,
                                path: path,
                                message: "Line \(idx + 1): Unresolved git merge conflict marker."
                            )
                        )
                    }
                }
            }
        }

        return StagedPreCommitReport(
            passed: violations.isEmpty,
            checkedFileCount: entries.count,
            violations: violations
        )
    }

    private static func isForbiddenArtifactPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        for comp in components {
            if comp == ".DS_Store"
                || comp == ".build"
                || comp == "DerivedData"
                || comp.hasSuffix(".xcresult")
                || comp.hasSuffix(".xcuserdata") {
                return true
            }
        }
        return false
    }
}
