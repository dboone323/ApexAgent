//
//  SlackIntegrationAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 103: Slack Integration Auditor & Block Kit Builder Tests.
//

import Testing
import Foundation
import CryptoKit
@testable import ApexAgentCore

@Suite("Batch 103 — Slack Integration & Block Kit Auditor Tests")
struct SlackIntegrationAuditorTests {

    private let testSecret = "8f3b2c1a4e5d6f7a8b9c0d1e2f3a4b5c"

    private func generateValidSignature(body: String, timestamp: String, secret: String) -> String {
        let basestring = "v0:\(timestamp):\(body)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(basestring.utf8), using: key)
        return "v0=" + mac.map { String(format: "%02x", $0) }.joined()
    }

    @Test("Valid signature and fresh timestamp pass Slack verification")
    func testValidSlackSignaturePasses() {
        let body = "{\"type\":\"block_actions\",\"action_id\":\"approve_action\"}"
        let now = Date()
        let timestamp = String(Int(now.timeIntervalSince1970))
        let sig = generateValidSignature(body: body, timestamp: timestamp, secret: testSecret)

        let config = SlackSecurityConfig(
            maxReplayToleranceSeconds: 300,
            signingSecret: testSecret
        )

        let report = SlackIntegrationAuditor.auditInboundRequest(
            signatureHeader: sig,
            timestampHeader: timestamp,
            rawBody: Data(body.utf8),
            config: config,
            currentDate: now
        )

        #expect(report.isCompliant)
        #expect(report.signatureVerified)
        #expect(report.replaySafe)
        #expect(report.securityScore >= 0.95)
        #expect(report.violations.isEmpty)
    }

    @Test("Stale timestamp exceeding replay threshold fails verification")
    func testStaleTimestampTripsReplay() {
        let body = "{\"type\":\"block_actions\"}"
        let past = Date().addingTimeInterval(-600) // 10 minutes ago
        let timestamp = String(Int(past.timeIntervalSince1970))
        let sig = generateValidSignature(body: body, timestamp: timestamp, secret: testSecret)

        let config = SlackSecurityConfig(
            maxReplayToleranceSeconds: 300,
            signingSecret: testSecret
        )

        let report = SlackIntegrationAuditor.auditInboundRequest(
            signatureHeader: sig,
            timestampHeader: timestamp,
            rawBody: Data(body.utf8),
            config: config,
            currentDate: Date()
        )

        #expect(!report.isCompliant)
        #expect(!report.signatureVerified)
        #expect(!report.replaySafe)
        #expect(report.violations.contains(where: { $0.code == "SIGNATURE_VERIFICATION_FAILED" }))
    }

    @Test("Tampered body payload fails HMAC signature verification")
    func testTamperedPayloadFails() {
        let originalBody = "{\"action\":\"approve\"}"
        let tamperedBody = "{\"action\":\"deny\"}"
        let now = Date()
        let timestamp = String(Int(now.timeIntervalSince1970))
        let sig = generateValidSignature(body: originalBody, timestamp: timestamp, secret: testSecret)

        let config = SlackSecurityConfig(
            maxReplayToleranceSeconds: 300,
            signingSecret: testSecret
        )

        let report = SlackIntegrationAuditor.auditInboundRequest(
            signatureHeader: sig,
            timestampHeader: timestamp,
            rawBody: Data(tamperedBody.utf8),
            config: config,
            currentDate: now
        )

        #expect(!report.isCompliant)
        #expect(!report.signatureVerified)
    }

    @Test("Approval card Block Kit contains expected interactive buttons and sanitization")
    func testApprovalCardBlockKit() {
        let payload = SlackMessageBuilder.buildApprovalCard(
            taskTitle: "Deploy <!channel> release v2.0",
            description: "Deploy new cloud microservices <!everyone>",
            requestedBy: "ops-lead",
            approvalId: "appr_12345"
        )

        #expect(!payload.text.contains("<!channel>"))
        #expect(payload.text.contains("[channel]"))

        let dict = payload.toDict()
        guard let blocks = dict["blocks"] as? [[String: Any]] else {
            Issue.record("Expected blocks array")
            return
        }

        #expect(blocks.count == 5)
        #expect(blocks.first?["type"] as? String == "header")

        // Find actions block
        let actions = blocks.first(where: { ($0["type"] as? String) == "actions" })
        #expect(actions != nil)
        let elements = actions?["elements"] as? [[String: Any]]
        #expect(elements?.count == 2)
        #expect(elements?.first?["value"] as? String == "appr_12345")
        #expect(elements?.first?["style"] as? String == "primary")
        #expect(elements?.last?["style"] as? String == "danger")

        let jsonData = payload.toJSONData()
        #expect(jsonData != nil)
        #expect((jsonData?.count ?? 0) > 100)
    }

    @Test("Incident alert builds structured blocks with custom metadata")
    func testIncidentAlertPayload() {
        let alert = SlackMessageBuilder.buildIncidentAlert(
            level: "critical",
            summary: "Unauthorized API gateway probe detected",
            agentId: "agent-007",
            details: ["IP": "192.168.1.100", "Attempt": "3"]
        )

        let dict = alert.toDict()
        #expect(alert.text.contains("CRITICAL"))
        guard let blocks = dict["blocks"] as? [[String: Any]] else {
            Issue.record("Expected blocks")
            return
        }
        let section = blocks.first(where: { ($0["type"] as? String) == "section" })
        let textObj = section?["text"] as? [String: Any]
        let mrkdwn = textObj?["text"] as? String ?? ""
        #expect(mrkdwn.contains("192.168.1.100"))
        #expect(mrkdwn.contains("agent-007"))
    }

    @Test("Slack webhook URL auditor detects insecure schemes and suspicious hosts")
    func testWebhookURLAuditor() {
        let validURL = URL(string: "https://hooks.slack.com/services/T00/B00/XXXXX")!
        #expect(SlackIntegrationAuditor.auditWebhookURL(validURL).isEmpty)

        let httpURL = URL(string: "http://hooks.slack.com/services/T00/B00/XXXXX")!
        let httpViolations = SlackIntegrationAuditor.auditWebhookURL(httpURL)
        #expect(httpViolations.contains(where: { $0.code == "INSECURE_SLACK_SCHEME" && $0.isFatal }))

        let nonSlackURL = URL(string: "https://evil.example.com/services/T00")!
        let hostViolations = SlackIntegrationAuditor.auditWebhookURL(nonSlackURL)
        #expect(hostViolations.contains(where: { $0.code == "SUSPICIOUS_WEBHOOK_HOST" }))
    }

    @Test("formatSlackAuditReportMarkdown generates valid markdown report")
    func testMarkdownFormatting() {
        let report = SlackAuditReport(
            isCompliant: true,
            securityScore: 1.0,
            signatureVerified: true,
            replaySafe: true,
            violations: []
        )
        let md = SlackIntegrationAuditor.formatSlackAuditReportMarkdown(report)
        #expect(md.contains("### 💬 Slack Integration & Signature Security Audit"))
        #expect(md.contains("100%"))
        #expect(md.contains("✅ Verified (v0)"))
    }
}
