//
//  NotionIntegrationAuditor.swift
//  ApexAgent
//
//  Created for Batch 115: Notion API Block & Database Property Builder with Schema Auditor.
//

import Foundation

// MARK: - Notion Page Create Payload

public struct NotionPageCreatePayload: Sendable, Codable, Equatable {
    public let databaseId: String
    public let title: String
    public let status: String?
    public let tags: [String]
    public let contentMarkdown: String

    public init(
        databaseId: String,
        title: String,
        status: String? = nil,
        tags: [String] = [],
        contentMarkdown: String = ""
    ) {
        self.databaseId = databaseId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = status
        self.tags = tags
        self.contentMarkdown = contentMarkdown
    }
}

// MARK: - Notion Audit Violation & Report

public struct NotionAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct NotionAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let notionVersion: String
    public let violations: [NotionAuditViolation]
    public let redactedKey: String?

    public init(
        passed: Bool,
        score: Double,
        notionVersion: String,
        violations: [NotionAuditViolation],
        redactedKey: String?
    ) {
        self.passed = passed
        self.score = score
        self.notionVersion = notionVersion
        self.violations = violations
        self.redactedKey = redactedKey
    }
}

// MARK: - Notion Integration Auditor

public enum NotionIntegrationAuditor {

    public static let standardBaseURL = URL(string: "https://api.notion.com/v1")!
    public static let recommendedNotionVersion = "2022-06-28"

    // MARK: - Audit Configuration

