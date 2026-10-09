import Foundation

// MARK: - Apple Virtualization & OCI Container Security Policy Auditor (Batch 53)

/// Severity of a container policy violation.
public enum ContainerViolationSeverity: String, Codable, Sendable, Comparable {
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

    public static func < (lhs: ContainerViolationSeverity, rhs: ContainerViolationSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Mount specification for container isolation audits.
public struct ContainerMountSpec: Codable, Sendable, Equatable {
    public let hostPath: String
    public let containerPath: String
    public let isReadOnly: Bool

    public init(hostPath: String, containerPath: String, isReadOnly: Bool = true) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.isReadOnly = isReadOnly
    }
}

/// Resource quota bounds for containerized microVM execution.
public struct ContainerResourceQuota: Codable, Sendable, Equatable {
    public let cpuCount: Int
    public let memoryLimitBytes: UInt64
    public let storageLimitBytes: UInt64

    public init(
        cpuCount: Int = 2,
        memoryLimitBytes: UInt64 = 2 * 1024 * 1024 * 1024,
        storageLimitBytes: UInt64 = 10 * 1024 * 1024 * 1024
    ) {
        self.cpuCount = cpuCount
        self.memoryLimitBytes = memoryLimitBytes
        self.storageLimitBytes = storageLimitBytes
    }
}

/// Full security specification evaluated by `ContainerPolicyAuditor`.
public struct ContainerSecurityConfig: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isolationLevel: ContainerIsolationLevel
    public let resourceQuota: ContainerResourceQuota
    public let mounts: [ContainerMountSpec]
    public let snapshots: [ContainerSnapshotRecord]
    public let allowHostNetwork: Bool
    public let privileged: Bool

    public init(
        id: String,
        name: String,
        isolationLevel: ContainerIsolationLevel = .strict,
        resourceQuota: ContainerResourceQuota = ContainerResourceQuota(),
        mounts: [ContainerMountSpec] = [],
        snapshots: [ContainerSnapshotRecord] = [],
        allowHostNetwork: Bool = false,
        privileged: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isolationLevel = isolationLevel
        self.resourceQuota = resourceQuota
        self.mounts = mounts
        self.snapshots = snapshots
        self.allowHostNetwork = allowHostNetwork
        self.privileged = privileged
    }
}

