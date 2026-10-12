//
//  DiscordIntegrationAuditor.swift
//  ApexAgent
//
//  Created for Batch 114: Discord Bot, Rich Embed Builder & Ed25519 Interaction Signature Auditor.
//

import Foundation
import CryptoKit

// MARK: - Discord Embed Structures

public struct DiscordEmbedField: Sendable, Codable, Equatable {
    public let name: String
    public let value: String
    public let inline: Bool

    public init(name: String, value: String, inline: Bool = false) {
        self.name = String(name.prefix(256))
        self.value = String(value.prefix(1024))
        self.inline = inline
    }
}

public struct DiscordEmbedFooter: Sendable, Codable, Equatable {
    public let text: String
    public let iconURL: String?

    public init(text: String, iconURL: String? = nil) {
        self.text = String(text.prefix(2048))
        self.iconURL = iconURL
    }
}

public struct DiscordEmbed: Sendable, Codable, Equatable {
    public let title: String?
    public let description: String?
    public let url: String?
    public let color: Int?
    public let fields: [DiscordEmbedField]
    public let footer: DiscordEmbedFooter?
    public let timestamp: String?

    public init(
        title: String? = nil,
        description: String? = nil,
        url: String? = nil,
        color: Int? = 0x5865F2, // Discord blurple default
        fields: [DiscordEmbedField] = [],
        footer: DiscordEmbedFooter? = nil,
        timestamp: String? = nil
    ) {
        self.title = title.map { String($0.prefix(256)) }
        self.description = description.map { String($0.prefix(4096)) }
        self.url = url
        self.color = color
        self.fields = Array(fields.prefix(25))
        self.footer = footer
        self.timestamp = timestamp
    }
}

public struct DiscordWebhookPayload: Sendable, Codable, Equatable {
    public let content: String?
    public let username: String?
    public let avatarURL: String?
    public let embeds: [DiscordEmbed]

    public init(
        content: String? = nil,
        username: String? = "ApexAgent",
        avatarURL: String? = nil,
        embeds: [DiscordEmbed] = []
    ) {
        self.content = content.map { String($0.prefix(2000)) }
        self.username = username
        self.avatarURL = avatarURL
        self.embeds = Array(embeds.prefix(10))
    }
}

// MARK: - Discord Audit Violation & Report

public struct DiscordAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct DiscordAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let violations: [DiscordAuditViolation]
    public let webhookURLSanitized: String?
    public let ed25519KeyConfigured: Bool

    public init(
        passed: Bool,
        score: Double,
        violations: [DiscordAuditViolation],
        webhookURLSanitized: String?,
        ed25519KeyConfigured: Bool
    ) {
        self.passed = passed
        self.score = score
        self.violations = violations
        self.webhookURLSanitized = webhookURLSanitized
        self.ed25519KeyConfigured = ed25519KeyConfigured
    }
}

// MARK: - Discord Integration Auditor

public enum DiscordIntegrationAuditor {

    // MARK: - Audit Configuration

