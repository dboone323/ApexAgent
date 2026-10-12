//
//  GitLabIntegrationAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 113: GitLab API Client & CI/CD Pipeline Telemetry Auditor Tests.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 113 — GitLab Integration & CI Telemetry Auditor Tests")
struct GitLabIntegrationAuditorTests {

    @Test("GitLabProjectIdentifier encodes numeric IDs and URL-encodes group/repo paths")
    func testProjectIdentifierParsing() {
        let numeric = GitLabProjectIdentifier(id: 1337)
        #expect(numeric?.rawIdentifier == "1337")

        let path = GitLabProjectIdentifier(path: "gitlab-org/gitlab")
        #expect(path?.rawIdentifier == "gitlab-org%2Fgitlab")

        let alreadyEncoded = GitLabProjectIdentifier(path: "apex%2Fagent")
        #expect(alreadyEncoded?.rawIdentifier == "apex%2Fagent")

        let invalid = GitLabProjectIdentifier(path: "   ")
        #expect(invalid == nil)
    }

    @Test("GitLabTokenKind detects personal, trigger, and job token prefixes")
    func testTokenKindDetection() {
        #expect(GitLabTokenKind.detect(token: "glpat-auditSample12") == .personalAccessToken)
        #expect(GitLabTokenKind.detect(token: "glcbt-auditSample12") == .pipelineTriggerToken)
        #expect(GitLabTokenKind.detect(token: "gljob-auditSample12") == .jobToken)
        #expect(GitLabTokenKind.detect(token: "custom_bearer_token") == .custom)
    }

    @Test("Valid HTTPS GitLab configuration passes audit with 100% score")
    func testValidConfigurationPasses() {
        let proj = GitLabProjectIdentifier(id: 42)
        let report = GitLabIntegrationAuditor.auditConfiguration(
            token: "glpat-auditSample12345",
            instanceURL: URL(string: "https://gitlab.com")!,
            project: proj
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.tokenKind == .personalAccessToken)
        #expect(report.targetProject == "42")
        #expect(report.violations.isEmpty)
        #expect(report.redactedToken?.contains("...") == true)
    }

    @Test("Insecure HTTP GitLab instance trips fatal security violation")
    func testInsecureHTTPTripsViolation() {
        let report = GitLabIntegrationAuditor.auditConfiguration(
            token: "glpat-auditSample12345",
            instanceURL: URL(string: "http://gitlab.internal.net")!
        )

        #expect(!report.passed)
        #expect(report.violations.contains(where: { $0.code == "INSECURE_HTTP_ENDPOINT" }))
    }

    @Test("buildCreatePipelineRequest generates valid pipeline trigger request")
    func testBuildCreatePipelineRequest() throws {
        let proj = try #require(GitLabProjectIdentifier(id: 99))
        let payload = GitLabPipelineTriggerPayload(
            ref: "release/v2.0",
            variables: ["DEPLOY_ENV": "staging", "RUN_AUDIT": "true"]
        )

        let req = GitLabIntegrationAuditor.buildCreatePipelineRequest(
            instanceURL: URL(string: "https://gitlab.example.com")!,
            project: proj,
            triggerToken: "glcbt-triggerToken123",
            payload: payload
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://gitlab.example.com/api/v4/projects/99/trigger/pipeline")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["token"] as? String == "glcbt-triggerToken123")
        #expect(bodyJson?["ref"] as? String == "release/v2.0")
        let vars = bodyJson?["variables"] as? [String: String]
        #expect(vars?["DEPLOY_ENV"] == "staging")
        #expect(vars?["RUN_AUDIT"] == "true")
    }

    @Test("buildCreateMergeRequestNoteRequest constructs valid MR comment request")
    func testBuildCreateMergeRequestNoteRequest() throws {
        let proj = try #require(GitLabProjectIdentifier(path: "apex/agent"))
        let req = GitLabIntegrationAuditor.buildCreateMergeRequestNoteRequest(
            instanceURL: URL(string: "https://gitlab.com")!,
            project: proj,
            mrIid: 17,
            token: "glpat-auditSample12345",
            body: "ApexAgent verified: Loop 14 pipeline checks passed."
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path.contains("/projects/apex%2Fagent/merge_requests/17/notes") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer glpat-auditSample12345")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["body"] as? String == "ApexAgent verified: Loop 14 pipeline checks passed.")
    }

    @Test("buildGetJobTraceRequest constructs valid raw log request")
    func testBuildGetJobTraceRequest() throws {
        let proj = try #require(GitLabProjectIdentifier(id: 42))
        let req = GitLabIntegrationAuditor.buildGetJobTraceRequest(
            instanceURL: URL(string: "https://gitlab.com")!,
            project: proj,
            jobId: 1024,
            token: "glpat-auditSample12345"
        )

        let request = try #require(req)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://gitlab.com/api/v4/projects/42/jobs/1024/trace")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/plain")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer glpat-auditSample12345")
    }

    @Test("formatGitLabAuditReportMarkdown formats markdown summary table")
    func testMarkdownFormatting() {
        let proj = GitLabProjectIdentifier(path: "apple/swift")
        let report = GitLabIntegrationAuditor.auditConfiguration(
            token: "glpat-auditSample12345",
            instanceURL: URL(string: "https://gitlab.com")!,
            project: proj
        )

        let md = GitLabIntegrationAuditor.formatGitLabAuditReportMarkdown(report)
        #expect(md.contains("GitLab API & CI/CD Telemetry Audit"))
        #expect(md.contains("apple%2Fswift"))
        #expect(md.contains("personal_access_token"))
        #expect(md.contains("✅ Compliant"))
    }
}