/// Specific violation detected in container configuration or snapshot states.
public struct ContainerPolicyViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(containerId):\(ruleId):\(message)" }
    public let containerId: String
    public let ruleId: String
    public let severity: ContainerViolationSeverity
    public let message: String
    public let remediation: String

    public init(
        containerId: String,
        ruleId: String,
        severity: ContainerViolationSeverity,
        message: String,
        remediation: String
    ) {
        self.containerId = containerId
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// Aggregated report of container policy security audit.
public struct ContainerPolicyAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedContainers: Int
    public let violations: [ContainerPolicyViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        evaluatedContainers: Int,
        violations: [ContainerPolicyViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedContainers = evaluatedContainers
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Virtualization & OCI Container Security Policy Audit (`\(badge)`)",
            "",
            "- **Compliance Score**: `\(String(format: "%.1f", score))/100.0`",
            "- **Containers Evaluated**: `\(evaluatedContainers)`",
            "- **Violations Detected**: `\(violations.count)`",
            ""
        ]

        if !violations.isEmpty {
            lines.append("### Violations")
            lines.append("| Container ID | Rule ID | Severity | Violation | Remediation |")
            lines.append("| :--- | :--- | :---: | :--- | :--- |")
            for v in violations {
                lines.append("| `\(v.containerId)` | `\(v.ruleId)` | `\(v.severity.rawValue)` | \(v.message) | \(v.remediation) |")
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

/// Security auditor for container configurations, microVM resource quotas, and snapshot rollbacks.
public enum ContainerPolicyAuditor {
    private static let sensitiveHostPrefixes: [String] = [
        "/etc", "/var", "/System", "/Library", "/private", "/dev", "/Volumes",
        "~/.ssh", "~/.aws", "~/.gnupg", "~/.kube", "~/.config"
    ]

    /// Evaluates a suite of container configurations.
    public static func audit(configs: [ContainerSecurityConfig]) -> ContainerPolicyAuditReport {
        var violations: [ContainerPolicyViolation] = []
        var recommendations: [String] = []

        for config in configs {
            violations.append(contentsOf: auditContainer(config))
        }

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
            recommendations.append("Disallow privileged mode across all untrusted container workloads.")
            recommendations.append("Enforce read-only host mounts and sanitize all directory paths against traversal.")
            recommendations.append("Enforce strict isolation level and bound compute quotas to <= 4 vCPUs and <= 8GB RAM.")
            recommendations.append("Verify snapshot rollback invariants before allowing agent state reversion.")
        } else {
            recommendations.append("All container configurations comply with virtualization security policies.")
        }

        return ContainerPolicyAuditReport(
            passed: passed,
            score: finalScore,
            evaluatedContainers: configs.count,
            violations: violations,
            recommendations: recommendations
        )
    }

    /// Evaluates an individual container security configuration.
    public static func auditContainer(_ config: ContainerSecurityConfig) -> [ContainerPolicyViolation] {
        var issues: [ContainerPolicyViolation] = []

        // 1. Privileged execution check
        if config.privileged {
            issues.append(
                ContainerPolicyViolation(
                    containerId: config.id,
                    ruleId: "container_privileged_forbidden",
                    severity: .critical,
                    message: "Container '\(config.name)' runs in privileged mode, granting host root capabilities.",
                    remediation: "Disable privileged mode and execute as an unprivileged UID."
                )
            )
        }

        // 2. Network isolation check
        if config.allowHostNetwork {
            issues.append(
                ContainerPolicyViolation(
                    containerId: config.id,
                    ruleId: "container_host_network_exposure",
                    severity: .high,
                    message: "Container shares host network namespace, exposing loopback listeners.",
                    remediation: "Isolate network using bridge or vmnet NAT."
                )
            )
        }

        // 3. Resource quotas validation
        let quota = config.resourceQuota
        if quota.cpuCount < 1 || quota.cpuCount > 8 {
            issues.append(
                ContainerPolicyViolation(
                    containerId: config.id,
                    ruleId: "container_quota_cpu_out_of_bounds",
                    severity: .medium,
                    message: "Configured CPU count (\(quota.cpuCount)) exceeds safe sandbox quota [1..8].",
                    remediation: "Clamp CPU count between 1 and 8 cores."
                )
            )
        }

        let maxMemory: UInt64 = 16 * 1024 * 1024 * 1024 // 16 GB
        let minMemory: UInt64 = 256 * 1024 * 1024       // 256 MB
        if quota.memoryLimitBytes < minMemory || quota.memoryLimitBytes > maxMemory {
            issues.append(
                ContainerPolicyViolation(
                    containerId: config.id,
                    ruleId: "container_quota_memory_out_of_bounds",
                    severity: .medium,
                    message: "Memory limit (\(quota.memoryLimitBytes / (1024 * 1024)) MB) is outside safe boundary [256MB..16GB].",
                    remediation: "Set memory allocation within approved boundaries."
                )
            )
        }

        // 4. Mount directory traversal and sensitive path validation
        issues.append(contentsOf: auditMounts(config.mounts, containerId: config.id))

        // 5. Snapshot integrity and rollback invariant audit
        issues.append(contentsOf: auditSnapshots(config.snapshots, containerId: config.id))

        return issues
    }

    /// Audits host mounts for path traversal, escaping, and sensitive directory access.
    public static func auditMounts(_ mounts: [ContainerMountSpec], containerId: String) -> [ContainerPolicyViolation] {
        var issues: [ContainerPolicyViolation] = []

        for mount in mounts {
            let host = mount.hostPath.trimmingCharacters(in: .whitespacesAndNewlines)

            // Traversal check
            if host.contains("..") || host.contains("\0") {
                issues.append(
                    ContainerPolicyViolation(
                        containerId: containerId,
                        ruleId: "mount_path_traversal",
                        severity: .critical,
                        message: "Mount path '\(host)' contains directory traversal sequences or null bytes.",
                        remediation: "Canonicalize and sanitize host directory paths."
                    )
                )
            }

            // Root mount check
            if host == "/" {
                issues.append(
                    ContainerPolicyViolation(
                        containerId: containerId,
                        ruleId: "mount_root_forbidden",
                        severity: .critical,
                        message: "Mount targets root filesystem ('/').",
                        remediation: "Mount only dedicated workspace subdirectories."
                    )
                )
            }

            // Sensitive system directories
            let lower = host.lowercased()
            for prefix in sensitiveHostPrefixes {
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
                        ContainerPolicyViolation(
                            containerId: containerId,
                            ruleId: "mount_sensitive_system_path",
                            severity: .high,
                            message: "Mount targets sensitive host system path '\(host)'.",
                            remediation: "Scope container storage to isolated workspace paths."
                        )
                    )
                    break
                }
            }

            // Writable mount to binary path
            if !mount.isReadOnly && (host.hasPrefix("/usr") || host.hasPrefix("/bin") || host.hasPrefix("/sbin")) {
                issues.append(
                    ContainerPolicyViolation(
                        containerId: containerId,
                        ruleId: "mount_writable_system_binary_path",
                        severity: .critical,
                        message: "Writable mount allowed on system binary directory '\(host)'.",
                        remediation: "Mark mount as read-only."
                    )
                )
            }
        }

        return issues
    }

    /// Verifies snapshot monotonicity and rollback integrity.
    public static func auditSnapshots(_ snapshots: [ContainerSnapshotRecord], containerId: String) -> [ContainerPolicyViolation] {
        var issues: [ContainerPolicyViolation] = []
        var seenIDs = Set<String>()
        var previousDate: Date?

        for snapshot in snapshots {
            // Identity uniqueness
            if seenIDs.contains(snapshot.id) {
                issues.append(
                    ContainerPolicyViolation(
                        containerId: containerId,
                        ruleId: "snapshot_duplicate_id",
                        severity: .high,
                        message: "Duplicate snapshot identifier '\(snapshot.id)'.",
                        remediation: "Assign unique IDs to all rollback snapshots."
                    )
                )
            }
            seenIDs.insert(snapshot.id)

            // Container binding
            if snapshot.containerId != containerId {
                issues.append(
                    ContainerPolicyViolation(
                        containerId: containerId,
                        ruleId: "snapshot_container_mismatch",
                        severity: .critical,
                        message: "Snapshot '\(snapshot.name)' is bound to foreign container '\(snapshot.containerId)', not '\(containerId)'.",
                        remediation: "Verify snapshot ownership before applying rollback."
                    )
                )
            }

            // Name presence
            if snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(
                    ContainerPolicyViolation(
                        containerId: containerId,
                        ruleId: "snapshot_empty_name",
                        severity: .high,
                        message: "Snapshot id '\(snapshot.id)' has an empty name.",
                        remediation: "Provide a descriptive snapshot name."
                    )
                )
            }

            // Chronological order verification
            if let prev = previousDate, snapshot.createdAt < prev {
                issues.append(
                    ContainerPolicyViolation(
                        containerId: containerId,
                        ruleId: "snapshot_non_monotonic_timestamp",
                        severity: .medium,
                        message: "Snapshot '\(snapshot.name)' has timestamp earlier than preceding record.",
                        remediation: "Maintain strict monotonic timestamp sequence for snapshots."
                    )
                )
            }
            previousDate = snapshot.createdAt
        }

        return issues
    }
}
