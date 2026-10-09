import Foundation

// MARK: - Network Diagnostics & Host Reachability Resilience Gate (Batch 68)

/// Severity of a network security or resilience violation.
public enum NetworkViolationSeverity: String, Codable, Sendable, Comparable {
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

    public static func < (lhs: NetworkViolationSeverity, rhs: NetworkViolationSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A specific violation detected during network diagnostic evaluation.
public struct NetworkViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(targetHost):\(ruleId):\(message)" }
    public let targetHost: String
    public let ruleId: String
    public let severity: NetworkViolationSeverity
    public let message: String
    public let remediation: String

    public init(
        targetHost: String,
        ruleId: String,
        severity: NetworkViolationSeverity,
        message: String,
        remediation: String
    ) {
        self.targetHost = targetHost
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// Parameters for a proposed network probe.
public struct NetworkProbeSpec: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int
    public let timeoutSeconds: TimeInterval

    public init(host: String, port: Int = 443, timeoutSeconds: TimeInterval = 10.0) {
        self.host = host
        self.port = port
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Aggregated report produced by `NetworkResilienceAuditor`.
public struct NetworkResilienceAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedProbesCount: Int
    public let violations: [NetworkViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        evaluatedProbesCount: Int,
        violations: [NetworkViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedProbesCount = evaluatedProbesCount
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

/// Autonomous gate ensuring all network probes, reachability diagnostics, and DNS queries
/// adhere to SSRF protections, timeout boundaries, and valid port ranges.
public enum NetworkResilienceAuditor {

    /// Cloud metadata endpoints and link-local address prefixes strictly blocked from probing.
    public static let blockedMetadataPrefixes: [String] = [
        "169.254.169.254",
        "metadata.google.internal",
        "169.254.",
        "fe80:"
    ]

    /// Prohibited administrative or high-risk ports.
    public static let sensitivePorts: Set<Int> = [
        22,   // SSH
        23,   // Telnet
        25,   // SMTP
        445,  // SMB
        3389  // RDP
    ]

    public static let maxAllowedTimeoutSeconds: TimeInterval = 30.0
    public static let minAllowedTimeoutSeconds: TimeInterval = 0.5

    /// Audits a collection of proposed network probe specifications.
    public static func audit(probes: [NetworkProbeSpec]) -> NetworkResilienceAuditReport {
        guard !probes.isEmpty else {
            return NetworkResilienceAuditReport(
                passed: true,
                score: 100.0,
                evaluatedProbesCount: 0,
                violations: [],
                recommendations: ["No network probes evaluated."]
            )
        }

        var violations: [NetworkViolation] = []

        for probe in probes {
            let host = probe.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            // Rule 1: Injection & malformed host check
            if host.isEmpty || host.contains("\0") || host.contains(";") || host.contains("&") || host.contains("|") || host.contains("`") {
                violations.append(
                    NetworkViolation(
                        targetHost: probe.host,
                        ruleId: "NET-001",
                        severity: .critical,
                        message: "Target host '\(probe.host)' contains illegal characters or command injection tokens.",
                        remediation: "Provide a valid DNS hostname or IP address without shell delimiters."
                    )
                )
            }

            // Rule 2: SSRF metadata endpoint defense
            for prefix in blockedMetadataPrefixes {
                if host == prefix || host.hasPrefix(prefix) {
                    violations.append(
                        NetworkViolation(
                            targetHost: probe.host,
                            ruleId: "NET-002",
                            severity: .critical,
                            message: "Target host '\(probe.host)' attempts to access protected cloud metadata or link-local address (\(prefix)).",
                            remediation: "Block SSRF queries to cloud instance metadata services."
                        )
                    )
                    break
                }
            }

            // Rule 3: Valid TCP port range
            if probe.port < 1 || probe.port > 65535 {
                violations.append(
                    NetworkViolation(
                        targetHost: probe.host,
                        ruleId: "NET-003",
                        severity: .critical,
                        message: "Port \(probe.port) is outside valid TCP port range [1 ... 65535].",
                        remediation: "Use a valid TCP port number."
                    )
                )
            } else if sensitivePorts.contains(probe.port) {
                violations.append(
                    NetworkViolation(
                        targetHost: probe.host,
                        ruleId: "NET-004",
                        severity: .medium,
                        message: "Probing sensitive administrative port \(probe.port) on host '\(probe.host)'.",
                        remediation: "Verify explicit administrator approval for administrative port probing."
                    )
                )
            }

            // Rule 4: Timeout bounds
            if probe.timeoutSeconds > maxAllowedTimeoutSeconds || probe.timeoutSeconds < minAllowedTimeoutSeconds {
                violations.append(
                    NetworkViolation(
                        targetHost: probe.host,
                        ruleId: "NET-005",
                        severity: .high,
                        message: "Timeout of \(probe.timeoutSeconds)s is outside safe bounds [\(minAllowedTimeoutSeconds)s ... \(maxAllowedTimeoutSeconds)s].",
                        remediation: "Clamp probe timeout between 0.5s and 30.0s."
                    )
                )
            }
        }

        let penalty = violations.reduce(0.0) { acc, v in
            switch v.severity {
            case .critical: return acc + 35.0
            case .high: return acc + 20.0
            case .medium: return acc + 10.0
            case .low: return acc + 5.0
            case .info: return acc + 1.0
            }
        }

        let score = max(0.0, 100.0 - penalty)
        let hasCriticalOrHigh = violations.contains { $0.severity >= .high }
        let passed = !hasCriticalOrHigh && score >= 80.0

        var recs: [String] = []
        if !passed {
            recs.append("Prevent SSRF attempts against cloud metadata endpoints and clamp probe timeouts.")
        }

        return NetworkResilienceAuditReport(
            passed: passed,
            score: score,
            evaluatedProbesCount: probes.count,
            violations: violations,
            recommendations: recs
        )
    }

    /// Computes summary latency percentiles across an array of latency sample milliseconds.
    public static func computeLatencyStats(samplesMs: [Double]) -> (p50: Double, p95: Double, min: Double, max: Double) {
        guard !samplesMs.isEmpty else { return (0, 0, 0, 0) }
        let sorted = samplesMs.sorted()
        let count = sorted.count

        let p50Index = min(count - 1, Int(round(Double(count - 1) * 0.50)))
        let p95Index = min(count - 1, Int(round(Double(count - 1) * 0.95)))

        return (
            p50: sorted[p50Index],
            p95: sorted[p95Index],
            min: sorted.first ?? 0,
            max: sorted.last ?? 0
        )
    }
}
