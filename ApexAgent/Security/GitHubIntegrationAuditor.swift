//
//  GitHubIntegrationAuditor.swift
//  ApexAgent
//
//  Created for Batch 111: GitHub REST/GraphQL API Client & Token Permission Auditor.
//

import Foundation
import CryptoKit

// MARK: - GitHub Token Kind

public enum GitHubTokenKind: String, Sendable, Codable, Equatable {
    case classic = "classic_pat"
    case fineGrained = "fine_grained_pat"
    case oauth = "oauth_access_token"
    case userToServer = "user_to_server"
    case serverToServer = "server_to_server"
    case refresh = "refresh_token"
    case custom = "custom_token"

    public static func detect(token: String) -> GitHubTokenKind {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ghp_") {
            return .classic
        } else if trimmed.hasPrefix("github_pat_") {
            return .fineGrained
        } else if trimmed.hasPrefix("gho_") {
            return .oauth
        } else if trimmed.hasPrefix("ghu_") {
            return .userToServer
        } else if trimmed.hasPrefix("ghs_") {
            return .serverToServer
        } else if trimmed.hasPrefix("ghr_") {
            return .refresh
        } else {
            return .custom
        }
    }
}

// MARK: - GitHub Repository Identifier

public struct GitHubRepositoryIdentifier: Sendable, Codable, Equatable, Hashable {
    public let owner: String
    public let name: String

    public init?(owner: String, name: String) {
        let cleanOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanOwner.isEmpty, !cleanName.isEmpty else { return nil }
        guard cleanOwner.count <= 39, cleanName.count <= 100 else { return nil }

        // Validate GitHub owner and repo slug characters: [A-Za-z0-9_.-]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard cleanOwner.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              cleanName.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }

        self.owner = cleanOwner
        self.name = cleanName
    }

    public var slug: String {
        "\(owner)/\(name)"
    }
}

// MARK: - GitHub Commit Status State & Payload

public enum GitHubCommitStatusState: String, Sendable, Codable, Equatable {
    case pending
    case success
    case failure
    case error
}

public struct GitHubCommitStatusPayload: Sendable, Codable, Equatable {
    public let state: GitHubCommitStatusState
    public let targetURL: URL?
    public let description: String?
    public let context: String

    public init(
        state: GitHubCommitStatusState,
        targetURL: URL? = nil,
        description: String? = nil,
        context: String = "apexagent/audit"
    ) {
        self.state = state
        self.targetURL = targetURL
        self.description = description
        self.context = context
    }
}

// MARK: - GitHub Audit Violation & Report

public struct GitHubAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct GitHubAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let tokenKind: GitHubTokenKind
    public let violations: [GitHubAuditViolation]
    public let targetRepository: String?
    public let redactedToken: String?

    public init(
        passed: Bool,
        score: Double,
        tokenKind: GitHubTokenKind,
        violations: [GitHubAuditViolation],
        targetRepository: String?,
        redactedToken: String?
    ) {
        self.passed = passed
        self.score = score
        self.tokenKind = tokenKind
        self.violations = violations
        self.targetRepository = targetRepository
        self.redactedToken = redactedToken
    }
}

// MARK: - GitHub Integration Auditor

public enum GitHubIntegrationAuditor {

    public static let standardBaseURL = URL(string: "https://api.github.com")!
    public static let standardGraphQLEndpoint = URL(string: "https://api.github.com/graphql")!

    // MARK: - Audit Configuration

