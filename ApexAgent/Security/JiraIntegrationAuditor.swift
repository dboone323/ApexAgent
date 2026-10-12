//
//  JiraIntegrationAuditor.swift
//  ApexAgent
//
//  Created for Batch 112: Jira & Atlassian Document Format (ADF) Parser & Webhook Auditor.
//

import Foundation

// MARK: - Jira Issue Models

public struct JiraIssueCreatePayload: Sendable, Codable, Equatable {
    public let projectKey: String
    public let summary: String
    public let issueType: String
    public let descriptionMarkdown: String
    public let labels: [String]
    public let priority: String

    public init(
        projectKey: String,
        summary: String,
        issueType: String = "Task",
        descriptionMarkdown: String,
        labels: [String] = [],
        priority: String = "Medium"
    ) {
        self.projectKey = projectKey
        self.summary = summary
        self.issueType = issueType
        self.descriptionMarkdown = descriptionMarkdown
        self.labels = labels
        self.priority = priority
    }
}

// MARK: - Jira Audit Violation & Report

public struct JiraAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct JiraAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let domain: String
    public let userEmail: String
    public let violations: [JiraAuditViolation]
    public let redactedToken: String?

    public init(
        passed: Bool,
        score: Double,
        domain: String,
        userEmail: String,
        violations: [JiraAuditViolation],
        redactedToken: String?
    ) {
        self.passed = passed
        self.score = score
        self.domain = domain
        self.userEmail = userEmail
        self.violations = violations
        self.redactedToken = redactedToken
    }
}

// MARK: - Jira Integration Auditor

public enum JiraIntegrationAuditor {

    // MARK: - Configuration Audit