    public static func auditConfiguration(
        webhookURL: URL?,
        publicKeyHex: String? = nil
    ) -> DiscordAuditReport {
        var violations: [DiscordAuditViolation] = []

        // 1. Webhook URL Verification
        var sanitizedURL: String? = nil
        if let url = webhookURL {
            let scheme = url.scheme?.lowercased() ?? ""
            let host = url.host?.lowercased() ?? ""
            let isLocal = (host == "localhost" || host == "127.0.0.1" || host == "::1")

            if scheme != "https" && !isLocal {
                violations.append(DiscordAuditViolation(
                    code: "INSECURE_DISCORD_HTTP_ENDPOINT",
                    message: "Discord webhook endpoint must use HTTPS transport security.",
                    isFatal: true
                ))
            }

            if host != "discord.com" && host != "discordapp.com" && !isLocal {
                violations.append(DiscordAuditViolation(
                    code: "NON_DISCORD_WEBHOOK_HOST",
                    message: "Webhook target host '\(host)' does not match official discord.com domains.",
                    isFatal: false
                ))
            }

            // Redact webhook token in path (/api/webhooks/{id}/{token})
            let components = url.pathComponents
            if components.count >= 4 && components[1] == "api" && components[2] == "webhooks" {
                sanitizedURL = "https://\(host)/api/webhooks/\(components[3])/**REDACTED**"
            } else {
                sanitizedURL = "https://\(host)\(url.path)"
            }
        }

        // 2. Ed25519 Public Key Verification
        var hasValidKey = false
        if let keyHex = publicKeyHex?.trimmingCharacters(in: .whitespacesAndNewlines), !keyHex.isEmpty {
            if keyHex.count != 64 {
                violations.append(DiscordAuditViolation(
                    code: "INVALID_ED25519_KEY_LENGTH",
                    message: "Ed25519 public key must be exactly 64 hex characters (32 bytes). Provided length: \(keyHex.count).",
                    isFatal: true
                ))
            } else if dataFromHex(keyHex) == nil {
                violations.append(DiscordAuditViolation(
                    code: "MALFORMED_HEX_KEY",
                    message: "Ed25519 public key contains non-hexadecimal characters.",
                    isFatal: true
                ))
            } else {
                hasValidKey = true
            }
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let nonFatalCount = violations.filter { !$0.isFatal }.count
        let rawScore = 100.0 - (Double(fatalCount) * 50.0) - (Double(nonFatalCount) * 15.0)
        let finalScore = max(0.0, min(100.0, rawScore))
        let passed = (fatalCount == 0)

        return DiscordAuditReport(
            passed: passed,
            score: finalScore,
            violations: violations,
            webhookURLSanitized: sanitizedURL,
            ed25519KeyConfigured: hasValidKey
        )
    }

    // MARK: - Ed25519 Signature Verification

    /// Verifies Discord incoming HTTP interaction signature using Curve25519.
    /// Discord signs message = `timestamp + body` using Ed25519.
    public static func verifyEd25519Signature(
        publicKeyHex: String,
        signatureHex: String,
        timestamp: String,
        body: Data
    ) -> Bool {
        guard let keyData = dataFromHex(publicKeyHex), keyData.count == 32 else { return false }
        guard let sigData = dataFromHex(signatureHex), sigData.count == 64 else { return false }
        guard !timestamp.isEmpty else { return false }

        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }

        var messageData = Data(timestamp.utf8)
        messageData.append(body)

        return publicKey.isValidSignature(sigData, for: messageData)
    }

    // MARK: - Webhook Request Builder

    /// Builds a URLRequest for executing a Discord webhook with embeds.
    public static func buildExecuteWebhookRequest(
        webhookURL: URL,
        payload: DiscordWebhookPayload
    ) -> URLRequest? {
        var req = URLRequest(url: webhookURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        var dict: [String: Any] = [:]
        if let c = payload.content { dict["content"] = c }
        if let u = payload.username { dict["username"] = u }
        if let a = payload.avatarURL { dict["avatar_url"] = a }

        if !payload.embeds.isEmpty {
            var embedsList: [[String: Any]] = []
            for emb in payload.embeds {
                var embDict: [String: Any] = [:]
                if let t = emb.title { embDict["title"] = t }
                if let d = emb.description { embDict["description"] = d }
                if let u = emb.url { embDict["url"] = u }
                if let c = emb.color { embDict["color"] = c }
                if let ts = emb.timestamp { embDict["timestamp"] = ts }
                if let f = emb.footer {
                    var fDict: [String: Any] = ["text": f.text]
                    if let icon = f.iconURL { fDict["icon_url"] = icon }
                    embDict["footer"] = fDict
                }
                if !emb.fields.isEmpty {
                    let fieldsArr = emb.fields.map { ["name": $0.name, "value": $0.value, "inline": $0.inline] }
                    embDict["fields"] = fieldsArr
                }
                embedsList.append(embDict)
            }
            dict["embeds"] = embedsList
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        req.httpBody = data
        return req
    }

    // MARK: - Hex Helper

    private static func dataFromHex(_ hex: String) -> Data? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let nextIndex = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    // MARK: - Markdown Formatter

    public static func formatDiscordAuditReportMarkdown(_ report: DiscordAuditReport) -> String {
        var md = "### 🎮 Discord Webhook & Ed25519 Interaction Audit\n\n"
        md += "| Metric | Value |\n"
        md += "|---|---|\n"
        md += "| **Status** | \(report.passed ? "✅ Compliant" : "❌ Non-Compliant") |\n"
        md += "| **Score** | `\(String(format: "%.1f", report.score))%` |\n"
        md += "| **Target Webhook** | `\(report.webhookURLSanitized ?? "None")` |\n"
        md += "| **Ed25519 Key Configured** | `\(report.ed25519KeyConfigured ? "Yes" : "No")` |\n\n"

        if report.violations.isEmpty {
            md += "✨ **Zero violations found.** Discord webhook transport and Ed25519 signature config are valid.\n"
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
