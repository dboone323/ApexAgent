//
//  IncidentManagementAuditor.swift
//  ApexAgent
//
//  Created for Batch 118: PagerDuty Events API v2 Client & Opsgenie Incident Escalation Auditor.
//

import Foundation

// MARK: - Incident Models

public enum IncidentSeverity: String, Sendable, Codable, Equatable {
    case info
    case warning
    case error
    case critical
}

public enum IncidentAction: String, Sendable, Codable, Equatable {
    case trigger
    case acknowledge
    case resolve
}

public struct PagerDutyEventPayload: Sendable, Codable, Equatable {
    public let eventAction: IncidentAction
    public let summary: String
    public let source: String
    public let severity: IncidentSeverity
    public let dedupKey: String?
    public let component: String?

    public init(
        eventAction: IncidentAction = .trigger,
        summary: String,
        source: String = "apexagent.local",
        severity: IncidentSeverity = .error,
        dedupKey: String? = nil,
        component: String? = "orchestrator"
    ) {
        self.eventAction = eventAction
        self.summary = String(summary.prefix(1024))
        self.source = String(source.prefix(255))
        self.severity = severity
        self.dedupKey = dedupKey.map { String($0.prefix(255)) }
        self.component = component
    }
}

public struct OpsgenieAlertPayload: Sendable, Codable, Equatable {
    public let message: String
    public let alias: String?
    public let description: String?
    public let priority: String // P1, P2, P3, P4, P5
    public let tags: [String]
    public let details: [String: String]

    public init(
        message: String,
        alias: String? = nil,
        description: String? = nil,
        priority: String = "P2",
        tags: [String] = [],
        details: [String: String] = [:]
    ) {
        self.message = String(message.prefix(130))
        self.alias = alias
        self.description = description.map { String($0.prefix(15000)) }
        self.priority = priority
        self.tags = tags
        self.details = details
    }
}

// MARK: - Incident Audit Violation & Report

public struct IncidentAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct IncidentAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let routingKeyConfigured: Bool
    public let violations: [IncidentAuditViolation]
    public let redactedKey: String?

    public init(
        passed: Bool,
        score: Double,
        routingKeyConfigured: Bool,
        violations: [IncidentAuditViolation],
        redactedKey: String?
    ) {
        self.passed = passed
        self.score = score
        self.routingKeyConfigured = routingKeyConfigured
        self.violations = violations
        self.redactedKey = redactedKey
    }
}

// MARK: - Incident Management Auditor

public enum IncidentManagementAuditor {

    public static let pagerDutyEnqueueURL = URL(string: "https://events.pagerduty.com/v2/enqueue")!
    public static let opsgenieAlertURL = URL(string: "https://api.opsgenie.com/v2/alerts")!

    // MARK: - Audit Configuration

    public static func auditPagerDutyConfiguration(
        routingKey: String,
        endpointURL: URL = pagerDutyEnqueueURL
    ) -> IncidentAuditReport {
        var violations: [IncidentAuditViolation] = []
        let cleanKey = routingKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Routing Key Validation
        if cleanKey.isEmpty {
            violations.append(IncidentAuditViolation(
                code: "EMPTY_ROUTING_KEY",
                message: "PagerDuty 32-character integration routing key cannot be empty.",
                isFatal: true
            ))
        } else if cleanKey.count < 16 {
            violations.append(IncidentAuditViolation(
                code: "SUSPICIOUS_SHORT_KEY",
                message: "Integration routing key is suspiciously short (< 16 characters).",
                isFatal: true
            ))
        }

        // 2. Transport Protocol Security
        let scheme = endpointURL.scheme?.lowercased() ?? ""
        let host = endpointURL.host?.lowercased() ?? ""
        let isLocal = (host == "localhost" || host == "127.0.0.1" || host == "::1")

        if scheme != "https" && !isLocal {
            violations.append(IncidentAuditViolation(
                code: "INSECURE_PAGERDUTY_HTTP_ENDPOINT",
                message: "Remote PagerDuty Events API endpoint must use HTTPS transport security.",
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

        return IncidentAuditReport(
            passed: passed,
            score: finalScore,
            routingKeyConfigured: !cleanKey.isEmpty,
            violations: violations,
            redactedKey: redacted
        )
    }

    // MARK: - PagerDuty Events API v2 Request Builder

    public static func buildPagerDutyEventRequest(
        routingKey: String,
        payload: PagerDutyEventPayload,
        endpointURL: URL = pagerDutyEnqueueURL
    ) -> URLRequest? {
        let cleanKey = routingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !payload.summary.isEmpty, !payload.source.isEmpty else {
            return nil
        }

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        var bodyDict: [String: Any] = [
            "routing_key": cleanKey,
            "event_action": payload.eventAction.rawValue,
            "payload": [
                "summary": payload.summary,
                "source": payload.source,
                "severity": payload.severity.rawValue,
                "component": payload.component ?? "agent"
            ] as [String: Any]
        ]
        if let dedup = payload.dedupKey {
            bodyDict["dedup_key"] = dedup
        }

        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    // MARK: - Opsgenie Alert Request Builder

    public static func buildOpsgenieAlertRequest(
        apiKey: String,
        payload: OpsgenieAlertPayload,
        endpointURL: URL = opsgenieAlertURL
    ) -> URLRequest? {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !payload.message.isEmpty else { return nil }

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.setValue("GenieKey \(cleanKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        var bodyDict: [String: Any] = [
            "message": payload.message,
            "priority": payload.priority
        ]
        if let a = payload.alias { bodyDict["alias"] = a }
        if let d = payload.description { bodyDict["description"] = d }
        if !payload.tags.isEmpty { bodyDict["tags"] = payload.tags }
        if !payload.details.isEmpty { bodyDict["details"] = payload.details }

        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    // MARK: - Markdown Formatter

    public static func formatIncidentAuditReportMarkdown(_ report: IncidentAuditReport) -> String {
        var md = "### 🚨 Incident Management & On-Call Dispatch Audit\n\n"
        md += "| Parameter | Value |\n"
        md += "|---|---|\n"
        md += "| **Status** | \(report.passed ? "✅ Compliant" : "❌ Non-Compliant") |\n"
        md += "| **Score** | `\(String(format: "%.1f", report.score))%` |\n"
        md += "| **Routing Key Configured** | `\(report.routingKeyConfigured ? "Yes" : "No")` |\n"
        md += "| **Token Preview** | `\(report.redactedKey ?? "N/A")` |\n\n"

        if report.violations.isEmpty {
            md += "✨ **Zero violations found.** PagerDuty & Opsgenie integration endpoints are properly secured.\n"
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
