import Foundation

// MARK: - System Diagnostics OSLog Query Predicate Sanitizer Gate (Batch 89)

/// Sanitized and bounds-checked query configuration for OSLogStore queries.
public struct SanitizedLogQuery: Sendable, Codable, Equatable {
    public let subsystem: String?
    public let category: String?
    public let level: String?
    public let lastSeconds: Int
    public let searchText: String?
    public let limit: Int

    public init(
        subsystem: String?,
        category: String?,
        level: String?,
        lastSeconds: Int,
        searchText: String?,
        limit: Int
    ) {
        self.subsystem = subsystem
        self.category = category
        self.level = level
        self.lastSeconds = lastSeconds
        self.searchText = searchText
        self.limit = limit
    }
}

/// Violation encountered when auditing a diagnostics log query.
public struct DiagnosticQueryViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Audit report produced by evaluating an OSLog query request.
public struct DiagnosticQueryAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let sanitizedQuery: SanitizedLogQuery?
    public let violations: [DiagnosticQueryViolation]

    public init(
        passed: Bool,
        score: Double,
        sanitizedQuery: SanitizedLogQuery?,
        violations: [DiagnosticQueryViolation]
    ) {
        self.passed = passed
        self.score = score
        self.sanitizedQuery = sanitizedQuery
        self.violations = violations
    }
}

/// Security auditor and sanitizer for OSLogStore diagnostic queries.
public enum DiagnosticQuerySecurityAuditor {

    public static let maxLookbackSeconds: Int = 86400 // 24 hours
    public static let defaultLookbackSeconds: Int = 300 // 5 minutes
    public static let maxEntriesLimit: Int = 500
    public static let defaultEntriesLimit: Int = 50

    public static let validLogLevels: Set<String> = [
        "debug", "info", "notice", "error", "fault"
    ]

    // MARK: - Sensitive Data Masking

