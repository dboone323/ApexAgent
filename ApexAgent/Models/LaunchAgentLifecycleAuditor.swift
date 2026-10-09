import Foundation

// MARK: - LaunchAgent Plist & Socket Activation Lifecycle Gate (Batch 80)

/// Violation detected during LaunchAgent property list analysis.
public struct LaunchAgentViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Report produced by auditing a LaunchAgent daemon configuration or property list.
public struct LaunchAgentAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let labelValid: Bool
    public let executablePathValid: Bool
    public let logPathsSandboxed: Bool
    public let violations: [LaunchAgentViolation]

    public init(
        passed: Bool,
        score: Double,
        labelValid: Bool,
        executablePathValid: Bool,
        logPathsSandboxed: Bool,
        violations: [LaunchAgentViolation]
    ) {
        self.passed = passed
        self.score = score
        self.labelValid = labelValid
        self.executablePathValid = executablePathValid
        self.logPathsSandboxed = logPathsSandboxed
        self.violations = violations
    }
}

/// Auditor for launchd daemon property lists, log sandboxing, and lifecycle timeouts.
public enum LaunchAgentLifecycleAuditor {

    // Forbidden paths for launchd daemon redirection
    private static let forbiddenLogPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/Library/Preferences"
    ]

    // MARK: - Config Audit

    /// Audits a LaunchAgentConfig structure before writing to disk.
    public static func auditConfig(_ config: LaunchAgentConfig) -> LaunchAgentAuditReport {
        var violations: [LaunchAgentViolation] = []
        var labelValid = true
        var execValid = true
        var logsSandboxed = true

        // 1. Label Reverse-DNS Check
        if !config.label.hasPrefix("com.apexagent.") && !config.label.hasPrefix("com.apple.") {
            // Must have reverse-DNS structure
            let parts = config.label.components(separatedBy: ".")
            if parts.count < 3 || parts.contains(where: { $0.isEmpty }) {
                labelValid = false
                violations.append(LaunchAgentViolation(
                    code: "INVALID_LABEL_FORMAT",
                    message: "LaunchAgent label '\(config.label)' is not a valid reverse-DNS identifier."
                ))
            }
        }

        // 2. Executable Path Check
        if !config.programPath.hasPrefix("/") {
            execValid = false
            violations.append(LaunchAgentViolation(
                code: "RELATIVE_EXECUTABLE_PATH",
                message: "Program path '\(config.programPath)' must be an absolute filesystem path."
            ))
        }

        // 3. Log Path Sandboxing Check
        let stdout = LaunchAgentPlist.stdoutPath(for: config)
        let stderr = LaunchAgentPlist.stderrPath(for: config)

        for logPath in [stdout, stderr] {
            for forbidden in forbiddenLogPrefixes {
                if logPath.hasPrefix(forbidden) {
                    logsSandboxed = false
                    violations.append(LaunchAgentViolation(
                        code: "LOG_PATH_ESCAPES_SANDBOX",
                        message: "Log file '\(logPath)' redirects to restricted system path '\(forbidden)'."
                    ))
                }
            }
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? (violations.isEmpty ? 100.0 : 85.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 30.0)

        return LaunchAgentAuditReport(
            passed: passed,
            score: score,
            labelValid: labelValid,
            executablePathValid: execValid,
            logPathsSandboxed: logsSandboxed,
            violations: violations
        )
    }

    // MARK: - Plist XML Audit

    /// Audits a raw launchd property list XML string by parsing and verifying required keys.
    public static func auditPlistXML(_ xmlString: String) -> LaunchAgentAuditReport {
        guard let data = xmlString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return LaunchAgentAuditReport(
                passed: false,
                score: 0.0,
                labelValid: false,
                executablePathValid: false,
                logPathsSandboxed: false,
                violations: [LaunchAgentViolation(code: "MALFORMED_PLIST_XML", message: "Property list XML failed to deserialize.")]
            )
        }

        var violations: [LaunchAgentViolation] = []
        var labelValid = true
        var execValid = true
        var logsSandboxed = true

        // Label check
        if let label = plist["Label"] as? String, !label.isEmpty {
            let parts = label.components(separatedBy: ".")
            if parts.count < 3 {
                labelValid = false
                violations.append(LaunchAgentViolation(code: "INVALID_LABEL_FORMAT", message: "Label '\(label)' is not reverse-DNS."))
            }
        } else {
            labelValid = false
            violations.append(LaunchAgentViolation(code: "MISSING_LABEL_KEY", message: "Missing required 'Label' key."))
        }

        // ProgramArguments check
        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty {
            if let first = args.first, !first.hasPrefix("/") {
                execValid = false
                violations.append(LaunchAgentViolation(code: "RELATIVE_EXECUTABLE_PATH", message: "First argument must be absolute binary path."))
            }
        } else {
            execValid = false
            violations.append(LaunchAgentViolation(code: "MISSING_PROGRAM_ARGUMENTS", message: "Missing or empty 'ProgramArguments' array."))
        }

        // Log paths check
        let stdout = plist["StandardOutPath"] as? String ?? ""
        let stderr = plist["StandardErrorPath"] as? String ?? ""
        for path in [stdout, stderr] where !path.isEmpty {
            for forbidden in forbiddenLogPrefixes {
                if path.hasPrefix(forbidden) {
                    logsSandboxed = false
                    violations.append(LaunchAgentViolation(code: "LOG_PATH_ESCAPES_SANDBOX", message: "Path '\(path)' is in restricted directory."))
                }
            }
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? (violations.isEmpty ? 100.0 : 85.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 30.0)

        return LaunchAgentAuditReport(
            passed: passed,
            score: score,
            labelValid: labelValid,
            executablePathValid: execValid,
            logPathsSandboxed: logsSandboxed,
            violations: violations
        )
    }

    // MARK: - Lifecycle Grace Period Validation

    /// Validates that a daemon shutdown grace period complies with system escalation ceilings (5s to 30s).
    public static func validateShutdownGracePeriod(
        gracePeriodSeconds: TimeInterval,
        maxAllowedCeiling: TimeInterval = 30.0
    ) -> Bool {
        gracePeriodSeconds >= 5.0 && gracePeriodSeconds <= maxAllowedCeiling
    }
}
