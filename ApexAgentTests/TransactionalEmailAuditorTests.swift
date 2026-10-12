//
//  TransactionalEmailAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 116: Transactional Email Dispatcher & Deliverability Auditor Tests.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 116 — Transactional Email & Deliverability Auditor Tests")
struct TransactionalEmailAuditorTests {

    @Test("EmailAddress validates format and strictly rejects CRLF injection attempts")
    func testEmailAddressValidationAndCRLFProtection() {
        let valid = EmailAddress(address: "alerts@apexagent.internal", name: "ApexAgent Alerts")
        #expect(valid != nil)
        #expect(valid?.formatted == "ApexAgent Alerts <alerts@apexagent.internal>")

        // CRLF injection attempt in email
        let injected = EmailAddress(address: "alerts@example.com\r\nBcc: evil@hacker.com")
        #expect(injected == nil)

        // Invalid address without domain
        let malformed = EmailAddress(address: "invalid-user-no-domain")
        #expect(malformed == nil)
    }

    @Test("Valid transactional email message passes audit with 100% score")
    func testValidMessageAudit() throws {
        let from = try #require(EmailAddress(address: "system@apexagent.com", name: "ApexAgent CI"))
        let to = try #require(EmailAddress(address: "admin@apexagent.com", name: "Admin"))
        let message = EmailMessage(
            from: from,
            recipients: EmailRecipientList(to: [to]),
            subject: "Security Audit Report Loop 14",
            textBody: "All 10 integration audits passed.",
            htmlBody: "<p>All 10 integration audits passed.</p>"
        )

        let report = TransactionalEmailAuditor.auditMessage(
            message: message,
            apiKey: "re_auditSampleKey123",
            provider: .resend
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.provider == .resend)
        #expect(report.recipientCount == 1)
        #expect(report.hasHtmlBody)
        #expect(report.violations.isEmpty)
        #expect(report.redactedKey?.contains("...") == true)
    }

    @Test("Empty subject, empty body, and empty API key trip fatal violations")
    func testEmptySubjectAndBodyTripViolations() throws {
        let from = try #require(EmailAddress(address: "system@apexagent.com"))
        let to = try #require(EmailAddress(address: "dev@apexagent.com"))
        let message = EmailMessage(
            from: from,
            recipients: EmailRecipientList(to: [to]),
            subject: "   ",
            textBody: "",
            htmlBody: ""
        )

        let report = TransactionalEmailAuditor.auditMessage(
            message: message,
            apiKey: ""
        )

        #expect(!report.passed)
        #expect(report.violations.contains(where: { $0.code == "EMPTY_EMAIL_SUBJECT" }))
        #expect(report.violations.contains(where: { $0.code == "EMPTY_EMAIL_BODY" }))
        #expect(report.violations.contains(where: { $0.code == "EMPTY_EMAIL_API_KEY" }))
    }

    @Test("buildResendRequest formats valid JSON payload and Bearer authorization header")
    func testBuildResendRequest() throws {
        let from = try #require(EmailAddress(address: "notifications@apexagent.com", name: "ApexAgent"))
        let to1 = try #require(EmailAddress(address: "user1@example.com"))
        let to2 = try #require(EmailAddress(address: "user2@example.com"))
        let message = EmailMessage(
            from: from,
            recipients: EmailRecipientList(to: [to1, to2]),
            subject: "Build Success",
            htmlBody: "<h1>Build Succeeded</h1>"
        )

        let req = TransactionalEmailAuditor.buildResendRequest(
            apiKey: "re_auditSampleKey123",
            message: message
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.resend.com/emails")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer re_auditSampleKey123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["from"] as? String == "ApexAgent <notifications@apexagent.com>")
        let toArr = bodyJson?["to"] as? [String]
        #expect(toArr == ["user1@example.com", "user2@example.com"])
        #expect(bodyJson?["subject"] as? String == "Build Success")
        #expect(bodyJson?["html"] as? String == "<h1>Build Succeeded</h1>")
    }

    @Test("buildPostmarkRequest formats valid JSON payload with Postmark server token header")
    func testBuildPostmarkRequest() throws {
        let from = try #require(EmailAddress(address: "bot@apexagent.com"))
        let to = try #require(EmailAddress(address: "lead@example.com"))
        let message = EmailMessage(
            from: from,
            recipients: EmailRecipientList(to: [to]),
            subject: "Incident Alert",
            textBody: "Subsystem CPU spike detected."
        )

        let req = TransactionalEmailAuditor.buildPostmarkRequest(
            serverToken: "postmark_token_abc_123",
            message: message
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.postmarkapp.com/email")
        #expect(request.value(forHTTPHeaderField: "X-Postmark-Server-Token") == "postmark_token_abc_123")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["From"] as? String == "bot@apexagent.com")
        #expect(bodyJson?["To"] as? String == "lead@example.com")
        #expect(bodyJson?["TextBody"] as? String == "Subsystem CPU spike detected.")
    }

    @Test("formatEmailAuditReportMarkdown renders markdown summary table")
    func testMarkdownFormatting() throws {
        let from = try #require(EmailAddress(address: "bot@apexagent.com"))
        let to = try #require(EmailAddress(address: "lead@example.com"))
        let message = EmailMessage(
            from: from,
            recipients: EmailRecipientList(to: [to]),
            subject: "Test Subject",
            textBody: "Hello world"
        )
        let report = TransactionalEmailAuditor.auditMessage(
            message: message,
            apiKey: "re_sampleToken123"
        )

        let md = TransactionalEmailAuditor.formatEmailAuditReportMarkdown(report)
        #expect(md.contains("Transactional Email Dispatch Audit"))
        #expect(md.contains("resend"))
        #expect(md.contains("✅ Compliant"))
        #expect(md.contains("100.0%"))
    }
}
