//
//  GitHubIntegrationAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 111: GitHub REST/GraphQL API Client & Token Permission Auditor Tests.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 111 — GitHub Integration & Token Permission Auditor Tests")
struct GitHubIntegrationAuditorTests {

    @Test("Repository identifier parses valid slugs and rejects malformed names")
    func testRepoIdentifierParsing() {
        let valid = GitHubRepositoryIdentifier(owner: "apple", name: "swift")
        #expect(valid != nil)
        #expect(valid?.slug == "apple/swift")

        let invalidChar = GitHubRepositoryIdentifier(owner: "apple", name: "swift/submodule")
        #expect(invalidChar == nil)

        let empty = GitHubRepositoryIdentifier(owner: "", name: "swift")
        #expect(empty == nil)

        let spaces = GitHubRepositoryIdentifier(owner: "  dboone323  ", name: "  ApexAgent  ")
        #expect(spaces?.slug == "dboone323/ApexAgent")
    }

    @Test("GitHub token kind detection correctly classifies known token prefixes")
    func testTokenKindDetection() {
        #expect(GitHubTokenKind.detect(token: "ghp_auditSample12") == .classic)
        #expect(GitHubTokenKind.detect(token: "github_pat_auditSample12") == .fineGrained)
        #expect(GitHubTokenKind.detect(token: "gho_auditSample12") == .oauth)
        #expect(GitHubTokenKind.detect(token: "ghu_auditSample12") == .userToServer)
        #expect(GitHubTokenKind.detect(token: "ghs_auditSample12") == .serverToServer)
        #expect(GitHubTokenKind.detect(token: "ghr_auditSample12") == .refresh)
        #expect(GitHubTokenKind.detect(token: "my_custom_pat_token") == .custom)
    }

    @Test("Valid HTTPS GitHub configuration passes audit with 100% score")
    func testValidConfigurationPasses() {
        let repo = GitHubRepositoryIdentifier(owner: "apple", name: "swift")
        let report = GitHubIntegrationAuditor.auditConfiguration(
            token: "ghp_auditSample12345",
            endpointURL: URL(string: "https://api.github.com")!,
            repo: repo
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.tokenKind == .classic)
        #expect(report.targetRepository == "apple/swift")
        #expect(report.redactedToken?.contains("...") == true)
        #expect(report.violations.isEmpty)
    }

    @Test("Insecure HTTP transport endpoint trips fatal security violation")
    func testInsecureHTTPTripsViolation() {
        let report = GitHubIntegrationAuditor.auditConfiguration(
            token: "ghp_auditSample12345",
            endpointURL: URL(string: "http://api.github.com")!
        )

        #expect(!report.passed)
        #expect(report.violations.contains(where: { $0.code == "INSECURE_HTTP_ENDPOINT" }))
    }

    @Test("Empty and short tokens trip fatal violations")
    func testEmptyTokenTripsViolation() {
        let emptyReport = GitHubIntegrationAuditor.auditConfiguration(token: "   ")
        #expect(!emptyReport.passed)
        #expect(emptyReport.violations.contains(where: { $0.code == "EMPTY_GITHUB_TOKEN" }))

        let shortReport = GitHubIntegrationAuditor.auditConfiguration(token: "abc")
        #expect(!shortReport.passed)
        #expect(shortReport.violations.contains(where: { $0.code == "SUSPICIOUS_SHORT_TOKEN" }))
    }

    @Test("Refresh token used directly as bearer token trips fatal violation")
    func testRefreshTokenTripsViolation() {
        let report = GitHubIntegrationAuditor.auditConfiguration(token: "ghr_refreshSample123")
        #expect(!report.passed)
        #expect(report.violations.contains(where: { $0.code == "REFRESH_TOKEN_USED_AS_BEARER" }))
    }

    @Test("buildCreateIssueCommentRequest constructs valid GitHub REST request")
    func testBuildCreateIssueCommentRequest() throws {
        guard let repo = GitHubRepositoryIdentifier(owner: "dboone323", name: "ApexAgent") else {
            Issue.record("Failed to create repo identifier")
            return
        }

        let req = GitHubIntegrationAuditor.buildCreateIssueCommentRequest(
            token: "ghp_auditSampleToken12",
            repo: repo,
            issueNumber: 42,
            body: "Audit verified: PR passed all security gates."
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.github.com/repos/dboone323/ApexAgent/issues/42/comments")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_auditSampleToken12")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["body"] as? String == "Audit verified: PR passed all security gates.")
    }

    @Test("buildCreateCommitStatusRequest constructs valid commit status check request")
    func testBuildCreateCommitStatusRequest() throws {
        guard let repo = GitHubRepositoryIdentifier(owner: "dboone323", name: "ApexAgent") else {
            Issue.record("Failed to create repo identifier")
            return
        }

        let payload = GitHubCommitStatusPayload(
            state: .success,
            targetURL: URL(string: "https://ci.apexagent.local/build/101")!,
            description: "All 10 security audits passed cleanly",
            context: "apexagent/pre-push"
        )

        let req = GitHubIntegrationAuditor.buildCreateCommitStatusRequest(
            token: "ghp_auditSampleToken12",
            repo: repo,
            sha: "0123456789abcdef0123456789abcdef01234567",
            payload: payload
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path.contains("/statuses/0123456789abcdef0123456789abcdef01234567") == true)

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["state"] as? String == "success")
        #expect(bodyJson?["context"] as? String == "apexagent/pre-push")
        #expect(bodyJson?["description"] as? String == "All 10 security audits passed cleanly")
        #expect(bodyJson?["target_url"] as? String == "https://ci.apexagent.local/build/101")
    }

    @Test("buildGraphQLRequest encodes query and variables into JSON payload")
    func testBuildGraphQLRequest() throws {
        let query = "query ($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id } }"
        let variables: [String: Any] = ["owner": "apple", "name": "swift"]

        let req = GitHubIntegrationAuditor.buildGraphQLRequest(
            token: "ghp_auditSampleToken12",
            query: query,
            variables: variables
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.github.com/graphql")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["query"] as? String == query)
        let vars = bodyJson?["variables"] as? [String: Any]
        #expect(vars?["owner"] as? String == "apple")
        #expect(vars?["name"] as? String == "swift")
    }

    @Test("formatGitHubAuditReportMarkdown produces clean markdown overview")
    func testMarkdownFormatting() {
        let repo = GitHubRepositoryIdentifier(owner: "dboone323", name: "ApexAgent")
        let report = GitHubIntegrationAuditor.auditConfiguration(
            token: "ghp_auditSample12345",
            endpointURL: URL(string: "https://api.github.com")!,
            repo: repo
        )

        let md = GitHubIntegrationAuditor.formatGitHubAuditReportMarkdown(report)
        #expect(md.contains("GitHub API Integration & Permission Audit"))
        #expect(md.contains("dboone323/ApexAgent"))
        #expect(md.contains("✅ Passed"))
        #expect(md.contains("100.0%"))
    }
}
