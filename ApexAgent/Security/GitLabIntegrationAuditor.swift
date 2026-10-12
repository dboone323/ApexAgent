//
//  GitLabIntegrationAuditor.swift
//  ApexAgent
//
//  Created for Batch 113: GitLab API Client & CI/CD Pipeline Telemetry Auditor.
//

import Foundation

// MARK: - GitLab Token Kind

public enum GitLabTokenKind: String, Sendable, Codable, Equatable {
    case personalAccessToken = "personal_access_token"
    case projectAccessToken = "project_access_token"
    case pipelineTriggerToken = "pipeline_trigger_token"
    case jobToken = "ci_job_token"
    case custom = "custom_token"

    public static func detect(token: String) -> GitLabTokenKind {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("glpat-") {
            return .personalAccessToken
        } else if trimmed.hasPrefix("glcbt-") {
            return .pipelineTriggerToken
        } else if trimmed.hasPrefix("gljob-") {
            return .jobToken
        } else {
            return .custom
        }
    }
}

// MARK: - GitLab Project Identifier

public struct GitLabProjectIdentifier: Sendable, Codable, Equatable, Hashable {
    public let rawIdentifier: String

    public init?(id: Int) {
        guard id > 0 else { return nil }
        self.rawIdentifier = "\(id)"
    }

    public init?(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // URL-encode path slashes as %2F if not already encoded
        if trimmed.contains("/") {
            self.rawIdentifier = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
                .replacingOccurrences(of: "/", with: "%2F") ?? trimmed
        } else {
            self.rawIdentifier = trimmed
        }
    }
}

// MARK: - GitLab Pipeline Trigger Payload

public struct GitLabPipelineTriggerPayload: Sendable, Codable, Equatable {
    public let ref: String
    public let variables: [String: String]

    public init(ref: String = "main", variables: [String: String] = [:]) {
        self.ref = ref
        self.variables = variables
    }
}

// MARK: - GitLab Audit Violation & Report

public struct GitLabAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct GitLabAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let instanceURL: String
    public let tokenKind: GitLabTokenKind
    public let violations: [GitLabAuditViolation]
    public let targetProject: String?
    public let redactedToken: String?

    public init(
        passed: Bool,
        score: Double,
        instanceURL: String,
        tokenKind: GitLabTokenKind,
        violations: [GitLabAuditViolation],
        targetProject: String?,
        redactedToken: String?
    ) {
        self.passed = passed
        self.score = score
        self.instanceURL = instanceURL
        self.tokenKind = tokenKind
        self.violations = violations
        self.targetProject = targetProject
        self.redactedToken = redactedToken
    }
}

// MARK: - GitLab Integration Auditor

public enum GitLabIntegrationAuditor {

    public static let defaultGitLabURL = URL(string: "https://gitlab.com")!

    // MARK: - Audit Configuration

