//
//  WebhookSignatureAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 106: Universal Multi-Vendor Webhook Signature Auditor Tests.
//

import Testing
import Foundation
import CryptoKit
@testable import ApexAgentCore

@Suite("Batch 106 — Universal Webhook Signature Auditor Tests")
struct WebhookSignatureAuditorTests {

    private let testSecret = "webhook_secret_key_prod_test_42"

    private func computeHMAC(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    @Test("GitHub signature verification passes with valid sha256= prefix and fails on tampered body")
    func testGitHubSignatureVerification() {
        let body = Data("{\"ref\":\"refs/heads/main\",\"commits\":[]}".utf8)
        let hex = computeHMAC(body: body, secret: testSecret)
        let sig = "sha256=" + hex

        let request = WebhookInboundRequest(
            url: URL(string: "https://agent.apex.internal/webhooks/github")!,
            headers: [
                "x-hub-signature-256": sig,
                "x-github-event": "push"
            ],
            rawBody: body
        )

        let report = WebhookSignatureAuditor.audit(request: request, secret: testSecret)
        #expect(report.detectedProvider == .gitHub)
        #expect(report.isCompliant)
        #expect(report.signatureValid)
        #expect(report.securityScore >= 0.95)

        // Tamper test
        let tampered = WebhookInboundRequest(
            url: URL(string: "https://agent.apex.internal/webhooks/github")!,
            headers: ["x-hub-signature-256": sig],
            rawBody: Data("{\"ref\":\"refs/heads/malicious\"}".utf8)
        )
        let tamperedReport = WebhookSignatureAuditor.audit(request: tampered, secret: testSecret)
        #expect(!tamperedReport.isCompliant)
        #expect(!tamperedReport.signatureValid)
    }

    @Test("Stripe webhook parses t= and v1= signature format and enforces timestamp window")
    func testStripeSignatureVerification() {
        let body = Data("{\"id\":\"evt_123\",\"object\":\"event\"}".utf8)
        let now = Date()
        let tsStr = String(Int(now.timeIntervalSince1970))
        let signedPayload = "\(tsStr).\(String(data: body, encoding: .utf8)!)"
        let hex = computeHMAC(body: Data(signedPayload.utf8), secret: testSecret)
        let stripeHeader = "t=\(tsStr),v1=\(hex)"

        let request = WebhookInboundRequest(
            url: URL(string: "https://agent.apex.internal/webhooks/stripe")!,
            headers: ["stripe-signature": stripeHeader],
            rawBody: body
        )

        let report = WebhookSignatureAuditor.audit(request: request, secret: testSecret, currentDate: now)
        #expect(report.detectedProvider == .stripe)
        #expect(report.isCompliant)
        #expect(report.signatureValid)
        #expect(report.replaySafe)
    }

    @Test("Shopify Base64 encoded HMAC signature verifies correctly")
    func testShopifySignatureVerification() {
        let body = Data("{\"id\":998877,\"email\":\"buyer@example.com\"}".utf8)
        let key = SymmetricKey(data: Data(testSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        let b64 = Data(mac).base64EncodedString()

        let request = WebhookInboundRequest(
            url: URL(string: "https://agent.apex.internal/webhooks/shopify")!,
            headers: ["x-shopify-hmac-sha256": b64],
            rawBody: body
        )

        let report = WebhookSignatureAuditor.audit(request: request, secret: testSecret)
        #expect(report.detectedProvider == .shopify)
        #expect(report.isCompliant)
        #expect(report.signatureValid)
    }

    @Test("Provider detection accurately identifies vendors by headers")
    func testProviderDetection() {
        #expect(WebhookSignatureAuditor.detectProvider(headers: ["X-GitHub-Event": "workflow_run"]) == .gitHub)
        #expect(WebhookSignatureAuditor.detectProvider(headers: ["X-Slack-Signature": "v0=123"]) == .slack)
        #expect(WebhookSignatureAuditor.detectProvider(headers: ["Linear-Event": "Issue"]) == .linear)
        #expect(WebhookSignatureAuditor.detectProvider(headers: ["Stripe-Signature": "t=1,v1=2"]) == .stripe)
        #expect(WebhookSignatureAuditor.detectProvider(headers: ["X-Shopify-Hmac-Sha256": "abc="]) == .shopify)
        #expect(WebhookSignatureAuditor.detectProvider(headers: ["Content-Type": "application/json"]) == .genericHMAC)
    }

    @Test("Payload size limit violation triggers fatal security violation")
    func testPayloadSizeLimitViolation() {
        let hugeBody = Data(repeating: 0x41, count: 200_000)
        let request = WebhookInboundRequest(
            url: URL(string: "https://agent.apex.internal/webhooks/generic")!,
            headers: ["x-webhook-signature": "dummy"],
            rawBody: hugeBody
        )
        let policy = WebhookSecurityPolicy(maxBodySizeBytes: 100_000)

        let report = WebhookSignatureAuditor.audit(request: request, secret: testSecret, policy: policy)
        #expect(!report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "PAYLOAD_TOO_LARGE" && $0.isFatal }))
    }

    @Test("Insecure HTTP transport triggers fatal violation on non-localhost")
    func testInsecureTransportViolation() {
        let body = Data("{}".utf8)
        let hex = computeHMAC(body: body, secret: testSecret)
        let request = WebhookInboundRequest(
            url: URL(string: "http://api.remote.example.com/webhooks")!,
            headers: ["x-webhook-signature": hex],
            rawBody: body
        )

        let report = WebhookSignatureAuditor.audit(request: request, secret: testSecret)
        #expect(!report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "INSECURE_WEBHOOK_TRANSPORT" && $0.isFatal }))
    }

    @Test("formatWebhookAuditReportMarkdown renders markdown summary table")
    func testMarkdownFormatting() {
        let report = WebhookAuditReport(
            detectedProvider: .gitHub,
            isCompliant: true,
            signatureValid: true,
            replaySafe: true,
            securityScore: 1.0,
            violations: []
        )
        let md = WebhookSignatureAuditor.formatWebhookAuditReportMarkdown(report)
        #expect(md.contains("### 🔏 Webhook Signature & Authenticity Audit"))
        #expect(md.contains("GitHub"))
        #expect(md.contains("100%"))
        #expect(md.contains("✅ Cryptographically Verified"))
    }
}
