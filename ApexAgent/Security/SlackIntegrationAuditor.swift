//
//  SlackIntegrationAuditor.swift
//  ApexAgent
//
//  Created for Batch 103: Slack Integration Auditor & Block Kit Builder.
//

import Foundation
import CryptoKit

// MARK: - Slack Security Configuration

public struct SlackSecurityConfig: Sendable, Codable, Equatable {
    public var maxReplayToleranceSeconds: TimeInterval
    public var signingSecret: String?
    public var enforceHTTPS: Bool
    public var neutralizeMassBroadcast: Bool
    public var maxTextLength: Int

    public init(
        maxReplayToleranceSeconds: TimeInterval = 300.0,
        signingSecret: String? = nil,
        enforceHTTPS: Bool = true,
        neutralizeMassBroadcast: Bool = true,
        maxTextLength: Int = 3000
    ) {
        self.maxReplayToleranceSeconds = maxReplayToleranceSeconds
        self.signingSecret = signingSecret
        self.enforceHTTPS = enforceHTTPS
        self.neutralizeMassBroadcast = neutralizeMassBroadcast
        self.maxTextLength = maxTextLength
    }
}

// MARK: - Slack Block Kit Models

public enum SlackButtonStyle: String, Sendable, Codable, Equatable {
    case primary
    case danger
    case `default`
}

public struct SlackButton: Sendable, Codable, Equatable {
    public let text: String
    public let actionId: String
    public let value: String
    public let style: SlackButtonStyle

    public init(text: String, actionId: String, value: String, style: SlackButtonStyle = .default) {
        self.text = text
        self.actionId = actionId
        self.value = value
        self.style = style
    }

    public func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "type": "button",
            "text": ["type": "plain_text", "text": text, "emoji": true],
            "action_id": actionId,
            "value": value
        ]
        if style != .default {
            dict["style"] = style.rawValue
        }
        return dict
    }
}

public enum SlackBlock: Sendable, Equatable {
    case header(text: String)
    case section(markdown: String)
    case divider
    case context(elements: [String])
    case actions(buttons: [SlackButton])

    public func toDict() -> [String: Any] {
        switch self {
        case .header(let text):
            return [
                "type": "header",
                "text": ["type": "plain_text", "text": text, "emoji": true]
            ]
        case .section(let markdown):
            return [
                "type": "section",
                "text": ["type": "mrkdwn", "text": markdown]
            ]
        case .divider:
            return ["type": "divider"]
        case .context(let elements):
            let elementDicts = elements.map { ["type": "mrkdwn", "text": $0] }
            return [
                "type": "context",
                "elements": elementDicts
            ]
        case .actions(let buttons):
            return [
                "type": "actions",
                "elements": buttons.map { $0.toDict() }
            ]
        }
    }
}

public struct SlackWebhookPayload: Sendable, Equatable {
    public let text: String
    public let blocks: [SlackBlock]

    public init(text: String, blocks: [SlackBlock] = []) {
        self.text = text
        self.blocks = blocks
    }

    public func toDict() -> [String: Any] {
        var dict: [String: Any] = ["text": text]
        if !blocks.isEmpty {
            dict["blocks"] = blocks.map { $0.toDict() }
        }
        return dict
    }

    public func toJSONData() -> Data? {
        try? JSONSerialization.data(withJSONObject: toDict(), options: [.prettyPrinted, .sortedKeys])
    }
}

// MARK: - Slack Message Builder

public struct SlackMessageBuilder: Sendable {
    public static func sanitizeText(_ text: String, neutralizeMassBroadcast: Bool = true) -> String {
        guard neutralizeMassBroadcast else { return text }
        return text
            .replacingOccurrences(of: "<!channel>", with: "[channel]")
            .replacingOccurrences(of: "<!here>", with: "[here]")
            .replacingOccurrences(of: "<!everyone>", with: "[everyone]")
    }

