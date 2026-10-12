//
//  WebhookSignatureAuditor.swift
//  ApexAgent
//
//  Created for Batch 106: Universal Multi-Vendor Webhook Signature Auditor & Dispatch Gate.
//

import Foundation
import CryptoKit

// MARK: - Supported Webhook Providers

public enum WebhookProvider: String, Sendable, Codable, CaseIterable {
    case gitHub = "GitHub"
    case slack = "Slack"
    case linear = "Linear"
    case stripe = "Stripe"
    case shopify = "Shopify"
    case genericHMAC = "GenericHMAC"

    public var signatureHeaderName: String {
        switch self {
        case .gitHub: return "x-hub-signature-256"
        case .slack: return "x-slack-signature"
        case .linear: return "linear-signature"
        case .stripe: return "stripe-signature"
        case .shopify: return "x-shopify-hmac-sha256"
        case .genericHMAC: return "x-webhook-signature"
        }
    }
}

// MARK: - Webhook Inbound Request

public struct WebhookInboundRequest: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let rawBody: Data
    public let timestamp: Date

    public init(
        url: URL,
        headers: [String: String],
        rawBody: Data,
        timestamp: Date = Date()
    ) {
        self.url = url
        self.headers = headers
        self.rawBody = rawBody
        self.timestamp = timestamp
    }

    public func headerValue(for name: String) -> String? {
        let lowerTarget = name.lowercased()
        for (k, v) in headers {
            if k.lowercased() == lowerTarget {
                return v
            }
        }
        return nil
    }
}

// MARK: - Webhook Security Policy

public struct WebhookSecurityPolicy: Sendable, Codable, Equatable {
    public var maxReplayToleranceSeconds: TimeInterval
    public var maxBodySizeBytes: Int
    public var enforceHTTPS: Bool
    public var allowLocalhost: Bool

    public init(
        maxReplayToleranceSeconds: TimeInterval = 300.0,
        maxBodySizeBytes: Int = 1_000_000,
        enforceHTTPS: Bool = true,
        allowLocalhost: Bool = true
    ) {
        self.maxReplayToleranceSeconds = maxReplayToleranceSeconds
        self.maxBodySizeBytes = maxBodySizeBytes
        self.enforceHTTPS = enforceHTTPS
        self.allowLocalhost = allowLocalhost
    }
}

// MARK: - Audit Violation & Report

public struct WebhookSecurityViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct WebhookAuditReport: Sendable, Codable, Equatable {
    public let detectedProvider: WebhookProvider
    public let isCompliant: Bool
    public let signatureValid: Bool
    public let replaySafe: Bool
    public let securityScore: Double
    public let violations: [WebhookSecurityViolation]
}

// MARK: - Webhook Signature Auditor

public struct WebhookSignatureAuditor: Sendable {

    /// Automatically detects provider based on inbound HTTP request headers.
    public static func detectProvider(headers: [String: String]) -> WebhookProvider {
        let lower = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }

