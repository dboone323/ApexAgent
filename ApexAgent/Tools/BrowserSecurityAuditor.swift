import Foundation

// MARK: - Browser Automation DOM Sandbox & URL Restrictions Gate (Batch 91)

/// Policy constraints for browser automation navigation and DOM extraction.
public struct BrowserURLPolicy: Sendable, Codable, Equatable {
    public var allowedSchemes: Set<String>
    public var blockedHosts: Set<String>
    public var blockedIPRanges: [String]
    public var maxScrapeLengthBytes: Int
    public var allowLocalhost: Bool

    public init(
        allowedSchemes: Set<String> = ["http", "https", "data"],
        blockedHosts: Set<String> = [
            "169.254.169.254", // Cloud Instance Metadata
            "metadata.google.internal",
            "metadata.azure.internal",
            "instance-data"
        ],
        blockedIPRanges: [String] = ["169.254."],
        maxScrapeLengthBytes: Int = 250_000,
        allowLocalhost: Bool = true
    ) {
        self.allowedSchemes = allowedSchemes
        self.blockedHosts = blockedHosts
        self.blockedIPRanges = blockedIPRanges
        self.maxScrapeLengthBytes = maxScrapeLengthBytes
        self.allowLocalhost = allowLocalhost
    }
}

/// Violation detected when verifying browser navigation requests or DOM selectors.
public struct BrowserSecurityViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Audit report produced by evaluating browser navigation requests.
public struct BrowserSecurityReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let sanitizedURL: URL?
    public let violations: [BrowserSecurityViolation]

    public init(
        passed: Bool,
        score: Double,
        sanitizedURL: URL?,
        violations: [BrowserSecurityViolation]
    ) {
        self.passed = passed
        self.score = score
        self.sanitizedURL = sanitizedURL
        self.violations = violations
    }
}

/// Security auditor for headless browser automation, URL schemes, cloud metadata SSRF defense, and DOM sanitization.
public enum BrowserSecurityAuditor {

    // Dangerous URL schemes blocked to prevent local file leaks or protocol hijacking
    public static let prohibitedSchemes: Set<String> = [
        "file", "javascript", "applescript", "shell", "telnet", "ssh", "gopher", "dict", "ldap"
    ]

    // MARK: - URL Audit & SSRF Defense

    /// Audits a navigation destination URL against protocol schemes, metadata endpoints, and format sanity.
    public static func auditNavigationURL(
        _ urlString: String,
        policy: BrowserURLPolicy = BrowserURLPolicy()
    ) -> BrowserSecurityReport {
        var violations: [BrowserSecurityViolation] = []
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            violations.append(BrowserSecurityViolation(
                code: "EMPTY_URL",
                message: "Target URL cannot be empty."
            ))
            return BrowserSecurityReport(passed: false, score: 0.0, sanitizedURL: nil, violations: violations)
        }

        // Check if raw string already has a scheme (e.g. http:, https:, file:, javascript:)
        let hasScheme = trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil
        let normalized = hasScheme ? trimmed : "https://" + trimmed

        guard let url = URL(string: normalized) else {
            violations.append(BrowserSecurityViolation(
                code: "MALFORMED_URL",
                message: "String '\(urlString)' could not be parsed as a valid URL."
            ))
            return BrowserSecurityReport(passed: false, score: 0.0, sanitizedURL: nil, violations: violations)
        }

        let scheme = (url.scheme ?? "").lowercased()

        // 1. Prohibited scheme check
        if prohibitedSchemes.contains(scheme) {
            violations.append(BrowserSecurityViolation(
                code: "PROHIBITED_URL_SCHEME",
                message: "URL scheme '\(scheme)' is strictly disallowed for browser automation."
            ))
        } else if !policy.allowedSchemes.contains(scheme) {
            violations.append(BrowserSecurityViolation(
                code: "UNAUTHORIZED_URL_SCHEME",
                message: "URL scheme '\(scheme)' is not in the allowed schemes list."
            ))
        }

        // 2. Host check for metadata & SSRF targets
        if let host = url.host?.lowercased() {
            if policy.blockedHosts.contains(host) || policy.blockedIPRanges.contains(where: { host.hasPrefix($0) }) {
                violations.append(BrowserSecurityViolation(
                    code: "CLOUD_METADATA_ENDPOINT_BLOCKED",
                    message: "Navigation to cloud instance metadata service '\(host)' is blocked to prevent SSRF."
                ))
            }

            if !policy.allowLocalhost && (host == "localhost" || host == "127.0.0.1" || host == "::1") {
                violations.append(BrowserSecurityViolation(
                    code: "LOCALHOST_NAVIGATION_DISALLOWED",
                    message: "Navigation to localhost is disabled by policy."
                ))
            }
        } else if scheme != "data" {
            violations.append(BrowserSecurityViolation(
                code: "MISSING_URL_HOST",
                message: "URL specifies no host destination."
            ))
        }

        // 3. UserInfo credential leak check (e.g. https://user:pass@host)
        if url.user != nil || url.password != nil {
            violations.append(BrowserSecurityViolation(
                code: "EMBEDDED_CREDENTIALS_IN_URL",
                message: "URL embeds user credentials in the authority component.",
                isFatal: false
            ))
        }

        let fatalViolations = violations.filter(\.isFatal)
        let nonFatalViolations = violations.filter { !$0.isFatal }
        let passed = fatalViolations.isEmpty

        var score = 100.0 - Double(fatalViolations.count) * 25.0 - Double(nonFatalViolations.count) * 10.0
        score = max(0.0, min(100.0, score))

        return BrowserSecurityReport(
            passed: passed,
            score: score,
            sanitizedURL: passed ? url : nil,
            violations: violations
        )
    }

    // MARK: - DOM Selector & Scraped Content Sanitization

    /// Sanitizes CSS/DOM selector string to prevent JavaScript injection in evaluateJavaScript.
    public static func sanitizeDOMSelector(_ rawSelector: String) -> String? {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Block JavaScript quotes, escape characters, and evaluation payloads
        let dangerousSubstrings = [
            "<script", "</script>", "javascript:", "eval(", "Function(", "window.", "document.", ";", "\"", "\\", "\n", "\r"
        ]
        let lower = trimmed.lowercased()
        for dangerous in dangerousSubstrings {
            if lower.contains(dangerous) {
                return nil
            }
        }

        return trimmed
    }

    /// Truncates scraped webpage content to prevent memory buffer bloat.
    public static func sanitizeScrapedContent(_ content: String, maxBytes: Int = 250_000) -> String {
        guard let data = content.data(using: .utf8), data.count > maxBytes else {
            return content
        }
        let truncatedData = data.prefix(maxBytes)
        let safeString = String(decoding: truncatedData, as: UTF8.self)
        return safeString + "\n\n[TRUNCATED: Scraped content exceeded \(maxBytes) bytes]"
    }
}
