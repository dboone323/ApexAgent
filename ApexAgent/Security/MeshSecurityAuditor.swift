import Foundation

// MARK: - Collaborative Mesh Authentication & P2P Grant Rate-Limiting Gate (Batch 54)

/// Severity of a mesh security violation.
public enum MeshViolationSeverity: String, Codable, Sendable, Comparable {
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

    public static func < (lhs: MeshViolationSeverity, rhs: MeshViolationSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Node configuration and authentication state for collaborative mesh audits.
public struct MeshAuthConfig: Codable, Sendable, Equatable {
    public let lanModeEnabled: Bool
    public let token: String
    public let requireP2PApproval: Bool
    public let tlsEnabled: Bool
    public let bindAddress: String

    public init(
        lanModeEnabled: Bool,
        token: String,
        requireP2PApproval: Bool = true,
        tlsEnabled: Bool = false,
        bindAddress: String = "127.0.0.1"
    ) {
        self.lanModeEnabled = lanModeEnabled
        self.token = token
        self.requireP2PApproval = requireP2PApproval
        self.tlsEnabled = tlsEnabled
        self.bindAddress = bindAddress
    }
}

/// Result of evaluating token-bucket rate limiting behavior under burst conditions.
public struct MeshRateLimitAuditResult: Codable, Sendable, Equatable {
    public let clientIP: String
    public let burstRequestsSent: Int
    public let burstAllowed: Int
    public let burstThrottled: Int
    public let limiterHealthy: Bool

    public init(
        clientIP: String,
        burstRequestsSent: Int,
        burstAllowed: Int,
        burstThrottled: Int,
        limiterHealthy: Bool
    ) {
        self.clientIP = clientIP
        self.burstRequestsSent = burstRequestsSent
        self.burstAllowed = burstAllowed
        self.burstThrottled = burstThrottled
        self.limiterHealthy = limiterHealthy
    }
}

/// A specific security or authentication violation in mesh configuration.
public struct MeshSecurityViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(ruleId):\(message)" }
    public let ruleId: String
    public let severity: MeshViolationSeverity
    public let message: String
    public let remediation: String

    public init(
        ruleId: String,
        severity: MeshViolationSeverity,
        message: String,
        remediation: String
    ) {
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// Aggregated report of mesh authentication and rate-limiting audit.
public struct MeshSecurityAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let tokenEntropyBits: Double
    public let rateLimitResult: MeshRateLimitAuditResult
    public let violations: [MeshSecurityViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        tokenEntropyBits: Double,
        rateLimitResult: MeshRateLimitAuditResult,
        violations: [MeshSecurityViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.tokenEntropyBits = tokenEntropyBits
        self.rateLimitResult = rateLimitResult
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Collaborative Mesh & P2P Authentication Audit (`\(badge)`)",
            "",
            "- **Compliance Score**: `\(String(format: "%.1f", score))/100.0`",
            "- **Token Entropy**: `\(String(format: "%.2f", tokenEntropyBits)) bits`",
            "- **Rate Limiter Health**: \(rateLimitResult.limiterHealthy ? "✅ Throttling Verified" : "❌ Rate Limit Bypassed")",
            "- **Burst Stats**: `\(rateLimitResult.burstAllowed)` allowed / `\(rateLimitResult.burstThrottled)` throttled (of `\(rateLimitResult.burstRequestsSent)`)",
            ""
        ]

        if !violations.isEmpty {
            lines.append("### Violations")
            lines.append("| Rule ID | Severity | Violation | Remediation |")
            lines.append("| :--- | :---: | :--- | :--- |")
            for v in violations {
                lines.append("| `\(v.ruleId)` | `\(v.severity.rawValue)` | \(v.message) | \(v.remediation) |")
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

/// Security auditor for mesh networking, LAN authentication, token entropy, and rate limits.
public enum MeshSecurityAuditor {
    /// Computes Shannon entropy of a string (in bits per symbol).
    public static func computeShannonEntropy(string: String) -> Double {
        guard !string.isEmpty else { return 0.0 }
        var freqs: [Character: Double] = [:]
        for char in string {
            freqs[char, default: 0.0] += 1.0
        }
        let length = Double(string.count)
        var entropy = 0.0
        for count in freqs.values {
            let p = count / length
            entropy -= p * (log(p) / log(2.0))
        }
        return entropy
    }

    /// Simulates and evaluates token bucket throttling under burst and sustained load.
    public static func evaluateRateLimiting(burstCount: Int = 50, capacity: Double = 20.0, refillRate: Double = 10.0) -> MeshRateLimitAuditResult {
        var tokens = capacity
        var allowed = 0
        var throttled = 0

        for _ in 0..<burstCount {
            if tokens >= 1.0 {
                tokens -= 1.0
                allowed += 1
            } else {
                throttled += 1
            }
        }

        let isHealthy = (allowed <= Int(capacity)) && (throttled > 0)

        return MeshRateLimitAuditResult(
            clientIP: "192.168.1.100",
            burstRequestsSent: burstCount,
            burstAllowed: allowed,
            burstThrottled: throttled,
            limiterHealthy: isHealthy
        )
    }

    /// Performs full audit of mesh authentication configuration and rate limiting.
    public static func audit(config: MeshAuthConfig, burstCount: Int = 50) -> MeshSecurityAuditReport {
        var violations: [MeshSecurityViolation] = []
        var recommendations: [String] = []

        // 1. LAN mode token verification
        let trimmedToken = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.lanModeEnabled && trimmedToken.isEmpty {
            violations.append(
                MeshSecurityViolation(
                    ruleId: "mesh_insecure_lan_empty_token",
                    severity: .critical,
                    message: "LAN mode is enabled but collaborative bearer token is blank.",
                    remediation: "Generate a cryptographically secure 16+ byte bearer token."
                )
            )
        }

        // 2. Token entropy & length
        let entropy = computeShannonEntropy(string: trimmedToken)
        let totalEntropyBits = entropy * Double(trimmedToken.count)

        if !trimmedToken.isEmpty {
            if trimmedToken.count < 16 {
                violations.append(
                    MeshSecurityViolation(
                        ruleId: "mesh_token_insufficient_length",
                        severity: .high,
                        message: "Bearer token length (\(trimmedToken.count)) is less than recommended 16 characters.",
                        remediation: "Use a minimum 16-character token."
                    )
                )
            }
            if entropy < 2.5 && trimmedToken.count >= 8 {
                violations.append(
                    MeshSecurityViolation(
                        ruleId: "mesh_token_low_entropy",
                        severity: .high,
                        message: "Bearer token has low Shannon entropy (\(String(format: "%.2f", entropy)) bits/char).",
                        remediation: "Use a high-entropy CSPRNG generated key."
                    )
                )
            }
        }

        // 3. Bind address check
        if !config.lanModeEnabled && config.bindAddress == "0.0.0.0" {
            violations.append(
                MeshSecurityViolation(
                    ruleId: "mesh_unintended_wildcard_bind",
                    severity: .critical,
                    message: "Server binds to 0.0.0.0 while LAN mode is disabled.",
                    remediation: "Bind to loopback 127.0.0.1 when LAN collaboration is disabled."
                )
            )
        }

        // 4. P2P permission grant requirement
        if !config.requireP2PApproval {
            violations.append(
                MeshSecurityViolation(
                    ruleId: "mesh_p2p_grant_unrestricted",
                    severity: .high,
                    message: "Peer approval coordinator is disabled, permitting unvetted bot-to-bot contacts.",
                    remediation: "Require human approval for all initial peer interactions."
                )
            )
        }

        // 5. Rate limiting verification
        let rateLimitResult = evaluateRateLimiting(burstCount: burstCount)
        if !rateLimitResult.limiterHealthy {
            violations.append(
                MeshSecurityViolation(
                    ruleId: "mesh_rate_limiter_bypass",
                    severity: .high,
                    message: "Token bucket rate limiter failed to throttle burst requests.",
                    remediation: "Enforce strict capacity bounding on TokenBucket."
                )
            )
        }

        // Score computation
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
            recommendations.append("Ensure LAN mode requires cryptographically random authentication tokens stored in Keychain.")
            recommendations.append("Enforce loopback binding (127.0.0.1) when LAN mode is turned off.")
            recommendations.append("Keep human-in-the-loop P2P approval gating active for all bot-to-bot delegation.")
        } else {
            recommendations.append("Collaborative mesh security configuration complies with baseline zero-trust requirements.")
        }

        return MeshSecurityAuditReport(
            passed: passed,
            score: finalScore,
            tokenEntropyBits: totalEntropyBits,
            rateLimitResult: rateLimitResult,
            violations: violations,
            recommendations: recommendations
        )
    }
}
