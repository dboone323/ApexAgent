//
//  LinearIntegrationAuditor.swift
//  ApexAgent
//
//  Created for Batch 104: Linear Project Management Integration & GraphQL Auditor.
//

import Foundation
import CryptoKit

// MARK: - Linear Configuration

public struct LinearClientConfiguration: Sendable, Codable, Equatable {
    public var endpointURL: URL
    public var apiToken: String
    public var webhookSigningSecret: String?
    public var timeoutInterval: TimeInterval

    public static let defaultEndpoint = URL(string: "https://api.linear.app/graphql")!

    public init(
        endpointURL: URL = defaultEndpoint,
        apiToken: String = "",
        webhookSigningSecret: String? = nil,
        timeoutInterval: TimeInterval = 30.0
    ) {
        self.endpointURL = endpointURL
        self.apiToken = apiToken
        self.webhookSigningSecret = webhookSigningSecret
        self.timeoutInterval = timeoutInterval
    }
}

// MARK: - GraphQL Query & Mutation Models

public struct LinearGraphQLRequest: Sendable, Codable, Equatable {
    public let query: String
    public let variables: [String: String]

    public init(query: String, variables: [String: String] = [:]) {
        self.query = query
        self.variables = variables
    }

    public func toJSONData() -> Data? {
        var dict: [String: Any] = ["query": query]
        if !variables.isEmpty {
            dict["variables"] = variables
        }
        return try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }
}

public struct LinearIssueDraft: Sendable, Codable, Equatable {
    public let title: String
    public let description: String
    public let teamId: String
    public let priority: Int // 0: None, 1: Urgent, 2: High, 3: Medium, 4: Low
    public let labelIds: [String]

    public init(
        title: String,
        description: String,
        teamId: String,
        priority: Int = 3,
        labelIds: [String] = []
    ) {
        self.title = title
        self.description = description
        self.teamId = teamId
        self.priority = priority
        self.labelIds = labelIds
    }
}

public struct LinearGraphQLBuilder: Sendable {
    public static func buildViewerQuery() -> LinearGraphQLRequest {
        LinearGraphQLRequest(
            query: "query Viewer { viewer { id name email } }"
        )
    }

    public static func buildIssuesQuery(teamId: String, first: Int = 20) -> LinearGraphQLRequest {
        LinearGraphQLRequest(
            query: """
            query TeamIssues($teamId: String!, $first: Int!) {
              team(id: $teamId) {
                issues(first: $first) {
                  nodes {
                    id
                    identifier
                    title
                    state { name }
                    priority
                  }
                }
              }
            }
            """,
            variables: ["teamId": teamId, "first": String(first)]
        )
    }

    public static func buildCreateIssueMutation(draft: LinearIssueDraft) -> LinearGraphQLRequest {
        LinearGraphQLRequest(
            query: """
            mutation CreateIssue($title: String!, $description: String, $teamId: String!, $priority: Int) {
              issueCreate(input: { title: $title, description: $description, teamId: $teamId, priority: $priority }) {
                success
                issue {
                  id
                  identifier
                  title
                  url
                }
              }
            }
            """,
            variables: [
                "title": draft.title,
                "description": draft.description,
                "teamId": draft.teamId,
                "priority": String(draft.priority)
            ]
        )
    }
}

// MARK: - Linear Webhook Signature Verifier

public struct LinearWebhookSignatureVerifier: Sendable {
    public static func verify(
        signatureHeader: String?,
        rawBody: Data,
        signingSecret: String
    ) -> (valid: Bool, reason: String?) {
        guard let signature = signatureHeader, !signature.isEmpty else {
            return (false, "Missing Linear-Signature header")
        }
        guard !signingSecret.isEmpty, let secretData = signingSecret.data(using: .utf8) else {
            return (false, "Signing secret is empty or invalid UTF-8")
        }

        let key = SymmetricKey(data: secretData)
        let mac = HMAC<SHA256>.authenticationCode(for: rawBody, using: key)
        let computedHex = mac.map { String(format: "%02x", $0) }.joined()

        let providedClean = signature.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let computedClean = computedHex.lowercased()

        let providedData = Data(providedClean.utf8)
        let computedData = Data(computedClean.utf8)

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
            return (false, "HMAC-SHA256 signature verification failed")
        }
    }
}

// MARK: - Linear Integration Auditor

public struct LinearSecurityViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct LinearAuditReport: Sendable, Codable, Equatable {
    public let endpointURL: String
    public let hasToken: Bool
    public let hasWebhookSecret: Bool
    public let isCompliant: Bool
    public let securityScore: Double
    public let violations: [LinearSecurityViolation]

    public init(
        endpointURL: String,
        hasToken: Bool,
        hasWebhookSecret: Bool,
        isCompliant: Bool,
        securityScore: Double,
        violations: [LinearSecurityViolation]
    ) {
        self.endpointURL = endpointURL
        self.hasToken = hasToken
        self.hasWebhookSecret = hasWebhookSecret
        self.isCompliant = isCompliant
        self.securityScore = securityScore
        self.violations = violations
    }
}