    public static func buildApprovalCard(
        taskTitle: String,
        description: String,
        requestedBy: String,
        approvalId: String
    ) -> SlackWebhookPayload {
        let safeTitle = sanitizeText(taskTitle)
        let safeDesc = sanitizeText(description)
        let safeUser = sanitizeText(requestedBy)

        let blocks: [SlackBlock] = [
            .header(text: "🔒 Agent Action Approval Required"),
            .section(markdown: "*Task:* `\(safeTitle)`\n*Requested by:* `\(safeUser)`\n*Details:* \(safeDesc)"),
            .divider,
            .actions(buttons: [
                SlackButton(text: "Approve", actionId: "approve_action", value: approvalId, style: .primary),
                SlackButton(text: "Deny", actionId: "deny_action", value: approvalId, style: .danger)
            ]),
            .context(elements: ["Approval ID: `\(approvalId)` • ApexAgent Security Gate"])
        ]

        return SlackWebhookPayload(text: "Action Approval Required: \(safeTitle)", blocks: blocks)
    }

    public static func buildIncidentAlert(
        level: String,
        summary: String,
        agentId: String,
        details: [String: String] = [:]
    ) -> SlackWebhookPayload {
        var lines: [String] = [
            "*Severity:* `\(level.uppercased())`",
            "*Agent:* `\(agentId)`",
            "*Summary:* \(sanitizeText(summary))"
        ]
        for (k, v) in details.sorted(by: { $0.key < $1.key }) {
            lines.append("*\(k):* \(sanitizeText(v))")
        }

        let blocks: [SlackBlock] = [
            .header(text: "🚨 Security Incident Alert"),
            .section(markdown: lines.joined(separator: "\n")),
            .divider,
            .context(elements: ["Generated at \(ISO8601DateFormatter().string(from: Date())) • ApexAgent SecOps"])
        ]

        return SlackWebhookPayload(text: "🚨 Incident Alert [\(level.uppercased())]: \(summary)", blocks: blocks)
    }

    public static func buildStatusUpdate(
        agentName: String,
        state: String,
        metricsSummary: String
    ) -> SlackWebhookPayload {
        let blocks: [SlackBlock] = [
            .header(text: "🤖 Agent Status: \(agentName)"),
            .section(markdown: "*State:* `\(state)`\n*Metrics:* \(sanitizeText(metricsSummary))"),
            .context(elements: ["ApexAgent Telemetry Node"])
        ]
        return SlackWebhookPayload(text: "Status update for \(agentName): \(state)", blocks: blocks)
    }
}

// MARK: - Slack Signature Verifier

public struct SlackSignatureVerifier: Sendable {
    public static func verify(
        signatureHeader: String?,
        timestampHeader: String?,
        rawBody: Data,
        signingSecret: String,
        maxReplayToleranceSeconds: TimeInterval = 300.0,
        currentDate: Date = Date()
    ) -> (valid: Bool, reason: String?) {
        guard let signature = signatureHeader, !signature.isEmpty else {
            return (false, "Missing X-Slack-Signature header")
        }
        guard signature.hasPrefix("v0=") else {
            return (false, "Invalid signature scheme; expected 'v0=' prefix")
        }
        guard let timestampStr = timestampHeader, let timestamp = Double(timestampStr) else {
            return (false, "Missing or non-numeric X-Slack-Request-Timestamp header")
        }

        let age = abs(currentDate.timeIntervalSince1970 - timestamp)
        guard age <= maxReplayToleranceSeconds else {
            return (false, "Timestamp age (\(Int(age))s) exceeds replay threshold (\(Int(maxReplayToleranceSeconds))s)")
        }

        guard let bodyString = String(data: rawBody, encoding: .utf8) else {
            return (false, "Body is not UTF-8 decodable")
        }

        let basestring = "v0:\(timestampStr):\(bodyString)"
        guard let baseData = basestring.data(using: .utf8),
              let secretData = signingSecret.data(using: .utf8) else {
            return (false, "String encoding failed")
        }

        let key = SymmetricKey(data: secretData)
        let mac = HMAC<SHA256>.authenticationCode(for: baseData, using: key)
        let computedHex = "v0=" + mac.map { String(format: "%02x", $0) }.joined()

        let providedData = Data(signature.utf8)
        let computedData = Data(computedHex.utf8)

        // Constant time comparison
        guard providedData.count == computedData.count else {
            return (false, "Signature length mismatch")
        }

        var match = 0
        for i in 0..<providedData.count {
            match |= Int(providedData[i] ^ computedData[i])
        }

        if match == 0 {
            return (true, nil)
        } else {
            return (false, "HMAC-SHA256 verification failed")
        }
    }
}

// MARK: - Slack Integration Auditor

public struct SlackSecurityViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct SlackAuditReport: Sendable, Codable, Equatable {
    public let isCompliant: Bool
    public let securityScore: Double
    public let signatureVerified: Bool
    public let replaySafe: Bool
    public let violations: [SlackSecurityViolation]

