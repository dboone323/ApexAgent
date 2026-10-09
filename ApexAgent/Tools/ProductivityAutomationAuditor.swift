import Foundation

// MARK: - Personal Productivity Event Sanitizer Gate (Batch 95)

/// Validation result for email recipient addresses.
public struct EmailRecipientValidation: Sendable, Codable, Equatable {
    public let isValid: Bool
    public let sanitizedEmail: String?
    public let hasHeaderInjection: Bool

    public init(isValid: Bool, sanitizedEmail: String?, hasHeaderInjection: Bool) {
        self.isValid = isValid
        self.sanitizedEmail = sanitizedEmail
        self.hasHeaderInjection = hasHeaderInjection
    }
}

/// Violation detected during calendar, reminder, or email parameter validation.
public struct ProductivityViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Comprehensive audit report for personal productivity actions.
public struct ProductivityAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let violations: [ProductivityViolation]

    public init(passed: Bool, score: Double, violations: [ProductivityViolation]) {
        self.passed = passed
        self.score = score
        self.violations = violations
    }
}

/// Security auditor and input sanitizer for Calendar, Reminder, and Mail automation tools.
public enum ProductivityAutomationAuditor {

    private static let emailRegex = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#

    // MARK: - Email Recipient & Header Injection Sanitizer

    /// Validates an email recipient address, strictly blocking CRLF injection and validating syntax.
    public static func validateEmailRecipient(_ email: String) -> EmailRecipientValidation {
        // Detect CRLF / SMTP header injection attempts
        if email.contains("\r") || email.contains("\n") ||
           email.localizedCaseInsensitiveContains("bcc:") ||
           email.localizedCaseInsensitiveContains("cc:") ||
           email.localizedCaseInsensitiveContains("to:") {
            return EmailRecipientValidation(
                isValid: false,
                sanitizedEmail: nil,
                hasHeaderInjection: true
            )
        }

        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return EmailRecipientValidation(isValid: false, sanitizedEmail: nil, hasHeaderInjection: false)
        }

        let isMatch = trimmed.range(of: emailRegex, options: .regularExpression) != nil
        return EmailRecipientValidation(
            isValid: isMatch,
            sanitizedEmail: isMatch ? trimmed : nil,
            hasHeaderInjection: false
        )
    }

    // MARK: - Calendar Event Audit

    /// Audits calendar event parameters for temporal consistency, title presence, and duration limits.
    public static func auditCalendarEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil
    ) -> ProductivityAuditReport {
        var violations: [ProductivityViolation] = []

        // 1. Title validation
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty {
            violations.append(ProductivityViolation(
                code: "EMPTY_EVENT_TITLE",
                message: "Calendar event title cannot be empty."
            ))
        }

        // 2. Date order validation
        if endDate < startDate {
            violations.append(ProductivityViolation(
                code: "END_DATE_PRECEDES_START_DATE",
                message: "Event end date (\(endDate)) cannot precede start date (\(startDate))."
            ))
        }

        // 3. Duration limits
        let durationSeconds = endDate.timeIntervalSince(startDate)
        if durationSeconds > 86400.0 * 7.0 { // Greater than 7 days
            violations.append(ProductivityViolation(
                code: "EXCESSIVE_EVENT_DURATION",
                message: "Event duration (\(Int(durationSeconds / 3600)) hours) exceeds 7-day single event threshold.",
                isFatal: false
            ))
        }

        let fatalViolations = violations.filter(\.isFatal)
        let nonFatalViolations = violations.filter { !$0.isFatal }
        let passed = fatalViolations.isEmpty

        var score = 100.0 - Double(fatalViolations.count) * 25.0 - Double(nonFatalViolations.count) * 10.0
        score = max(0.0, min(100.0, score))

        return ProductivityAuditReport(passed: passed, score: score, violations: violations)
    }

    // MARK: - Reminder Audit

    /// Audits reminder parameters, enforcing priority ranges (0..9 in EventKit) and title validity.
    public static func auditReminder(
        title: String,
        priority: Int? = nil,
        notes: String? = nil
    ) -> ProductivityAuditReport {
        var violations: [ProductivityViolation] = []

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty {
            violations.append(ProductivityViolation(
                code: "EMPTY_REMINDER_TITLE",
                message: "Reminder title cannot be empty."
            ))
        }

        if let prio = priority {
            if prio < 0 || prio > 9 {
                violations.append(ProductivityViolation(
                    code: "INVALID_REMINDER_PRIORITY",
                    message: "Reminder priority (\(prio)) must be between 0 (none) and 9 (high) per Apple EventKit conventions."
                ))
            }
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? 100.0 : max(0.0, 100.0 - Double(fatalViolations.count) * 25.0)

        return ProductivityAuditReport(passed: passed, score: score, violations: violations)
    }

    // MARK: - Text Content Sanitizer

    /// Strips control characters and null bytes from note / body text.
    public static func sanitizeTextContent(_ text: String) -> String {
        return text.filter { char in
            let scalar = char.unicodeScalars.first?.value ?? 0
            return scalar >= 32 || scalar == 9 || scalar == 10 || scalar == 13
        }
    }
}
