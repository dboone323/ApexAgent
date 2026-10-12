//
//  TransactionalEmailAuditor.swift
//  ApexAgent
//
//  Created for Batch 116: Transactional Email Dispatcher & Deliverability Auditor.
//

import Foundation

// MARK: - Email Models

public struct EmailAddress: Sendable, Codable, Equatable, Hashable {
    public let name: String?
    public let address: String

    public init?(address: String, name: String? = nil) {
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanAddress.isEmpty else { return nil }

        // Block CRLF injection in email address
        if cleanAddress.contains("\r") || cleanAddress.contains("\n") {
            return nil
        }

        // Validate basic RFC 5322 structure
        guard cleanAddress.contains("@") && cleanAddress.contains(".") else {
            return nil
        }
        let parts = cleanAddress.components(separatedBy: "@")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }

        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")

        self.address = cleanAddress
        self.name = cleanName?.isEmpty == true ? nil : cleanName
    }

    public var formatted: String {
        if let n = name {
            return "\(n) <\(address)>"
        }
        return address
    }
}

public struct EmailRecipientList: Sendable, Codable, Equatable {
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let bcc: [EmailAddress]

    public init(to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = []) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
    }
}

public struct EmailMessage: Sendable, Codable, Equatable {
    public let from: EmailAddress
    public let recipients: EmailRecipientList
    public let subject: String
    public let textBody: String?
    public let htmlBody: String?
    public let replyTo: EmailAddress?
    public let tags: [String]

    public init(
        from: EmailAddress,
        recipients: EmailRecipientList,
        subject: String,
        textBody: String? = nil,
        htmlBody: String? = nil,
        replyTo: EmailAddress? = nil,
        tags: [String] = []
    ) {
        self.from = from
        self.recipients = recipients
        // Sanitize subject against header injection
        self.subject = subject.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.replyTo = replyTo
        self.tags = tags
    }
}

public enum TransactionalEmailProvider: String, Sendable, Codable, Equatable {
    case resend
    case postmark
    case ses
    case mailgun
    case generic
}

// MARK: - Email Audit Violation & Report

public struct EmailAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct EmailAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let provider: TransactionalEmailProvider
    public let recipientCount: Int
    public let hasHtmlBody: Bool
    public let violations: [EmailAuditViolation]
    public let redactedKey: String?

    public init(
        passed: Bool,
        score: Double,
        provider: TransactionalEmailProvider,
        recipientCount: Int,
        hasHtmlBody: Bool,
        violations: [EmailAuditViolation],
        redactedKey: String?
    ) {
        self.passed = passed
        self.score = score
        self.provider = provider
        self.recipientCount = recipientCount
        self.hasHtmlBody = hasHtmlBody
        self.violations = violations
        self.redactedKey = redactedKey
    }
}

// MARK: - Transactional Email Auditor

public enum TransactionalEmailAuditor {

    public static let resendBaseURL = URL(string: "https://api.resend.com/emails")!
    public static let postmarkBaseURL = URL(string: "https://api.postmarkapp.com/email")!

    // MARK: - Message Audit