        if lower["x-hub-signature-256"] != nil || lower["x-github-event"] != nil {
            return .gitHub
        }
        if lower["x-slack-signature"] != nil {
            return .slack
        }
        if lower["linear-signature"] != nil || lower["linear-event"] != nil {
            return .linear
        }
        if lower["stripe-signature"] != nil {
            return .stripe
        }
        if lower["x-shopify-hmac-sha256"] != nil {
            return .shopify
        }
        return .genericHMAC
    }

    /// Verifies constant-time equality of two Data buffers.
    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff = 0
        for i in 0..<a.count {
            diff |= Int(a[i] ^ b[i])
        }
        return diff == 0
    }

    /// Verifies the cryptographic HMAC signature across supported vendors.
    public static func verifySignature(
        request: WebhookInboundRequest,
        provider: WebhookProvider,
        secret: String,
        currentDate: Date = Date(),
        replayTolerance: TimeInterval = 300.0
    ) -> (valid: Bool, replaySafe: Bool, reason: String?) {
        guard !secret.isEmpty else {
            return (false, false, "Signing secret is empty")
        }
        let secretData = Data(secret.utf8)
        let key = SymmetricKey(data: secretData)

        switch provider {
        case .gitHub:
            guard let sigHeader = request.headerValue(for: "x-hub-signature-256") else {
                return (false, true, "Missing x-hub-signature-256 header")
            }
            guard sigHeader.hasPrefix("sha256=") else {
                return (false, true, "GitHub signature must start with 'sha256='")
            }
            let providedHex = String(sigHeader.dropFirst(7)).lowercased()
            let mac = HMAC<SHA256>.authenticationCode(for: request.rawBody, using: key)
            let computedHex = mac.map { String(format: "%02x", $0) }.joined().lowercased()

            let valid = constantTimeEquals(Data(providedHex.utf8), Data(computedHex.utf8))
            return (valid, true, valid ? nil : "GitHub HMAC-SHA256 mismatch")

        case .slack:
            guard let sigHeader = request.headerValue(for: "x-slack-signature"),
                  let tsHeader = request.headerValue(for: "x-slack-request-timestamp"),
                  let ts = Double(tsHeader) else {
                return (false, false, "Missing x-slack-signature or timestamp header")
            }
            let age = abs(currentDate.timeIntervalSince1970 - ts)
            guard age <= replayTolerance else {
                return (false, false, "Slack timestamp age (\(Int(age))s) exceeds replay limit")
            }
            guard let bodyStr = String(data: request.rawBody, encoding: .utf8) else {
                return (false, true, "Body is not UTF-8 decodable")
            }
            let basestring = "v0:\(tsHeader):\(bodyStr)"
            let mac = HMAC<SHA256>.authenticationCode(for: Data(basestring.utf8), using: key)
            let computedHex = "v0=" + mac.map { String(format: "%02x", $0) }.joined()
            let valid = constantTimeEquals(Data(sigHeader.utf8), Data(computedHex.utf8))
            return (valid, true, valid ? nil : "Slack HMAC mismatch")

        case .linear:
            guard let sigHeader = request.headerValue(for: "linear-signature") else {
                return (false, true, "Missing linear-signature header")
            }
            let mac = HMAC<SHA256>.authenticationCode(for: request.rawBody, using: key)
            let computedHex = mac.map { String(format: "%02x", $0) }.joined().lowercased()
            let providedHex = sigHeader.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valid = constantTimeEquals(Data(providedHex.utf8), Data(computedHex.utf8))
            return (valid, true, valid ? nil : "Linear HMAC mismatch")

        case .stripe:
            guard let sigHeader = request.headerValue(for: "stripe-signature") else {
                return (false, false, "Missing stripe-signature header")
            }
            // Parse t=timestamp,v1=signature
            var timestampStr: String?
            var signatures: [String] = []
            let items = sigHeader.split(separator: ",")
            for item in items {
                let parts = item.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let k = parts[0].trimmingCharacters(in: .whitespaces)
                    let v = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    if k == "t" { timestampStr = v }
                    if k == "v1" { signatures.append(v) }
                }
            }
            guard let tsStr = timestampStr, let ts = Double(tsStr) else {
                return (false, false, "Stripe signature missing valid timestamp component")
            }
            let age = abs(currentDate.timeIntervalSince1970 - ts)
            guard age <= replayTolerance else {
                return (false, false, "Stripe timestamp age (\(Int(age))s) exceeds replay limit")
            }
            guard let bodyStr = String(data: request.rawBody, encoding: .utf8) else {
                return (false, true, "Body is not UTF-8 decodable")
            }
            let signedPayload = "\(tsStr).\(bodyStr)"
            let mac = HMAC<SHA256>.authenticationCode(for: Data(signedPayload.utf8), using: key)
            let computedHex = mac.map { String(format: "%02x", $0) }.joined().lowercased()

            let matchFound = signatures.contains { sig in
                constantTimeEquals(Data(sig.lowercased().utf8), Data(computedHex.utf8))
            }
            return (matchFound, true, matchFound ? nil : "Stripe HMAC signature mismatch")

        case .shopify:
            guard let sigHeader = request.headerValue(for: "x-shopify-hmac-sha256") else {
                return (false, true, "Missing x-shopify-hmac-sha256 header")
            }
            let mac = HMAC<SHA256>.authenticationCode(for: request.rawBody, using: key)
            let computedBase64 = Data(mac).base64EncodedString()
            let valid = constantTimeEquals(Data(sigHeader.utf8), Data(computedBase64.utf8))
            return (valid, true, valid ? nil : "Shopify Base64 HMAC mismatch")

        case .genericHMAC:
            guard let sigHeader = request.headerValue(for: "x-webhook-signature") ?? request.headerValue(for: "x-signature") else {
                return (false, true, "Missing generic webhook signature header")
            }
            let mac = HMAC<SHA256>.authenticationCode(for: request.rawBody, using: key)
            let computedHex = mac.map { String(format: "%02x", $0) }.joined().lowercased()
            let providedHex = sigHeader.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valid = constantTimeEquals(Data(providedHex.utf8), Data(computedHex.utf8))
            return (valid, true, valid ? nil : "Generic HMAC mismatch")
        }
    }

    /// Evaluates full security compliance of an inbound webhook.
    public static func audit(
        request: WebhookInboundRequest,
        secret: String,
        policy: WebhookSecurityPolicy = WebhookSecurityPolicy(),
        currentDate: Date = Date()
    ) -> WebhookAuditReport {
        var violations: [WebhookSecurityViolation] = []
        let provider = detectProvider(headers: request.headers)

        // 1. Transport Security Check
        let isLocal = (request.url.host == "localhost" || request.url.host == "127.0.0.1")
        if request.url.scheme?.lowercased() != "https" {
            if isLocal && policy.allowLocalhost {
                violations.append(WebhookSecurityViolation(
                    code: "LOCAL_HTTP_ALLOWED",
                    message: "Plaintext HTTP permitted for local webhook receiver.",
                    isFatal: false
                ))
            } else {
                violations.append(WebhookSecurityViolation(
                    code: "INSECURE_WEBHOOK_TRANSPORT",
                    message: "Inbound webhook must be received over HTTPS to prevent eavesdropping.",
                    isFatal: true
                ))
            }
        }

        // 2. Payload Size Check
        if request.rawBody.count > policy.maxBodySizeBytes {
            violations.append(WebhookSecurityViolation(
                code: "PAYLOAD_TOO_LARGE",
                message: "Payload size (\(request.rawBody.count) bytes) exceeds maximum allowable limit (\(policy.maxBodySizeBytes) bytes).",
                isFatal: true
            ))
        }

        // 3. Cryptographic Signature Verification
        let (valid, replaySafe, reason) = verifySignature(
            request: request,
            provider: provider,
            secret: secret,
            currentDate: currentDate,
            replayTolerance: policy.maxReplayToleranceSeconds
        )

        if !valid {
            violations.append(WebhookSecurityViolation(
                code: "SIGNATURE_INVALID",
                message: reason ?? "Signature verification failed",
                isFatal: true
            ))
        }

        if !replaySafe {
            violations.append(WebhookSecurityViolation(
                code: "TIMESTAMP_REPLAY_DETECTED",
                message: reason ?? "Timestamp outside acceptable replay window",
                isFatal: true
            ))
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let warnCount = violations.filter { !$0.isFatal }.count
        let rawScore = 1.0 - (Double(fatalCount) * 0.45) - (Double(warnCount) * 0.1)
        let score = max(0.0, min(1.0, rawScore))
        let compliant = fatalCount == 0

        return WebhookAuditReport(
            detectedProvider: provider,
            isCompliant: compliant,
            signatureValid: valid,
            replaySafe: replaySafe,
            securityScore: score,
            violations: violations
        )
    }

    public static func formatWebhookAuditReportMarkdown(_ report: WebhookAuditReport) -> String {
        var md = "### 🔏 Webhook Signature & Authenticity Audit\n\n"
        md += "| Parameter | Value | Status |\n"
        md += "|---|---|---|\n"
        md += "| Provider | `\(report.detectedProvider.rawValue)` | 🏷️ Detected Vendor |\n"
        md += "| Compliance | \(report.isCompliant ? "✅ Compliant" : "❌ Non-Compliant") | Security Perimeter |\n"
        md += "| Signature Valid | \(report.signatureValid ? "✅ Cryptographically Verified" : "🔴 Signature Mismatch") | HMAC-SHA256 |\n"
        md += "| Replay Safe | \(report.replaySafe ? "✅ Fresh Window" : "⚠️ Replay Risk") | Anti-Replay Guard |\n"
        md += "| Security Score | `\(Int(report.securityScore * 100))%` | \(report.securityScore >= 0.8 ? "🛡️ Solid" : "⚠️ Review Required") |\n\n"

        if !report.violations.isEmpty {
            md += "#### Findings\n"
            for v in report.violations {
                let badge = v.isFatal ? "🔴 **[FATAL]**" : "🟡 **[WARN]**"
                md += "- \(badge) `\(v.code)`: \(v.message)\n"
            }
        }
        return md
    }
}