    public static func auditConfiguration(
        apiKey: String,
        notionVersion: String = recommendedNotionVersion,
        endpointURL: URL = standardBaseURL
    ) -> NotionAuditReport {
        var violations: [NotionAuditViolation] = []
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVersion = notionVersion.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. API Key Validation
        if cleanKey.isEmpty {
            violations.append(NotionAuditViolation(
                code: "EMPTY_NOTION_API_KEY",
                message: "Notion internal or public integration token cannot be empty.",
                isFatal: true
            ))
        } else if cleanKey.count < 10 {
            violations.append(NotionAuditViolation(
                code: "SUSPICIOUS_SHORT_KEY",
                message: "Notion integration key length is suspiciously short (< 10 chars).",
                isFatal: true
            ))
        } else if !cleanKey.hasPrefix("secret_") && !cleanKey.hasPrefix("ntn_") {
            violations.append(NotionAuditViolation(
                code: "NON_STANDARD_NOTION_PREFIX",
                message: "Notion integration tokens typically start with 'secret_' or 'ntn_'.",
                isFatal: false
            ))
        }

        // 2. Notion-Version Header Validation
        if cleanVersion.isEmpty {
            violations.append(NotionAuditViolation(
                code: "MISSING_NOTION_VERSION",
                message: "Notion API requires 'Notion-Version' header (e.g. 2022-06-28).",
                isFatal: true
            ))
        }

        // 3. Transport Security
        let scheme = endpointURL.scheme?.lowercased() ?? ""
        let host = endpointURL.host?.lowercased() ?? ""
        let isLocal = (host == "localhost" || host == "127.0.0.1" || host == "::1")

        if scheme != "https" && !isLocal {
            violations.append(NotionAuditViolation(
                code: "INSECURE_NOTION_HTTP_ENDPOINT",
                message: "Remote Notion API endpoints must use HTTPS transport security.",
                isFatal: true
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
                let p = cleanKey.prefix(4)
                let s = cleanKey.suffix(3)
                redacted = "\(p)...\(s)"
            } else {
                redacted = "***"
            }
        }

        return NotionAuditReport(
            passed: passed,
            score: finalScore,
            notionVersion: cleanVersion,
            violations: violations,
            redactedKey: redacted
        )
    }

    // MARK: - Markdown to Notion Blocks Builder

    /// Converts markdown lines into Notion API block objects.
    public static func buildMarkdownToBlocks(markdown: String) -> [[String: Any]] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [[String: Any]] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("### ") {
                let text = String(trimmed.dropFirst(4))
                blocks.append([
                    "object": "block",
                    "type": "heading_3",
                    "heading_3": [
                        "rich_text": [["type": "text", "text": ["content": text]]]
                    ]
                ])
            } else if trimmed.hasPrefix("## ") {
                let text = String(trimmed.dropFirst(3))
                blocks.append([
                    "object": "block",
                    "type": "heading_2",
                    "heading_2": [
                        "rich_text": [["type": "text", "text": ["content": text]]]
                    ]
                ])
            } else if trimmed.hasPrefix("# ") {
                let text = String(trimmed.dropFirst(2))
                blocks.append([
                    "object": "block",
                    "type": "heading_1",
                    "heading_1": [
                        "rich_text": [["type": "text", "text": ["content": text]]]
                    ]
                ])
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let text = String(trimmed.dropFirst(2))
                blocks.append([
                    "object": "block",
                    "type": "bulleted_list_item",
                    "bulleted_list_item": [
                        "rich_text": [["type": "text", "text": ["content": text]]]
                    ]
                ])
            } else if trimmed.hasPrefix("```") {
                let text = trimmed.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespaces)
                blocks.append([
                    "object": "block",
                    "type": "code",
                    "code": [
                        "rich_text": [["type": "text", "text": ["content": text.isEmpty ? "code" : text]]],
                        "language": "plain text"
                    ]
                ])
            } else if trimmed == "---" {
                blocks.append([
                    "object": "block",
                    "type": "divider",
                    "divider": [:] as [String: Any]
                ])
            } else {
                blocks.append([
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": [
                        "rich_text": [["type": "text", "text": ["content": trimmed]]]
                    ]
                ])
            }
        }

        return blocks
    }

    // MARK: - Request Builders

    /// Builds a URLRequest for creating a new Notion page in a database.
    public static func buildCreatePageRequest(
        apiKey: String,
        payload: NotionPageCreatePayload,
        notionVersion: String = recommendedNotionVersion,
        baseURL: URL = standardBaseURL
    ) -> URLRequest? {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !payload.databaseId.isEmpty, !payload.title.isEmpty else {
            return nil
        }

        let endpoint = baseURL.appendingPathComponent("pages")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        req.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        var properties: [String: Any] = [
            "title": [
                "title": [
                    ["type": "text", "text": ["content": payload.title]]
                ]
            ]
        ]
        if let s = payload.status {
            properties["Status"] = ["status": ["name": s]]
        }
        if !payload.tags.isEmpty {
            properties["Tags"] = ["multi_select": payload.tags.map { ["name": $0] }]
        }

        var bodyDict: [String: Any] = [
            "parent": ["database_id": payload.databaseId],
            "properties": properties
        ]

        if !payload.contentMarkdown.isEmpty {
            let blocks = buildMarkdownToBlocks(markdown: payload.contentMarkdown)
            if !blocks.isEmpty {
                bodyDict["children"] = blocks
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    /// Builds a URLRequest for appending children blocks to an existing page or block.
    public static func buildAppendBlockChildrenRequest(
        apiKey: String,
        blockId: String,
        blocks: [[String: Any]],
        notionVersion: String = recommendedNotionVersion,
        baseURL: URL = standardBaseURL
    ) -> URLRequest? {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanId = blockId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !cleanId.isEmpty, !blocks.isEmpty else { return nil }

        let endpoint = baseURL.appendingPathComponent("blocks").appendingPathComponent(cleanId).appendingPathComponent("children")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        req.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        let bodyDict: [String: Any] = ["children": blocks]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    // MARK: - Markdown Formatter

    public static func formatNotionAuditReportMarkdown(_ report: NotionAuditReport) -> String {
        var md = "### 📑 Notion API Block & Database Integration Audit\n\n"
        md += "| Parameter | Value |\n"
        md += "|---|---|\n"
        md += "| **Status** | \(report.passed ? "✅ Compliant" : "❌ Non-Compliant") |\n"
        md += "| **Score** | `\(String(format: "%.1f", report.score))%` |\n"
        md += "| **Notion-Version** | `\(report.notionVersion)` |\n"
        md += "| **Token Preview** | `\(report.redactedKey ?? "N/A")` |\n\n"

        if report.violations.isEmpty {
            md += "✨ **Zero violations found.** Notion integration configuration and block builder are compliant.\n"
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