    public static func auditMessage(
        message: EmailMessage,
        apiKey: String,
        provider: TransactionalEmailProvider = .resend
    ) -> EmailAuditReport {
        var violations: [EmailAuditViolation] = []
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. API Key Validation
        if cleanKey.isEmpty {
            violations.append(EmailAuditViolation(
                code: "EMPTY_EMAIL_API_KEY",
                message: "Email provider API key or server token cannot be empty.",
                isFatal: true
            ))
        } else if cleanKey.count < 8 {
            violations.append(EmailAuditViolation(
                code: "SUSPICIOUS_SHORT_KEY",
                message: "API key is suspiciously short (< 8 chars).",
                isFatal: true
            ))
        }

        // 2. Recipients check
        let totalRecipients = message.recipients.to.count + message.recipients.cc.count + message.recipients.bcc.count
        if message.recipients.to.isEmpty {
            violations.append(EmailAuditViolation(
                code: "MISSING_PRIMARY_RECIPIENT",
                message: "Email must have at least one recipient in 'to' list.",
                isFatal: true
            ))
        } else if totalRecipients > 50 {
            violations.append(EmailAuditViolation(
                code: "EXCESSIVE_RECIPIENT_COUNT",
                message: "Transactional email exceeds maximum safe batch limit of 50 recipients.",
                isFatal: true
            ))
        }

        // 3. Body Presence check
        let hasText = !(message.textBody?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasHtml = !(message.htmlBody?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !hasText && !hasHtml {
            violations.append(EmailAuditViolation(
                code: "EMPTY_EMAIL_BODY",
                message: "Email message must contain either a plain-text or HTML body.",
                isFatal: true
            ))
        }

        // 4. Subject check
        let cleanSubject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanSubject.isEmpty {
            violations.append(EmailAuditViolation(
                code: "EMPTY_EMAIL_SUBJECT",
                message: "Email subject line cannot be empty.",
                isFatal: true
            ))
        } else if cleanSubject.count > 250 {
            violations.append(EmailAuditViolation(
                code: "EXCESSIVE_SUBJECT_LENGTH",
                message: "Email subject exceeds 250 characters, high spam score risk.",
                isFatal: false
            ))
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let nonFatalCount = violations.filter { !$0.isFatal }.count
        let rawScore = 100.0 - (Double(fatalCount) * 50.0) - (Double(nonFatalCount) * 15.0)
        let finalScore = max(0.0, min(100.0, rawScore))
        let passed = (fatalCount == 0)

        var redacted: String? = nil
        if !cleanKey.isEmpty {
            if cleanKey.count > 8 {
                let p = cleanKey.prefix(3)
                let s = cleanKey.suffix(3)
                redacted = "\(p)...\(s)"
            } else {
                redacted = "***"
            }
        }

        return EmailAuditReport(
            passed: passed,
            score: finalScore,
            provider: provider,
            recipientCount: totalRecipients,
            hasHtmlBody: hasHtml,
            violations: violations,
            redactedKey: redacted
        )
    }

    // MARK: - Resend Request Builder

    public static func buildResendRequest(
        apiKey: String,
        message: EmailMessage,
        endpointURL: URL = resendBaseURL
    ) -> URLRequest? {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !message.recipients.to.isEmpty else { return nil }

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        var bodyDict: [String: Any] = [
            "from": message.from.formatted,
            "to": message.recipients.to.map(\.address),
            "subject": message.subject
        ]
        if !message.recipients.cc.isEmpty {
            bodyDict["cc"] = message.recipients.cc.map(\.address)
        }
        if !message.recipients.bcc.isEmpty {
            bodyDict["bcc"] = message.recipients.bcc.map(\.address)
        }
        if let text = message.textBody {
            bodyDict["text"] = text
        }
        if let html = message.htmlBody {
            bodyDict["html"] = html
        }
        if let reply = message.replyTo {
            bodyDict["reply_to"] = reply.formatted
        }

        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    // MARK: - Postmark Request Builder

    public static func buildPostmarkRequest(
        serverToken: String,
        message: EmailMessage,
        endpointURL: URL = postmarkBaseURL
    ) -> URLRequest? {
        let cleanToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, !message.recipients.to.isEmpty else { return nil }

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.setValue(cleanToken, forHTTPHeaderField: "X-Postmark-Server-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        var bodyDict: [String: Any] = [
            "From": message.from.formatted,
            "To": message.recipients.to.map(\.address).joined(separator: ","),
            "Subject": message.subject
        ]
        if !message.recipients.cc.isEmpty {
            bodyDict["Cc"] = message.recipients.cc.map(\.address).joined(separator: ",")
        }
        if !message.recipients.bcc.isEmpty {
            bodyDict["Bcc"] = message.recipients.bcc.map(\.address).joined(separator: ",")
        }
        if let text = message.textBody {
            bodyDict["TextBody"] = text
        }
        if let html = message.htmlBody {
            bodyDict["HtmlBody"] = html
        }
        if let reply = message.replyTo {
            bodyDict["ReplyTo"] = reply.formatted
        }

        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    // MARK: - Markdown Formatter

    public static func formatEmailAuditReportMarkdown(_ report: EmailAuditReport) -> String {
        var md = "### ✉️ Transactional Email Dispatch Audit\n\n"
        md += "| Parameter | Value |\n"
        md += "|---|---|\n"
        md += "| **Status** | \(report.passed ? "✅ Compliant" : "❌ Non-Compliant") |\n"
        md += "| **Score** | `\(String(format: "%.1f", report.score))%` |\n"
        md += "| **Provider** | `\(report.provider.rawValue)` |\n"
        md += "| **Recipients Count** | `\(report.recipientCount)` |\n"
        md += "| **Has HTML Body** | `\(report.hasHtmlBody ? "Yes" : "No")` |\n"
        md += "| **Token Preview** | `\(report.redactedKey ?? "N/A")` |\n\n"

        if report.violations.isEmpty {
            md += "✨ **Zero violations found.** Transactional email payload conforms to anti-spam & deliverability standards.\n"
        } else {
            md += "#### Violations (\(report.violations.count))\n\n"
            for v in report.violations {
                let badge = v.isFatal ? "🔴 FATAL" : "🟡 WARN"
                md += "- \(badge) `\(v.code)`: \(v.message)\n"
            }
        }
        return md
    }
}