    private static let sensitivePatterns: [(pattern: String, replacement: String)] = [
        (#"(?i)bearer\s+[A-Za-z0-9_\.\-]+"#, "Bearer [REDACTED_TOKEN]"),
        (#"(?i)(api[-_]?key|auth[-_]?token|secret|password|passwd)\s*[:=]\s*['"]?[^\s'";,]+['"]?"#, "$1=[REDACTED]"),
        (#"ghp_[A-Za-z0-9]{36}"#, "ghp_[REDACTED]"),
        (#"sk-[A-Za-z0-9]{32,}"#, "sk-[REDACTED]")
    ]

    /// Masks secrets, tokens, API keys, and passwords within log message output.
    public static func maskSensitiveLogContent(_ rawMessage: String) -> String {
        var masked = rawMessage
        for (pattern, replacement) in sensitivePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: (masked as NSString).length)
                masked = regex.stringByReplacingMatches(in: masked, options: [], range: range, withTemplate: replacement)
            }
        }
        return masked
    }

    // MARK: - Query Sanitization & Audit

    /// Audits and sanitizes an OSLog query request, enforcing bounds and rejecting injection attempts.
    public static func auditAndSanitizeQuery(
        subsystem: String? = nil,
        category: String? = nil,
        level: String? = nil,
        lastSeconds: Int? = nil,
        searchText: String? = nil,
        limit: Int? = nil
    ) -> DiagnosticQueryAuditReport {
        var violations: [DiagnosticQueryViolation] = []

        // 1. Subsystem format & injection check
        var sanitizedSubsystem: String? = nil
        if let sub = subsystem?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty {
            if sub.contains(";") || sub.contains("==") || sub.contains("!=") || sub.lowercased().contains("truepredicate") {
                violations.append(DiagnosticQueryViolation(
                    code: "PREDICATE_INJECTION_DETECTED",
                    message: "Subsystem contains prohibited predicate injection characters."
                ))
            } else if sub.range(of: #"^[A-Za-z0-9_\.\-]+$"#, options: .regularExpression) == nil {
                violations.append(DiagnosticQueryViolation(
                    code: "INVALID_SUBSYSTEM_SYNTAX",
                    message: "Subsystem must follow reverse-DNS alphanumeric naming convention."
                ))
            } else {
                sanitizedSubsystem = sub
            }
        }

        // 2. Category check
        var sanitizedCategory: String? = nil
        if let cat = category?.trimmingCharacters(in: .whitespacesAndNewlines), !cat.isEmpty {
            if cat.contains(";") || cat.contains("==") || cat.lowercased().contains("truepredicate") {
                violations.append(DiagnosticQueryViolation(
                    code: "PREDICATE_INJECTION_DETECTED",
                    message: "Category contains prohibited predicate injection characters."
                ))
            } else {
                sanitizedCategory = cat
            }
        }

        // 3. Log level validation
        var sanitizedLevel: String? = nil
        if let lvl = level?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !lvl.isEmpty {
            if validLogLevels.contains(lvl) {
                sanitizedLevel = lvl
            } else {
                violations.append(DiagnosticQueryViolation(
                    code: "INVALID_LOG_LEVEL",
                    message: "Unknown log level '\(lvl)'. Valid levels: debug, info, notice, error, fault.",
                    isFatal: false
                ))
            }
        }

        // 4. Lookback time bounds check
        let rawLookback = lastSeconds ?? defaultLookbackSeconds
        let clampedLookback: Int
        if rawLookback <= 0 {
            violations.append(DiagnosticQueryViolation(
                code: "NON_POSITIVE_LOOKBACK",
                message: "Lookback window cannot be negative or zero (\(rawLookback)s)."
            ))
            clampedLookback = defaultLookbackSeconds
        } else if rawLookback > maxLookbackSeconds {
            violations.append(DiagnosticQueryViolation(
                code: "LOOKBACK_EXCEEDS_MAXIMUM",
                message: "Requested lookback \(rawLookback)s exceeds 24-hour maximum (\(maxLookbackSeconds)s). Clamped.",
                isFatal: false
            ))
            clampedLookback = maxLookbackSeconds
        } else {
            clampedLookback = rawLookback
        }

        // 5. Entries limit bounds check
        let rawLimit = limit ?? defaultEntriesLimit
        let clampedLimit: Int
        if rawLimit <= 0 {
            violations.append(DiagnosticQueryViolation(
                code: "NON_POSITIVE_LIMIT",
                message: "Log limit cannot be negative or zero (\(rawLimit))."
            ))
            clampedLimit = defaultEntriesLimit
        } else if rawLimit > maxEntriesLimit {
            violations.append(DiagnosticQueryViolation(
                code: "LIMIT_EXCEEDS_MAXIMUM",
                message: "Requested limit \(rawLimit) exceeds maximum ceiling (\(maxEntriesLimit)). Clamped.",
                isFatal: false
            ))
            clampedLimit = maxEntriesLimit
        } else {
            clampedLimit = rawLimit
        }

        // 6. Search text sanitization
        let sanitizedSearch = searchText?.trimmingCharacters(in: .whitespacesAndNewlines)

        let fatalViolations = violations.filter(\.isFatal)
        let nonFatalViolations = violations.filter { !$0.isFatal }
        let passed = fatalViolations.isEmpty

        var score = 100.0 - Double(fatalViolations.count) * 25.0 - Double(nonFatalViolations.count) * 10.0
        score = max(0.0, min(100.0, score))

        let query = passed ? SanitizedLogQuery(
            subsystem: sanitizedSubsystem,
            category: sanitizedCategory,
            level: sanitizedLevel,
            lastSeconds: clampedLookback,
            searchText: sanitizedSearch,
            limit: clampedLimit
        ) : nil

        return DiagnosticQueryAuditReport(
            passed: passed,
            score: score,
            sanitizedQuery: query,
            violations: violations
        )
    }
}