    public static func auditConfiguration(
        token: String,
        endpointURL: URL = standardBaseURL,
        repo: GitHubRepositoryIdentifier? = nil
    ) -> GitHubAuditReport {
        var violations: [GitHubAuditViolation] = []
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenKind = GitHubTokenKind.detect(token: cleanToken)

        // 1. Token presence & length check
        if cleanToken.isEmpty {
            violations.append(GitHubAuditViolation(
                code: "EMPTY_GITHUB_TOKEN",
                message: "GitHub authentication token cannot be empty.",
                isFatal: true
            ))
        } else if cleanToken.count < 8 {
            violations.append(GitHubAuditViolation(
                code: "SUSPICIOUS_SHORT_TOKEN",
                message: "Token length is under 8 characters, likely an incomplete placeholder.",
                isFatal: true
            ))
        }

        // 2. Transport Protocol Security
        let scheme = endpointURL.scheme?.lowercased() ?? ""
        let host = endpointURL.host?.lowercased() ?? ""
        let isLocal = (host == "localhost" || host == "127.0.0.1" || host == "::1")

        if scheme != "https" && !isLocal {
            violations.append(GitHubAuditViolation(
                code: "INSECURE_HTTP_ENDPOINT",
                message: "Remote GitHub API endpoints must use HTTPS transport security.",
                isFatal: true
            ))
        }

        // 3. GitHub Enterprise Host validation
        if host != "api.github.com" && !host.isEmpty && !isLocal {
            // Enterprise server endpoint check: must have valid hostname
            if host.hasSuffix(".invalid") || host.contains("example") {
                violations.append(GitHubAuditViolation(
                    code: "UNRESOLVABLE_ENTERPRISE_HOST",
                    message: "GitHub Enterprise hostname '\(host)' appears to be a reserved or test domain.",
                    isFatal: false
                ))
            }
        }

        // 4. Token kind evaluation
        if tokenKind == .refresh {
            violations.append(GitHubAuditViolation(
                code: "REFRESH_TOKEN_USED_AS_BEARER",
                message: "Refresh tokens cannot be used directly as API bearer tokens.",
                isFatal: true
            ))
        }

        // Calculate score
        let fatalCount = violations.filter { $0.isFatal }.count
        let nonFatalCount = violations.filter { !$0.isFatal }.count
        let rawScore = 100.0 - (Double(fatalCount) * 50.0) - (Double(nonFatalCount) * 15.0)
        let finalScore = max(0.0, min(100.0, rawScore))
        let passed = (fatalCount == 0)

        // Redacted token preview
        var redacted: String? = nil
        if !cleanToken.isEmpty {
            if cleanToken.count > 10 {
                let prefix = cleanToken.prefix(4)
                let suffix = cleanToken.suffix(4)
                redacted = "\(prefix)...\(suffix)"
            } else {
                redacted = "***"
            }
        }

        return GitHubAuditReport(
            passed: passed,
            score: finalScore,
            tokenKind: tokenKind,
            violations: violations,
            targetRepository: repo?.slug,
            redactedToken: redacted
        )
    }

    // MARK: - Request Builders

    /// Builds a URLRequest for creating an issue/PR comment.
    public static func buildCreateIssueCommentRequest(
        token: String,
        repo: GitHubRepositoryIdentifier,
        issueNumber: Int,
        body: String,
        baseURL: URL = standardBaseURL
    ) -> URLRequest? {
        guard issueNumber > 0, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let endpoint = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repo.owner)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("issues")
            .appendingPathComponent("\(issueNumber)")
            .appendingPathComponent("comments")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = ["body": body]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        req.httpBody = data
        return req
    }

    /// Builds a URLRequest for creating or updating a commit status check.
    public static func buildCreateCommitStatusRequest(
        token: String,
        repo: GitHubRepositoryIdentifier,
        sha: String,
        payload: GitHubCommitStatusPayload,
        baseURL: URL = standardBaseURL
    ) -> URLRequest? {
        let cleanSha = sha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanSha.count >= 7 && cleanSha.count <= 40 else { return nil }

        let endpoint = baseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repo.owner)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("statuses")
            .appendingPathComponent(cleanSha)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var bodyDict: [String: Any] = [
            "state": payload.state.rawValue,
            "context": payload.context
        ]
        if let target = payload.targetURL {
            bodyDict["target_url"] = target.absoluteString
        }
        if let desc = payload.description {
            bodyDict["description"] = String(desc.prefix(140))
        }

        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    /// Builds a URLRequest for GitHub GraphQL API.
    public static func buildGraphQLRequest(
        token: String,
        query: String,
        variables: [String: Any] = [:],
        endpointURL: URL = standardGraphQLEndpoint
    ) -> URLRequest? {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return nil }

        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyDict: [String: Any] = [
            "query": cleanQuery,
            "variables": variables
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    // MARK: - Markdown Report Formatter

    public static func formatGitHubAuditReportMarkdown(_ report: GitHubAuditReport) -> String {
        var md = "### 🐙 GitHub API Integration & Permission Audit\n\n"
        md += "| Metric | Value |\n"
        md += "|---|---|\n"
        md += "| **Status** | \(report.passed ? "✅ Passed" : "❌ Failed") |\n"
        md += "| **Compliance Score** | `\(String(format: "%.1f", report.score))%` |\n"
        md += "| **Token Kind** | `\(report.tokenKind.rawValue)` |\n"
        md += "| **Target Repository** | `\(report.targetRepository ?? "None specified")` |\n"
        md += "| **Token Preview** | `\(report.redactedToken ?? "N/A")` |\n\n"

        if report.violations.isEmpty {
            md += "✨ **Zero violations detected.** GitHub REST & GraphQL integration configuration is fully compliant.\n"
        } else {
            md += "#### Violations & Warnings (\(report.violations.count))\n\n"
            for v in report.violations {
                let badge = v.isFatal ? "🔴 FATAL" : "🟡 WARN"
                md += "- \(badge) `\(v.code)`: \(v.message)\n"
            }
        }
        return md
    }
}
