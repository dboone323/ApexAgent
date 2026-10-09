import Foundation

// MARK: - Deep-Link Action Dispatcher & URL Scheme Route Gate (Batch 58)

/// Severity of a deep-link security or routing violation.
public enum DeepLinkViolationSeverity: String, Codable, Sendable, Comparable {
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

    public static func < (lhs: DeepLinkViolationSeverity, rhs: DeepLinkViolationSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A specific defect or injection attempt detected in deep link processing.
public struct DeepLinkSecurityViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(url):\(ruleId):\(message)" }
    public let url: String
    public let ruleId: String
    public let severity: DeepLinkViolationSeverity
    public let message: String
    public let remediation: String

    public init(
        url: String,
        ruleId: String,
        severity: DeepLinkViolationSeverity,
        message: String,
        remediation: String
    ) {
        self.url = url
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// A sanitized dispatch decision produced by `DeepLinkRouteGate`.
public struct DeepLinkDispatchAction: Sendable, Equatable {
    public let route: String
    public let destination: DeepLinkDestination?
    public let sanitizedParameters: [String: String]
    public let isPermitted: Bool

    public init(
        route: String,
        destination: DeepLinkDestination?,
        sanitizedParameters: [String: String] = [:],
        isPermitted: Bool
    ) {
        self.route = route
        self.destination = destination
        self.sanitizedParameters = sanitizedParameters
        self.isPermitted = isPermitted
    }
}

/// Aggregated report of deep link route testing and security auditing.
public struct DeepLinkRouteAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedURLs: Int
    public let violations: [DeepLinkSecurityViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        evaluatedURLs: Int,
        violations: [DeepLinkSecurityViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedURLs = evaluatedURLs
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Deep-Link Route Gate & Dispatcher Security Audit (`\(badge)`)",
            "",
            "- **Compliance Score**: `\(String(format: "%.1f", score))/100.0`",
            "- **URLs Evaluated**: `\(evaluatedURLs)`",
            "- **Violations Detected**: `\(violations.count)`",
            ""
        ]

        if !violations.isEmpty {
            lines.append("### Violations")
            lines.append("| URL | Rule ID | Severity | Violation | Remediation |")
            lines.append("| :--- | :--- | :---: | :--- | :--- |")
            for v in violations {
                let displayURL = v.url.prefix(40)
                lines.append("| `\(displayURL)` | `\(v.ruleId)` | `\(v.severity.rawValue)` | \(v.message) | \(v.remediation) |")
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

/// Security gateway that sanitizes, validates, and dispatches incoming deep link URLs.
public enum DeepLinkRouteGate {
    private static let dangerousQueryKeywords: [String] = [
        "<script", "javascript:", "eval(", "alert(", "document.cookie", "window.location", "%00"
    ]

    private static let embeddedSchemes: [String] = [
        "http://", "https://", "ftp://", "file://", "javascript:", "data:", "blob:"
    ]

    /// Sanitizes query parameters by stripping injection attacks and dangerous payloads.
    public static func sanitizeParameters(from url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return [:]
        }

        var cleanParams: [String: String] = [:]
        for item in queryItems {
            let key = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let val = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { continue }

            let lowerVal = val.lowercased()
            let isDangerous = dangerousQueryKeywords.contains { lowerVal.contains($0) }
            if !isDangerous {
                cleanParams[key] = val
            }
        }
        return cleanParams
    }

    /// Evaluates an incoming URL, performs sanitization, and returns an action and violations.
    public static func evaluateURL(_ url: URL) -> (action: DeepLinkDispatchAction, violations: [DeepLinkSecurityViolation]) {
        var violations: [DeepLinkSecurityViolation] = []
        let raw = url.absoluteString

        // 1. Scheme verification
        guard let scheme = url.scheme?.lowercased(), scheme == DeepLinkRouter.scheme else {
            violations.append(
                DeepLinkSecurityViolation(
                    url: raw,
                    ruleId: "deeplink_scheme_mismatch",
                    severity: .high,
                    message: "URL scheme '\(url.scheme ?? "nil")' does not match 'apexagent'.",
                    remediation: "Reject non-apexagent scheme."
                )
            )
            let action = DeepLinkDispatchAction(route: "unknown", destination: nil, isPermitted: false)
            return (action, violations)
        }

        // 2. Traversal and null byte detection
        if raw.contains("..") || raw.contains("%2e%2e") || raw.contains("\0") || raw.contains("%00") {
            violations.append(
                DeepLinkSecurityViolation(
                    url: raw,
                    ruleId: "deeplink_path_traversal",
                    severity: .critical,
                    message: "URL contains directory traversal sequences or null byte characters.",
                    remediation: "Reject and quarantine path traversal URLs."
                )
            )
        }

        // 3. Embedded URL scheme injection (SSRF / open redirect attempt)
        let rawLower = raw.lowercased()
        for embedded in embeddedSchemes {
            if rawLower.replacingOccurrences(of: "apexagent://", with: "").contains(embedded) {
                violations.append(
                    DeepLinkSecurityViolation(
                        url: raw,
                        ruleId: "deeplink_url_injection",
                        severity: .critical,
                        message: "URL contains embedded foreign scheme '\(embedded)'.",
                        remediation: "Reject foreign protocol URLs embedded in deep link."
                    )
                )
                break
            }
        }

        // 4. Query script injection
        if let query = url.query?.lowercased() {
            for keyword in dangerousQueryKeywords {
                if query.contains(keyword) {
                    violations.append(
                        DeepLinkSecurityViolation(
                            url: raw,
                            ruleId: "deeplink_query_script_injection",
                            severity: .high,
                            message: "Query parameters contain prohibited injection token '\(keyword)'.",
                            remediation: "Sanitize and drop malicious query parameters."
                        )
                    )
                    break
                }
            }
        }

        // 5. Parse destination via DeepLinkRouter
        let parseResult = DeepLinkRouter.parse(url)
        let destination: DeepLinkDestination?
        let routeName: String

        switch parseResult {
        case .success(let dest):
            destination = dest
            switch dest {
            case .chat: routeName = "chat"
            case .routine: routeName = "routine"
            case .skill: routeName = "skill"
            case .diagnostics: routeName = "diagnostics"
            case .settings: routeName = "settings"
            case .command: routeName = "command"
            }
        case .failure(let err):
            destination = nil
            routeName = "invalid"
            violations.append(
                DeepLinkSecurityViolation(
                    url: raw,
                    ruleId: "deeplink_parse_failure",
                    severity: .medium,
                    message: err.localizedDescription,
                    remediation: "Ensure route adheres to DeepLinkRouter format."
                )
            )
        }

        let cleanParams = sanitizeParameters(from: url)
        let isPermitted = violations.allSatisfy { $0.severity < .high }

        let action = DeepLinkDispatchAction(
            route: routeName,
            destination: isPermitted ? destination : nil,
            sanitizedParameters: cleanParams,
            isPermitted: isPermitted
        )

        return (action, violations)
    }

    /// Verifies bidirectional bijection: destination -> url -> destination.
    public static func verifyBijection(destination: DeepLinkDestination) -> Bool {
        let generatedURL = DeepLinkRouter.url(for: destination)
        let parsed = DeepLinkRouter.parse(generatedURL)
        switch parsed {
        case .success(let parsedDest):
            return parsedDest == destination
        case .failure:
            return false
        }
    }

    /// Audits a catalog of deep link URLs and bidirectional serialization contracts.
    public static func audit(urls: [URL], testDestinations: [DeepLinkDestination] = []) -> DeepLinkRouteAuditReport {
        var allViolations: [DeepLinkSecurityViolation] = []

        for url in urls {
            let (_, violations) = evaluateURL(url)
            allViolations.append(contentsOf: violations)
        }

        // Check bijection on test destinations
        for dest in testDestinations {
            if !verifyBijection(destination: dest) {
                let url = DeepLinkRouter.url(for: dest)
                allViolations.append(
                    DeepLinkSecurityViolation(
                        url: url.absoluteString,
                        ruleId: "deeplink_bidirectional_drift",
                        severity: .critical,
                        message: "DeepLinkDestination did not roundtrip cleanly through DeepLinkRouter.",
                        remediation: "Ensure URL parsing precisely matches DeepLinkRouter.url(for:)."
                    )
                )
            }
        }

        var deduction = 0.0
        for v in allViolations {
            switch v.severity {
            case .critical: deduction += 35.0
            case .high: deduction += 20.0
            case .medium: deduction += 10.0
            case .low: deduction += 5.0
            case .info: deduction += 1.0
            }
        }

        let finalScore = max(0.0, 100.0 - deduction)
        let hasCriticalOrHigh = allViolations.contains(where: { $0.severity == .critical || $0.severity == .high })
        let passed = finalScore >= 70.0 && !hasCriticalOrHigh

        var recommendations: [String] = []
        if !allViolations.isEmpty {
            recommendations.append("Enforce URL decoding before testing for path traversal patterns.")
            recommendations.append("Disallow foreign URL scheme encapsulation inside apexagent:// hosts or paths.")
            recommendations.append("Strip dangerous query parameters containing script tokens before route dispatch.")
        } else {
            recommendations.append("All evaluated deep link routes comply with router security and bijection policies.")
        }

        return DeepLinkRouteAuditReport(
            passed: passed,
            score: finalScore,
            evaluatedURLs: urls.count + testDestinations.count,
            violations: allViolations,
            recommendations: recommendations
        )
    }
}
