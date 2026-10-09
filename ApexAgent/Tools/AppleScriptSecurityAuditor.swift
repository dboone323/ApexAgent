import Foundation

// MARK: - AppleScript OSA AST & Script Execution Gate (Batch 94)

/// Risk classification for analyzed AppleScript commands.
public enum AppleScriptRiskLevel: String, Sendable, Codable, Equatable {
    case safe
    case elevated
    case prohibited
}

/// Security policy defining boundaries for executing AppleScript payloads.
public struct AppleScriptSecurityPolicy: Sendable, Codable, Equatable {
    public var allowDoShellScript: Bool
    public var allowAdministratorPrivileges: Bool
    public var allowKeystrokeInjection: Bool
    public var maxScriptSizeBytes: Int
    public var blockedApplications: Set<String>

    public init(
        allowDoShellScript: Bool = false,
        allowAdministratorPrivileges: Bool = false,
        allowKeystrokeInjection: Bool = false,
        maxScriptSizeBytes: Int = 65_536,
        blockedApplications: Set<String> = ["terminal", "iterm", "iterm2"]
    ) {
        self.allowDoShellScript = allowDoShellScript
        self.allowAdministratorPrivileges = allowAdministratorPrivileges
        self.allowKeystrokeInjection = allowKeystrokeInjection
        self.maxScriptSizeBytes = maxScriptSizeBytes
        self.blockedApplications = blockedApplications
    }
}

/// Violation detected during AppleScript code auditing.
public struct AppleScriptSecurityViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Security audit report for an AppleScript payload.
public struct AppleScriptSecurityReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let riskLevel: AppleScriptRiskLevel
    public let sanitizedScript: String?
    public let violations: [AppleScriptSecurityViolation]

    public init(
        passed: Bool,
        score: Double,
        riskLevel: AppleScriptRiskLevel,
        sanitizedScript: String?,
        violations: [AppleScriptSecurityViolation]
    ) {
        self.passed = passed
        self.score = score
        self.riskLevel = riskLevel
        self.sanitizedScript = sanitizedScript
        self.violations = violations
    }
}

/// Security gate and command analyzer for AppleScript execution.
public enum AppleScriptSecurityAuditor {

    // Dangerous patterns
    private static let adminPrivilegesPattern = "with administrator privileges"
    private static let doShellScriptPattern = "do shell script"
    private static let keystrokePattern = "keystroke"
    private static let keycodePattern = "key code"

    // MARK: - Script Audit

    /// Audits AppleScript source text against privilege escalation, shell escapes, blocked target apps, and size limits.
    public static func auditScript(
        _ script: String,
        policy: AppleScriptSecurityPolicy = AppleScriptSecurityPolicy()
    ) -> AppleScriptSecurityReport {
        var violations: [AppleScriptSecurityViolation] = []
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let scriptBytes = trimmed.utf8.count

        // 1. Empty script check
        if trimmed.isEmpty {
            violations.append(AppleScriptSecurityViolation(
                code: "EMPTY_APPLESCRIPT",
                message: "AppleScript source cannot be empty."
            ))
            return AppleScriptSecurityReport(
                passed: false,
                score: 0.0,
                riskLevel: .prohibited,
                sanitizedScript: nil,
                violations: violations
            )
        }

        // 2. Size limit check
        if scriptBytes > policy.maxScriptSizeBytes {
            violations.append(AppleScriptSecurityViolation(
                code: "SCRIPT_SIZE_EXCEEDED",
                message: "Script size (\(scriptBytes) bytes) exceeds maximum allowable ceiling of \(policy.maxScriptSizeBytes) bytes."
            ))
        }

        let lower = trimmed.lowercased()

        // 3. Administrator privileges check
        if lower.contains(adminPrivilegesPattern) && !policy.allowAdministratorPrivileges {
            violations.append(AppleScriptSecurityViolation(
                code: "ADMINISTRATOR_PRIVILEGES_PROHIBITED",
                message: "AppleScript specifies 'with administrator privileges' which is strictly prohibited."
            ))
        }

        // 4. Do shell script check
        if lower.contains(doShellScriptPattern) && !policy.allowDoShellScript {
            violations.append(AppleScriptSecurityViolation(
                code: "DO_SHELL_SCRIPT_PROHIBITED",
                message: "AppleScript contains 'do shell script' execution. Use run_shell_command for tracked command execution."
            ))
        }

        // 5. Keystroke / Key code synthetic input check
        if (lower.contains(keystrokePattern) || lower.contains(keycodePattern)) && !policy.allowKeystrokeInjection {
            violations.append(AppleScriptSecurityViolation(
                code: "SYNTHETIC_KEYSTROKE_PROHIBITED",
                message: "Synthetic keystroke simulation via System Events is disabled by security policy."
            ))
        }

        // 6. Blocked applications check
        for blocked in policy.blockedApplications {
            let targetPattern = "tell application \"\(blocked)\""
            let targetPatternAlt = "tell application '\(blocked)'"
            if lower.contains(targetPattern) || lower.contains(targetPatternAlt) {
                violations.append(AppleScriptSecurityViolation(
                    code: "BLOCKED_TARGET_APPLICATION",
                    message: "Script attempts to control blocked terminal application '\(blocked)'."
                ))
            }
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty

        let riskLevel: AppleScriptRiskLevel
        if !passed {
            riskLevel = .prohibited
        } else if lower.contains(doShellScriptPattern) || lower.contains(keystrokePattern) {
            riskLevel = .elevated
        } else {
            riskLevel = .safe
        }

        let score = passed ? (violations.isEmpty ? 100.0 : 80.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 25.0)

        return AppleScriptSecurityReport(
            passed: passed,
            score: score,
            riskLevel: riskLevel,
            sanitizedScript: passed ? trimmed : nil,
            violations: violations
        )
    }

    // MARK: - Syntax Compilation Check

    /// Verifies if the script parses and compiles as valid AppleScript using NSAppleScript without executing it.
    public static func verifyCompilationSyntax(_ source: String) -> (isCompiled: Bool, errorMessage: String?) {
        guard let appleScript = NSAppleScript(source: source) else {
            return (false, "Could not initialize NSAppleScript")
        }
        var errorInfo: NSDictionary?
        let success = appleScript.compileAndReturnError(&errorInfo)
        if success {
            return (true, nil)
        } else {
            let msg = errorInfo?[NSAppleScript.errorMessage] as? String ?? "Compilation failed"
            return (false, msg)
        }
    }
}
