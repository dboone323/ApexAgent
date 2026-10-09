import Foundation
import Testing
import CryptoKit
@testable import ApexAgentCore

@Suite("Batch 71 — Discord Gateway & Webhook Security Auditor Tests")
struct DiscordWebhookSecurityAuditorTests {

    @Test("Valid Ed25519 inbound webhook request passes with 100% score")
    func validEd25519RequestPasses() throws {
        // Generate real Curve25519 private/public keypair
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()

        let now = Date()
        let timestamp = String(Int(now.timeIntervalSince1970))
        let bodyString = "{\"type\": 1}"
        let bodyData = bodyString.data(using: .utf8)!

        var signedPayload = timestamp.data(using: .utf8)!
        signedPayload.append(bodyData)
        let signature = try privateKey.signature(for: signedPayload)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

        let request = DiscordInboundWebhookRequest(
            timestampHeader: timestamp,
            signatureHeader: signatureHex,
            rawBody: bodyData
        )
        let config = DiscordSecurityConfig(
            maxReplayToleranceSeconds: 300,
            ed25519PublicKeyHex: publicKeyHex
        )

        let report = DiscordWebhookSecurityAuditor.auditInboundRequest(request, config: config, now: now)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.signatureValid)
        #expect(report.replaySafe)
        #expect(report.payloadValid)
        #expect(report.violations.isEmpty)
    }

    @Test("Tampered signature or body triggers INVALID_ED25519_SIGNATURE violation")
    func tamperedSignatureFails() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()

        let now = Date()
        let timestamp = String(Int(now.timeIntervalSince1970))
        let bodyData = "{\"type\": 1}".data(using: .utf8)!

        var signedPayload = timestamp.data(using: .utf8)!
        signedPayload.append(bodyData)
        let signature = try privateKey.signature(for: signedPayload)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

        // Tamper with body data
        let tamperedBody = "{\"type\": 2, \"malicious\": true}".data(using: .utf8)!

        let request = DiscordInboundWebhookRequest(
            timestampHeader: timestamp,
            signatureHeader: signatureHex,
            rawBody: tamperedBody
        )
        let config = DiscordSecurityConfig(ed25519PublicKeyHex: publicKeyHex)

        let report = DiscordWebhookSecurityAuditor.auditInboundRequest(request, config: config, now: now)
        #expect(!report.passed)
        #expect(!report.signatureValid)
        #expect(report.violations.contains { $0.code == "INVALID_ED25519_SIGNATURE" })
    }

    @Test("Outdated timestamp triggers REPLAY_TOLERANCE_EXCEEDED violation")
    func outdatedTimestampTriggersReplayViolation() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()

        let now = Date()
        // 400 seconds in the past, exceeding 300s tolerance
        let oldTimestamp = String(Int(now.timeIntervalSince1970 - 400))
        let bodyData = "{}".data(using: .utf8)!

        var signedPayload = oldTimestamp.data(using: .utf8)!
        signedPayload.append(bodyData)
        let signature = try privateKey.signature(for: signedPayload)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

        let request = DiscordInboundWebhookRequest(
            timestampHeader: oldTimestamp,
            signatureHeader: signatureHex,
            rawBody: bodyData
        )
        let config = DiscordSecurityConfig(
            maxReplayToleranceSeconds: 300,
            ed25519PublicKeyHex: publicKeyHex
        )

        let report = DiscordWebhookSecurityAuditor.auditInboundRequest(request, config: config, now: now)
        #expect(!report.passed)
        #expect(!report.replaySafe)
        #expect(report.violations.contains { $0.code == "REPLAY_TOLERANCE_EXCEEDED" })
    }

    @Test("Outbound payload sanitizer neutralizes mass mentions and role mentions")
    func outboundSanitizerNeutralizesMentions() {
        let input = "Hello @everyone and @here! Alerting team <@&9876543210> about build completion."
        let result = DiscordWebhookSecurityAuditor.sanitizeOutboundPayload(content: input)

        #expect(result.neutralizedMentionsCount == 3)
        #expect(!result.sanitizedContent.contains("@everyone"))
        #expect(!result.sanitizedContent.contains("@here"))
        #expect(!result.sanitizedContent.contains("<@&9876543210>"))
        #expect(result.sanitizedContent.contains("@\u{200B}everyone"))
        #expect(result.sanitizedContent.contains("[role-mention-redacted]"))
        #expect(!result.wasTruncated)
        #expect(result.isAcceptable)
    }

    @Test("Outbound payload sanitizer truncates content exceeding length limit")
    func outboundSanitizerTruncatesExceedingContent() {
        let longMessage = String(repeating: "A", count: 2500)
        let config = DiscordSecurityConfig(maxContentLength: 2000)
        let result = DiscordWebhookSecurityAuditor.sanitizeOutboundPayload(content: longMessage, config: config)

        #expect(result.wasTruncated)
        #expect(result.sanitizedContent.count == 2000)
        #expect(result.isAcceptable)
    }

    @Test("Discord rate limit header parser calculates throttling and backoff")
    func evaluateRateLimitsParsesThrottlingHeaders() {
        let headers = [
            "X-RateLimit-Limit": "5",
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset-After": "2.5",
            "Retry-After": "3.0"
        ]
        let status = DiscordWebhookSecurityAuditor.evaluateRateLimits(headers: headers)

        #expect(status.isThrottled)
        #expect(status.limit == 5)
        #expect(status.remaining == 0)
        #expect(status.recommendedWaitSeconds == 3.0)
    }
}