    public static func auditConfiguration(
        token: String,
        instanceURL: URL = defaultGitLabURL,
        project: GitLabProjectIdentifier? = nil
    ) -> GitLabAuditReport {
        var violations: [GitLabAuditViolation] = []
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenKind = GitLabTokenKind.detect(token: cleanToken)

        // 1. Token presence & length
        if cleanToken.isEmpty {
            violations.append(GitLabAuditViolation(
                code: "EMPTY_GITLAB_TOKEN",
                message: "GitLab access token or trigger token cannot be empty.",
                isFatal: true
            ))
        } else if cleanToken.count < 8 {
            violations.append(GitLabAuditViolation(
                code: "SUSPICIOUS_SHORT_TOKEN",
                message: "GitLab token is shorter than 8 characters, likely placeholder.",
                isFatal: true
            ))
        }

        // 2. Transport Protocol Security
        let scheme = instanceURL.scheme?.lowercased() ?? ""
        let host = instanceURL.host?.lowercased() ?? ""
        let isLocal = (host == "localhost" || host == "127.0.0.1" || host == "::1")

        if scheme != "https" && !isLocal {
            violations.append(GitLabAuditViolation(
                code: "INSECURE_HTTP_ENDPOINT",
                message: "Remote GitLab instances must use HTTPS transport security.",
                isFatal: true
            ))
        }

        // 3. Project identifier check
        if let proj = project, proj.rawIdentifier.isEmpty {
            violations.append(GitLabAuditViolation(
                code: "EMPTY_PROJECT_IDENTIFIER",
                message: "Target project identifier cannot be empty.",
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

        return GitLabAuditReport(
            passed: passed,
            score: finalScore,
            instanceURL: instanceURL.absoluteString,
            tokenKind: tokenKind,
            violations: violations,
            targetProject: project?.rawIdentifier,
            redactedToken: redacted
        )
    }

    // MARK: - Request Builders

    /// Builds a URLRequest for triggering a CI/CD pipeline via GitLab v4 API.
    public static func buildCreatePipelineRequest(
        instanceURL: URL = defaultGitLabURL,
        project: GitLabProjectIdentifier,
        triggerToken: String,
        payload: GitLabPipelineTriggerPayload
    ) -> URLRequest? {
        let cleanToken = triggerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, !payload.ref.isEmpty else { return nil }

        let endpoint = instanceURL
            .appendingPathComponent("api")
            .appendingPathComponent("v4")
            .appendingPathComponent("projects")
            .appendingPathComponent(project.rawIdentifier)
            .appendingPathComponent("trigger")
            .appendingPathComponent("pipeline")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        var bodyDict: [String: Any] = [
            "token": cleanToken,
            "ref": payload.ref
        ]
        if !payload.variables.isEmpty {
            bodyDict["variables"] = payload.variables
        }

        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    /// Builds a URLRequest for creating a note (comment) on a Merge Request.
    public static func buildCreateMergeRequestNoteRequest(
        instanceURL: URL = defaultGitLabURL,
        project: GitLabProjectIdentifier,
        mrIid: Int,
        token: String,
        body: String
    ) -> URLRequest? {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, mrIid > 0, !cleanBody.isEmpty else { return nil }

        let endpoint = instanceURL
            .appendingPathComponent("api")
            .appendingPathComponent("v4")
            .appendingPathComponent("projects")
            .appendingPathComponent(project.rawIdentifier)
            .appendingPathComponent("merge_requests")
            .appendingPathComponent("\(mrIid)")
            .appendingPathComponent("notes")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        let bodyDict: [String: Any] = ["body": cleanBody]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    /// Builds a URLRequest for fetching a CI Job's build trace (raw console log).
    public static func buildGetJobTraceRequest(
        instanceURL: URL = defaultGitLabURL,
        project: GitLabProjectIdentifier,
        jobId: Int,
        token: String
    ) -> URLRequest? {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty, jobId > 0 else { return nil }

        let endpoint = instanceURL
            .appendingPathComponent("api")
            .appendingPathComponent("v4")
            .appendingPathComponent("projects")
            .appendingPathComponent(project.rawIdentifier)
            .appendingPathComponent("jobs")
            .appendingPathComponent("\(jobId)")
            .appendingPathComponent("trace")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        req.setValue("text/plain", forHTTPHeaderField: "Accept")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")
        return req
    }

    // MARK: - Markdown Formatter

    public static func formatGitLabAuditReportMarkdown(_ report: GitLabAuditReport) -> String {
        var md = "### 🦊 GitLab API & CI/CD Telemetry Audit\n\n"
        md += "| Parameter | Value |\n"
        md += "|---|---|\n"
        md += "| **Status** | \(report.passed ? "✅ Compliant" : "❌ Non-Compliant") |\n"
        md += "| **Score** | `\(String(format: "%.1f", report.score))%` |\n"
        md += "| **Instance URL** | `\(report.instanceURL)` |\n"
        md += "| **Token Kind** | `\(report.tokenKind.rawValue)` |\n"
        md += "| **Target Project** | `\(report.targetProject ?? "None specified")` |\n"
        md += "| **Token Preview** | `\(report.redactedToken ?? "N/A")` |\n\n"

        if report.violations.isEmpty {
            md += "✨ **Zero violations found.** GitLab v4 REST integration configuration is fully secure.\n"
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
