//
//  DiscordIntegrationAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 114: Discord Bot, Rich Embed Builder & Ed25519 Interaction Signature Auditor Tests.
//

import Testing
import Foundation
import CryptoKit
@testable import ApexAgentCore

@Suite("Batch 114 — Discord Webhook, Embed Builder & Ed25519 Verification Tests")
struct DiscordIntegrationAuditorTests {

    @Test("Valid Discord webhook URL and 32-byte Ed25519 public key pass audit with 100% score")
    func testValidAuditConfiguration() {
        let validHexKey = String(repeating: "ab", count: 32) // 64 hex chars = 32 bytes
        let url = URL(string: "https://discord.com/api/webhooks/123456789/token_secret_here")!

        let report = DiscordIntegrationAuditor.auditConfiguration(
            webhookURL: url,
            publicKeyHex: validHexKey
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.ed25519KeyConfigured)
        #expect(report.webhookURLSanitized?.contains("**REDACTED**") == true)
        #expect(report.violations.isEmpty)
    }

    @Test("Insecure HTTP and invalid Ed25519 key length trip fatal violations")
    func testInsecureAndInvalidKeyTripViolations() {
        let report = DiscordIntegrationAuditor.auditConfiguration(
            webhookURL: URL(string: "http://discord.com/api/webhooks/123/token")!,
            publicKeyHex: "short_key_not_32_bytes"
        )

        #expect(!report.passed)
        #expect(report.violations.contains(where: { $0.code == "INSECURE_DISCORD_HTTP_ENDPOINT" }))
        #expect(report.violations.contains(where: { $0.code == "INVALID_ED25519_KEY_LENGTH" }))
    }

    @Test("Ed25519 signature verification passes with real CryptoKit private key signature and rejects tampered bodies")
    func testRealEd25519SignatureVerification() throws {
        // 1. Generate real ephemeral Curve25519 key pair
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let pubKeyHex = publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()

        // 2. Prepare timestamp and body
        let timestamp = "1728734400"
        let bodyString = "{\"type\":1}"
        let bodyData = Data(bodyString.utf8)

        // 3. Sign timestamp + body
        var messageData = Data(timestamp.utf8)
        messageData.append(bodyData)
        let signature = try privateKey.signature(for: messageData)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

        // 4. Verify valid signature passes
        let isValid = DiscordIntegrationAuditor.verifyEd25519Signature(
            publicKeyHex: pubKeyHex,
            signatureHex: signatureHex,
            timestamp: timestamp,
            body: bodyData
        )
        #expect(isValid)

        // 5. Verify tampered body is rejected
        let tamperedBody = Data("{\"type\":2,\"data\":{\"name\":\"hacked\"}}".utf8)
        let isTamperedValid = DiscordIntegrationAuditor.verifyEd25519Signature(
            publicKeyHex: pubKeyHex,
            signatureHex: signatureHex,
            timestamp: timestamp,
            body: tamperedBody
        )
        #expect(!isTamperedValid)

        // 6. Verify tampered timestamp is rejected
        let isStaleValid = DiscordIntegrationAuditor.verifyEd25519Signature(
            publicKeyHex: pubKeyHex,
            signatureHex: signatureHex,
            timestamp: "1728739999",
            body: bodyData
        )
        #expect(!isStaleValid)
    }

    @Test("buildExecuteWebhookRequest formats payload with rich embeds and fields")
    func testBuildExecuteWebhookRequest() throws {
        let field1 = DiscordEmbedField(name: "Loop", value: "14", inline: true)
        let field2 = DiscordEmbedField(name: "Audit Status", value: "PASS", inline: true)
        let embed = DiscordEmbed(
            title: "ApexAgent Deployment Status",
            description: "All autonomous gates passed cleanly.",
            color: 0x5865F2,
            fields: [field1, field2],
            footer: DiscordEmbedFooter(text: "ApexAgent v1.0")
        )
        let payload = DiscordWebhookPayload(
            content: "🚀 Production Release Automated Notification",
            username: "ApexAgent CI",
            embeds: [embed]
        )

        let targetURL = URL(string: "https://discord.com/api/webhooks/999/tok")!
        let req = DiscordIntegrationAuditor.buildExecuteWebhookRequest(
            webhookURL: targetURL,
            payload: payload
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["content"] as? String == "🚀 Production Release Automated Notification")
        #expect(bodyJson?["username"] as? String == "ApexAgent CI")

        let embeds = bodyJson?["embeds"] as? [[String: Any]]
        #expect(embeds?.count == 1)
        #expect(embeds?[0]["title"] as? String == "ApexAgent Deployment Status")
        #expect(embeds?[0]["color"] as? Int == 0x5865F2)

        let fields = embeds?[0]["fields"] as? [[String: Any]]
        #expect(fields?.count == 2)
        #expect(fields?[0]["name"] as? String == "Loop")
        #expect(fields?[0]["value"] as? String == "14")
    }

    @Test("formatDiscordAuditReportMarkdown renders markdown summary table")
    func testMarkdownFormatting() {
        let url = URL(string: "https://discord.com/api/webhooks/123/tok")!
        let report = DiscordIntegrationAuditor.auditConfiguration(
            webhookURL: url,
            publicKeyHex: String(repeating: "42", count: 32)
        )

        let md = DiscordIntegrationAuditor.formatDiscordAuditReportMarkdown(report)
        #expect(md.contains("Discord Webhook & Ed25519 Interaction Audit"))
        #expect(md.contains("✅ Compliant"))
        #expect(md.contains("100.0%"))
    }
}
