import Foundation

// MARK: - Tool Execution Safety Sandbox & Path Restriction Gate (Batch 61)

/// Severity classification for tool execution sandbox policy violations.
public enum ToolSandboxSeverity: String, Codable, Sendable, Comparable {
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

    public static func < (lhs: ToolSandboxSeverity, rhs: ToolSandboxSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A specific rule violation detected when evaluating a tool operation against sandbox policies.
public struct ToolSandboxViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(operationName):\(ruleId):\(message)" }
    public let operationName: String
    public let ruleId: String
    public let severity: ToolSandboxSeverity
    public let message: String
    public let remediation: String

    public init(
        operationName: String,
        ruleId: String,
        severity: ToolSandboxSeverity,
        message: String,
        remediation: String
    ) {
        self.operationName = operationName
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// A description of a requested tool execution for policy audit.
public struct ToolExecutionOperation: Codable, Sendable, Equatable {
    public let name: String
    public let targetPath: String?
    public let command: String?
    public let payloadSizeBytes: Int?
    public let requestedTimeoutSeconds: TimeInterval?
    public let workspaceRoot: String?

    public init(
        name: String,
        targetPath: String? = nil,
        command: String? = nil,
        payloadSizeBytes: Int? = nil,
        requestedTimeoutSeconds: TimeInterval? = nil,
        workspaceRoot: String? = nil
    ) {
        self.name = name
        self.targetPath = targetPath
        self.command = command
        self.payloadSizeBytes = payloadSizeBytes
        self.requestedTimeoutSeconds = requestedTimeoutSeconds
        self.workspaceRoot = workspaceRoot
    }
}

/// Comprehensive audit report produced by `ToolExecutionSandboxGate`.
public struct ToolExecutionSandboxReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedOperations: Int
    public let violations: [ToolSandboxViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        evaluatedOperations: Int,
        violations: [ToolSandboxViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedOperations = evaluatedOperations
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Autonomous gate ensuring all tool executions respect strict filesystem boundaries,
/// command safety patterns, and execution quotas.
public enum ToolExecutionSandboxGate {

    /// System root directories strictly prohibited for write or arbitrary execution.
    public static let forbiddenSystemPrefixes: [String] = [
        "/System",
        "/Library",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/var",
        "/private",
        "/dev"
    ]

    /// Sensitive user-level secret and configuration paths prohibited from agent modification.
    public static let forbiddenUserPatterns: [String] = [
        ".ssh",
        ".gnupg",
        ".aws",
        ".config/gcloud",
        ".vault-token",
        ".bash_history",
        ".zsh_history"
    ]

    /// Dangerous shell command patterns that must trigger critical security rejections.
    public static let dangerousShellSignatures: [(pattern: String, ruleId: String, description: String)] = [
        ("rm -rf /", "SH-001", "Catastrophic recursive root deletion"),
        ("rm -rf /*", "SH-001", "Catastrophic recursive root wildcard deletion"),
        ("rm -rf ~", "SH-002", "Recursive user home directory deletion"),
        ("mkfs", "SH-003", "Disk partition formatting command"),
        ("dd if=", "SH-004", "Raw block device write command"),
        (":(){ :|:& };:", "SH-005", "Bash fork-bomb denial-of-service attack"),
        ("| sh", "SH-006", "Piping uninspected remote script to shell"),
        ("| bash", "SH-006", "Piping uninspected remote script to bash"),
        ("| zsh", "SH-006", "Piping uninspected remote script to zsh"),
        ("> /etc/", "SH-007", "Direct redirection write into system configuration directory"),
        ("> /System/", "SH-008", "Direct redirection write into system root directory")
    ]

    public static let maxPayloadSizeBytes: Int = 10 * 1024 * 1024 // 10MB
    public static let maxTimeoutSeconds: TimeInterval = 300.0 // 5 minutes

    /// Audits a collection of tool execution operations.
    public static func audit(
        operations: [ToolExecutionOperation],
        defaultWorkspaceRoot: String? = nil
    ) -> ToolExecutionSandboxReport {
        guard !operations.isEmpty else {
            return ToolExecutionSandboxReport(
                passed: true,
                score: 100.0,
                evaluatedOperations: 0,
                violations: [],
                recommendations: ["No operations evaluated."]
            )
        }

        var allViolations: [ToolSandboxViolation] = []

        for op in operations {
            let ws = op.workspaceRoot ?? defaultWorkspaceRoot

            if let targetPath = op.targetPath {
                let pathViolations = validatePath(targetPath, operationName: op.name, workspaceRoot: ws)
                allViolations.append(contentsOf: pathViolations)
            }

            if let cmd = op.command {
                let cmdViolations = validateCommand(cmd, operationName: op.name)
                allViolations.append(contentsOf: cmdViolations)
            }

            if let payloadBytes = op.payloadSizeBytes {
                let payloadViolations = validatePayload(payloadBytes, operationName: op.name)
                allViolations.append(contentsOf: payloadViolations)
            }

            if let timeout = op.requestedTimeoutSeconds {
                let timeoutViolations = validateTimeout(timeout, operationName: op.name)
                allViolations.append(contentsOf: timeoutViolations)
            }
        }

        // Deduplicate violations
        var seen = Set<String>()
        let deduped = allViolations.filter { violation in
            if seen.contains(violation.id) { return false }
            seen.insert(violation.id)
            return true
        }

        let penalty = deduped.reduce(0.0) { acc, v in
            switch v.severity {
            case .critical: return acc + 35.0
            case .high: return acc + 20.0
            case .medium: return acc + 10.0
            case .low: return acc + 5.0
            case .info: return acc + 1.0
            }
        }

        let score = max(0.0, 100.0 - penalty)
        let hasCriticalOrHigh = deduped.contains { $0.severity >= .high }
        let passed = !hasCriticalOrHigh && score >= 75.0

        var recs: [String] = []
        if !passed {
            recs.append("Restrict tool operations to isolated workspace directories and avoid dangerous shell execution.")
        }
        if deduped.contains(where: { $0.ruleId.hasPrefix("PATH-") }) {
            recs.append("Constrain file paths within the designated workspace boundary.")
        }
        if deduped.contains(where: { $0.ruleId.hasPrefix("SH-") }) {
            recs.append("Refactor command scripts to eliminate pipe-to-shell or destructive deletion patterns.")
        }

        return ToolExecutionSandboxReport(
            passed: passed,
            score: score,
            evaluatedOperations: operations.count,
            violations: deduped,
            recommendations: recs
        )
    }

    /// Validates a file path against system boundary and workspace restrictions.
    public static func validatePath(
        _ rawPath: String,
        operationName: String,
        workspaceRoot: String?
    ) -> [ToolSandboxViolation] {
        var violations: [ToolSandboxViolation] = []
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return violations }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardized.path

        // Check path traversal escape attempt
        if trimmed.contains("../") || trimmed.contains("/..") {
            if let root = workspaceRoot {
                let standardRoot = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath).standardized.path
                if standardized != standardRoot && !standardized.hasPrefix(standardRoot + "/") {
                    violations.append(
                        ToolSandboxViolation(
                            operationName: operationName,
                            ruleId: "PATH-001",
                            severity: .critical,
                            message: "Path traversal detected: '\(trimmed)' resolves outside workspace '\(standardRoot)' to '\(standardized)'.",
                            remediation: "Ensure paths stay within the designated workspace."
                        )
                    )
                }
            }
        }

        // Check system root directory containment
        for prefix in forbiddenSystemPrefixes {
            if standardized == prefix || standardized.hasPrefix(prefix + "/") {
                violations.append(
                    ToolSandboxViolation(
                        operationName: operationName,
                        ruleId: "PATH-002",
                        severity: .critical,
                        message: "Access to system directory '\(standardized)' is strictly prohibited under sandbox policy.",
                        remediation: "Relocate target files to user workspace."
                    )
                )
                break
            }
        }

        // Check user secret patterns
        for pattern in forbiddenUserPatterns {
            let lower = standardized.lowercased()
            if lower.contains("/" + pattern) || lower.hasSuffix("/" + pattern) || lower.contains("/" + pattern + "/") {
                violations.append(
                    ToolSandboxViolation(
                        operationName: operationName,
                        ruleId: "PATH-003",
                        severity: .high,
                        message: "Access to sensitive user configuration '\(pattern)' is disallowed.",
                        remediation: "Do not read or write user secrets, SSH keys, or cloud credentials."
                    )
                )
                break
            }
        }

        // Check workspace containment if a workspaceRoot is mandated
        if let root = workspaceRoot {
            let standardRoot = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath).standardized.path
            let isInside = standardized == standardRoot || standardized.hasPrefix(standardRoot + "/")
            if !isInside && violations.isEmpty {
                violations.append(
                    ToolSandboxViolation(
                        operationName: operationName,
                        ruleId: "PATH-004",
                        severity: .medium,
                        message: "Path '\(standardized)' is outside the active workspace '\(standardRoot)'.",
                        remediation: "Specify paths relative to or inside the active project directory."
                    )
                )
            }
        }

        return violations
    }

    /// Validates a shell command against dangerous execution patterns.
    public static func validateCommand(
        _ command: String,
        operationName: String
    ) -> [ToolSandboxViolation] {
        var violations: [ToolSandboxViolation] = []
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return violations }

        for (pattern, ruleId, desc) in dangerousShellSignatures {
            if trimmed.contains(pattern) {
                violations.append(
                    ToolSandboxViolation(
                        operationName: operationName,
                        ruleId: ruleId,
                        severity: .critical,
                        message: "Dangerous command signature detected (\(pattern)): \(desc).",
                        remediation: "Remove the dangerous shell pattern or run via a containerized sandbox."
                    )
                )
            }
        }

        return violations
    }

    /// Validates payload byte count against disk exhaustion limits.
    public static func validatePayload(
        _ bytes: Int,
        operationName: String
    ) -> [ToolSandboxViolation] {
        var violations: [ToolSandboxViolation] = []
        if bytes > maxPayloadSizeBytes {
            violations.append(
                ToolSandboxViolation(
                    operationName: operationName,
                    ruleId: "QUOTA-001",
                    severity: .high,
                    message: "Payload size \(bytes) bytes exceeds maximum allowed limit of \(maxPayloadSizeBytes) bytes (10MB).",
                    remediation: "Chunk payload or stream large files in increments."
                )
            )
        }
        return violations
    }

    /// Validates requested execution timeout against denial-of-service limits.
    public static func validateTimeout(
        _ seconds: TimeInterval,
        operationName: String
    ) -> [ToolSandboxViolation] {
        var violations: [ToolSandboxViolation] = []
        if seconds > maxTimeoutSeconds {
            violations.append(
                ToolSandboxViolation(
                    operationName: operationName,
                    ruleId: "QUOTA-002",
                    severity: .medium,
                    message: "Requested timeout \(seconds)s exceeds maximum allowable timeout of \(maxTimeoutSeconds)s.",
                    remediation: "Reduce operation timeout to 300s or below."
                )
            )
        }
        return violations
    }
}