public struct LinearIntegrationAuditor: Sendable {
    public static func auditConfiguration(_ config: LinearClientConfiguration) -> LinearAuditReport {
        var violations: [LinearSecurityViolation] = []

        // 1. Endpoint TLS Check
        if config.endpointURL.scheme?.lowercased() != "https" {
            let isLocal = (config.endpointURL.host == "localhost" || config.endpointURL.host == "127.0.0.1")
            if isLocal {
                violations.append(LinearSecurityViolation(
                    code: "LOCAL_HTTP_ALLOWED",
                    message: "Plaintext HTTP allowed for local mock GraphQL server.",
                    isFatal: false
                ))
            } else {
                violations.append(LinearSecurityViolation(
                    code: "INSECURE_GRAPHQL_ENDPOINT",
                    message: "Linear API endpoint must use HTTPS to prevent token interception.",
                    isFatal: true
                ))
            }
        }

        // 2. Host Verification
        let host = config.endpointURL.host?.lowercased() ?? ""
        if host != "api.linear.app" && host != "localhost" && host != "127.0.0.1" {
            violations.append(LinearSecurityViolation(
                code: "CUSTOM_GRAPHQL_HOST",
                message: "Endpoint host '\(host)' differs from official 'api.linear.app'.",
                isFatal: false
            ))
        }

        // 3. API Token Check
        let hasToken = !config.apiToken.isEmpty || (KeychainManager.get(key: "linearAPIToken")?.isEmpty == false)
        if !hasToken {
            violations.append(LinearSecurityViolation(
                code: "MISSING_LINEAR_TOKEN",
                message: "No Linear API token configured in configuration or Keychain.",
                isFatal: true
            ))
        } else if !config.apiToken.isEmpty && !config.apiToken.hasPrefix("lin_api_") && !config.apiToken.hasPrefix("lin_oauth_") {
            violations.append(LinearSecurityViolation(
                code: "UNCONVENTIONAL_TOKEN_FORMAT",
                message: "Linear tokens typically begin with 'lin_api_' or 'lin_oauth_'.",
                isFatal: false
            ))
        }

        // 4. Webhook Secret Check
        let hasWebhookSecret = (config.webhookSigningSecret?.isEmpty == false) || (KeychainManager.get(key: "linearWebhookSecret")?.isEmpty == false)
        if !hasWebhookSecret {
            violations.append(LinearSecurityViolation(
                code: "MISSING_WEBHOOK_SECRET",
                message: "No Linear webhook signing secret configured for inbound event verification.",
                isFatal: false
            ))
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let warnCount = violations.filter { !$0.isFatal }.count
        let rawScore = 1.0 - (Double(fatalCount) * 0.45) - (Double(warnCount) * 0.1)
        let score = max(0.0, min(1.0, rawScore))
        let compliant = fatalCount == 0

        return LinearAuditReport(
            endpointURL: config.endpointURL.absoluteString,
            hasToken: hasToken,
            hasWebhookSecret: hasWebhookSecret,
            isCompliant: compliant,
            securityScore: score,
            violations: violations
        )
    }

    public static func auditGraphQLQuery(_ query: String) -> [LinearSecurityViolation] {
        var violations: [LinearSecurityViolation] = []

        // Inspect query depth / recursion heuristics
        let braceCount = query.filter { $0 == "{" }.count
        if braceCount > 12 {
            violations.append(LinearSecurityViolation(
                code: "EXCESSIVE_QUERY_DEPTH",
                message: "Query depth exceeds safe nesting threshold (\(braceCount) levels).",
                isFatal: false
            ))
        }

        // Check for raw string concatenation injection patterns (e.g. unparameterized queries)
        if query.contains("\"\"\"") || query.contains("--") || query.contains("/*") {
            violations.append(LinearSecurityViolation(
                code: "SUSPICIOUS_QUERY_SYNTAX",
                message: "Query contains comment markers or multi-line quotes resembling unescaped injections.",
                isFatal: true
            ))
        }

        return violations
    }

    public static func formatLinearAuditReportMarkdown(_ report: LinearAuditReport) -> String {
        var md = "### 📐 Linear Integration & GraphQL Security Audit\n\n"
        md += "| Metric | Value | Status |\n"
        md += "|---|---|---|\n"
        md += "| Compliance | \(report.isCompliant ? "✅ Compliant" : "❌ Violation") | API Standards |\n"
        md += "| Security Score | `\(Int(report.securityScore * 100))%` | \(report.securityScore >= 0.8 ? "🛡️ Solid" : "⚠️ Needs Attention") |\n"
        md += "| Endpoint | `\(report.endpointURL)` | Target Host |\n"
        md += "| Token Configured | \(report.hasToken ? "✅ Present" : "❌ Missing") | Authentication |\n"
        md += "| Webhook Secret | \(report.hasWebhookSecret ? "✅ Present" : "🟡 Not Set") | Webhook Security |\n\n"

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