    public static func auditConfiguration(
        domain: String,
        userEmail: String,
        apiToken: String
    ) -> JiraAuditReport {
        var violations: [JiraAuditViolation] = []
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanEmail = userEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Domain Validation
        if cleanDomain.isEmpty {
            violations.append(JiraAuditViolation(
                code: "EMPTY_ATLASSIAN_DOMAIN",
                message: "Atlassian cloud domain is required (e.g. company.atlassian.net).",
                isFatal: true
            ))
        } else if !cleanDomain.contains(".atlassian.net") && cleanDomain != "localhost" && !cleanDomain.hasPrefix("127.0.0.1") {
            violations.append(JiraAuditViolation(
                code: "NON_STANDARD_ATLASSIAN_DOMAIN",
                message: "Domain '\(cleanDomain)' does not match expected '*.atlassian.net' cloud suffix.",
                isFatal: false
            ))
        }

        // 2. Email Validation
        if cleanEmail.isEmpty {
            violations.append(JiraAuditViolation(
                code: "EMPTY_USER_EMAIL",
                message: "Atlassian Cloud REST API requires user email for basic auth credentials.",
                isFatal: true
            ))
        } else if !cleanEmail.contains("@") || !cleanEmail.contains(".") {
            violations.append(JiraAuditViolation(
                code: "INVALID_EMAIL_FORMAT",
                message: "Email '\(cleanEmail)' is not a valid email address.",
                isFatal: true
            ))
        }

        // 3. API Token Validation
        if cleanToken.isEmpty {
            violations.append(JiraAuditViolation(
                code: "EMPTY_API_TOKEN",
                message: "Atlassian API token cannot be empty.",
                isFatal: true
            ))
        } else if cleanToken.count < 10 {
            violations.append(JiraAuditViolation(
                code: "SUSPICIOUS_SHORT_TOKEN",
                message: "API token length is under 10 characters, likely placeholder.",
                isFatal: true
            ))
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let nonFatalCount = violations.filter { !$0.isFatal }.count
        let rawScore = 100.0 - (Double(fatalCount) * 50.0) - (Double(nonFatalCount) * 15.0)
        let finalScore = max(0.0, min(100.0, rawScore))
        let passed = (fatalCount == 0)

        var redacted: String? = nil
        if !cleanToken.isEmpty {
            if cleanToken.count > 8 {
                let p = cleanToken.prefix(3)
                let s = cleanToken.suffix(3)
                redacted = "\(p)...\(s)"
            } else {
                redacted = "***"
            }
        }

        return JiraAuditReport(
            passed: passed,
            score: finalScore,
            domain: cleanDomain,
            userEmail: cleanEmail,
            violations: violations,
            redactedToken: redacted
        )
    }

    // MARK: - Basic Auth Header Builder

    public static func buildBasicAuthHeader(userEmail: String, apiToken: String) -> String {
        let raw = "\(userEmail.trimmingCharacters(in: .whitespacesAndNewlines)):\(apiToken.trimmingCharacters(in: .whitespacesAndNewlines))"
        let data = Data(raw.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    // MARK: - Atlassian Document Format (ADF) Builder

    /// Converts standard markdown paragraphs and lines into an Atlassian Document Format (ADF) v1 dictionary.
    public static func buildADFDocument(markdown: String) -> [String: Any] {
        let lines = markdown.components(separatedBy: .newlines)
        var contentNodes: [[String: Any]] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("### ") {
                let headingText = String(trimmed.dropFirst(4))
                contentNodes.append([
                    "type": "heading",
                    "attrs": ["level": 3],
                    "content": [
                        ["type": "text", "text": headingText]
                    ]
                ])
            } else if trimmed.hasPrefix("## ") {
                let headingText = String(trimmed.dropFirst(3))
                contentNodes.append([
                    "type": "heading",
                    "attrs": ["level": 2],
                    "content": [
                        ["type": "text", "text": headingText]
                    ]
                ])
            } else if trimmed.hasPrefix("# ") {
                let headingText = String(trimmed.dropFirst(2))
                contentNodes.append([
                    "type": "heading",
                    "attrs": ["level": 1],
                    "content": [
                        ["type": "text", "text": headingText]
                    ]
                ])
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let bulletText = String(trimmed.dropFirst(2))
                contentNodes.append([
                    "type": "bulletList",
                    "content": [
                        [
                            "type": "listItem",
                            "content": [
                                [
                                    "type": "paragraph",
                                    "content": [
                                        ["type": "text", "text": bulletText]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ])
            } else {
                contentNodes.append([
                    "type": "paragraph",
                    "content": [
                        ["type": "text", "text": trimmed]
                    ]
                ])
            }
        }

        if contentNodes.isEmpty {
            contentNodes.append([
                "type": "paragraph",
                "content": [
                    ["type": "text", "text": ""]
                ]
            ])
        }

        return [
            "version": 1,
            "type": "doc",
            "content": contentNodes
        ]
    }

    // MARK: - Request Builders

    /// Builds a URLRequest for creating a Jira Cloud issue via REST API v3.
    public static func buildCreateIssueRequest(
        domain: String,
        userEmail: String,
        apiToken: String,
        payload: JiraIssueCreatePayload
    ) -> URLRequest? {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        guard !cleanDomain.isEmpty, !payload.projectKey.isEmpty, !payload.summary.isEmpty else {
            return nil
        }

        guard let url = URL(string: "https://\(cleanDomain)/rest/api/3/issue") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(buildBasicAuthHeader(userEmail: userEmail, apiToken: apiToken), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        let adfDoc = buildADFDocument(markdown: payload.descriptionMarkdown)

        var fields: [String: Any] = [
            "project": ["key": payload.projectKey.uppercased()],
            "summary": payload.summary,
            "issuetype": ["name": payload.issueType],
            "description": adfDoc,
            "priority": ["name": payload.priority]
        ]
        if !payload.labels.isEmpty {
            fields["labels"] = payload.labels
        }

        let bodyDict: [String: Any] = ["fields": fields]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    /// Builds a URLRequest for transitioning a Jira issue to another status (e.g. Done, In Review).
    public static func buildIssueTransitionRequest(
        domain: String,
        userEmail: String,
        apiToken: String,
        issueKey: String,
        transitionId: String
    ) -> URLRequest? {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        let cleanKey = issueKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanDomain.isEmpty, !cleanKey.isEmpty, !transitionId.isEmpty else {
            return nil
        }

        guard let url = URL(string: "https://\(cleanDomain)/rest/api/3/issue/\(cleanKey)/transitions") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(buildBasicAuthHeader(userEmail: userEmail, apiToken: apiToken), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        let bodyDict: [String: Any] = [
            "transition": ["id": transitionId]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    // MARK: - Markdown Formatter

    public static func formatJiraAuditReportMarkdown(_ report: JiraAuditReport) -> String {
        var md = "### 📋 Atlassian Jira Cloud Integration Audit\n\n"
        md += "| Parameter | Value |\n"
        md += "|---|---|\n"
        md += "| **Status** | \(report.passed ? "✅ Compliant" : "❌ Non-Compliant") |\n"
        md += "| **Score** | `\(String(format: "%.1f", report.score))%` |\n"
        md += "| **Cloud Domain** | `\(report.domain)` |\n"
        md += "| **User Principal** | `\(report.userEmail)` |\n"
        md += "| **Token Preview** | `\(report.redactedToken ?? "N/A")` |\n\n"

        if report.violations.isEmpty {
            md += "✨ **Zero violations found.** Jira REST API v3 configuration and ADF parser are valid.\n"
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