    public init(
        isCompliant: Bool,
        securityScore: Double,
        signatureVerified: Bool,
        replaySafe: Bool,
        violations: [SlackSecurityViolation]
    ) {
        self.isCompliant = isCompliant
        self.securityScore = securityScore
        self.signatureVerified = signatureVerified
        self.replaySafe = replaySafe
        self.violations = violations
    }
}

public struct SlackIntegrationAuditor: Sendable {
    public static func auditWebhookURL(_ url: URL) -> [SlackSecurityViolation] {
        var violations: [SlackSecurityViolation] = []

        if url.scheme?.lowercased() != "https" {
            violations.append(SlackSecurityViolation(
                code: "INSECURE_SLACK_SCHEME",
                message: "Slack incoming webhooks must use HTTPS.",
                isFatal: true
            ))
        }

        let host = url.host?.lowercased() ?? ""
        if host != "hooks.slack.com" {
            violations.append(SlackSecurityViolation(
                code: "SUSPICIOUS_WEBHOOK_HOST",
                message: "Expected 'hooks.slack.com', found '\(host)'.",
                isFatal: false
            ))
        }

        if !url.path.hasPrefix("/services/") {
            violations.append(SlackSecurityViolation(
                code: "INVALID_WEBHOOK_PATH",
                message: "Slack webhook URL path must start with '/services/'.",
                isFatal: false
            ))
        }

        return violations
    }

    public static func auditInboundRequest(
        signatureHeader: String?,
        timestampHeader: String?,
        rawBody: Data,
        config: SlackSecurityConfig,
        currentDate: Date = Date()
    ) -> SlackAuditReport {
        var violations: [SlackSecurityViolation] = []
        var signatureVerified = false
        var replaySafe = false

        if let secret = config.signingSecret, !secret.isEmpty {
            let res = SlackSignatureVerifier.verify(
                signatureHeader: signatureHeader,
                timestampHeader: timestampHeader,
                rawBody: rawBody,
                signingSecret: secret,
                maxReplayToleranceSeconds: config.maxReplayToleranceSeconds,
                currentDate: currentDate
            )
            signatureVerified = res.valid
            if !res.valid {
                violations.append(SlackSecurityViolation(
                    code: "SIGNATURE_VERIFICATION_FAILED",
                    message: res.reason ?? "Invalid signature",
                    isFatal: true
                ))
            } else {
                replaySafe = true
            }
        } else {
            violations.append(SlackSecurityViolation(
                code: "MISSING_SIGNING_SECRET",
                message: "No Slack signing secret configured to verify incoming payload authenticity.",
                isFatal: true
            ))
        }

        // Payload size checks
        if rawBody.count > 250_000 {
            violations.append(SlackSecurityViolation(
                code: "EXCESSIVE_PAYLOAD_SIZE",
                message: "Payload size (\(rawBody.count) bytes) exceeds Slack threshold.",
                isFatal: false
            ))
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let warnCount = violations.filter { !$0.isFatal }.count
        let rawScore = 1.0 - (Double(fatalCount) * 0.5) - (Double(warnCount) * 0.1)
        let score = max(0.0, min(1.0, rawScore))
        let compliant = fatalCount == 0

        return SlackAuditReport(
            isCompliant: compliant,
            securityScore: score,
            signatureVerified: signatureVerified,
            replaySafe: replaySafe,
            violations: violations
        )
    }

    public static func formatSlackAuditReportMarkdown(_ report: SlackAuditReport) -> String {
        var md = "### 💬 Slack Integration & Signature Security Audit\n\n"
        md += "| Metric | Value | Status |\n"
        md += "|---|---|---|\n"
        md += "| Compliance | \(report.isCompliant ? "✅ Compliant" : "❌ Violation") | Architecture Standard |\n"
        md += "| Security Score | `\(Int(report.securityScore * 100))%` | \(report.securityScore >= 0.8 ? "🛡️ Solid" : "⚠️ Attention Required") |\n"
        md += "| Signature Verified | \(report.signatureVerified ? "✅ Verified (v0)" : "❌ Unverified") | Cryptographic Auth |\n"
        md += "| Replay Protection | \(report.replaySafe ? "✅ Active" : "❌ Expired / Untrusted") | Timestamp Window |\n\n"

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
