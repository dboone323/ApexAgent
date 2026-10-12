//
//  JiraIntegrationAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 112: Jira & Atlassian Document Format (ADF) Parser & Webhook Auditor Tests.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 112 — Jira Integration & ADF Document Builder Tests")
struct JiraIntegrationAuditorTests {

    @Test("Valid Atlassian Cloud domain, user email and API token pass audit")
    func testValidJiraConfigurationPasses() {
        let report = JiraIntegrationAuditor.auditConfiguration(
            domain: "mycompany.atlassian.net",
            userEmail: "developer@mycompany.com",
            apiToken: "jira_audit_tok_12345"
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.domain == "mycompany.atlassian.net")
        #expect(report.userEmail == "developer@mycompany.com")
        #expect(report.redactedToken?.contains("...") == true)
        #expect(report.violations.isEmpty)
    }

    @Test("Invalid email and empty token trip fatal audit violations")
    func testInvalidEmailAndTokenTripViolations() {
        let report = JiraIntegrationAuditor.auditConfiguration(
            domain: "company.atlassian.net",
            userEmail: "invalid-email-no-at-sign",
            apiToken: ""
        )

        #expect(!report.passed)
        #expect(report.violations.contains(where: { $0.code == "INVALID_EMAIL_FORMAT" }))
        #expect(report.violations.contains(where: { $0.code == "EMPTY_API_TOKEN" }))
    }

    @Test("buildBasicAuthHeader creates RFC 7617 compliant Basic authorization header")
    func testBasicAuthHeaderGeneration() {
        let header = JiraIntegrationAuditor.buildBasicAuthHeader(
            userEmail: "user@test.org",
            apiToken: "secretToken123"
        )

        #expect(header.hasPrefix("Basic "))
        let base64 = String(header.dropFirst(6))
        let decodedData = Data(base64Encoded: base64)
        #expect(decodedData != nil)
        let decodedString = String(data: decodedData!, encoding: .utf8)
        #expect(decodedString == "user@test.org:secretToken123")
    }

    @Test("buildADFDocument parses markdown headers, lists, and paragraphs into valid ADF nodes")
    func testADFDocumentBuilder() {
        let md = """
        # Main Title
        ### Subheading Level 3
        - First bullet item
        - Second bullet item
        Regular body paragraph with details.
        """

        let doc = JiraIntegrationAuditor.buildADFDocument(markdown: md)
        #expect(doc["version"] as? Int == 1)
        #expect(doc["type"] as? String == "doc")

        guard let content = doc["content"] as? [[String: Any]] else {
            Issue.record("Missing content array in ADF doc")
            return
        }

        #expect(content.count >= 4)
        #expect(content[0]["type"] as? String == "heading")
        let h1Attrs = content[0]["attrs"] as? [String: Any]
        #expect(h1Attrs?["level"] as? Int == 1)

        #expect(content[1]["type"] as? String == "heading")
        let h3Attrs = content[1]["attrs"] as? [String: Any]
        #expect(h3Attrs?["level"] as? Int == 3)

        #expect(content[2]["type"] as? String == "bulletList")
    }

    @Test("buildCreateIssueRequest constructs valid REST API v3 request with ADF description")
    func testBuildCreateIssueRequest() throws {
        let payload = JiraIssueCreatePayload(
            projectKey: "APEX",
            summary: "Implement Cloudflare R2 backup gate",
            issueType: "Task",
            descriptionMarkdown: "### Acceptance Criteria\n- Zero leaks\n- 100% tests pass",
            labels: ["backend", "audit", "security"],
            priority: "High"
        )

        let req = JiraIntegrationAuditor.buildCreateIssueRequest(
            domain: "apexagent.atlassian.net",
            userEmail: "bot@apexagent.com",
            apiToken: "jira_audit_tok_12345",
            payload: payload
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://apexagent.atlassian.net/rest/api/3/issue")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let fields = bodyJson?["fields"] as? [String: Any]

        let project = fields?["project"] as? [String: String]
        #expect(project?["key"] == "APEX")
        #expect(fields?["summary"] as? String == "Implement Cloudflare R2 backup gate")

        let desc = fields?["description"] as? [String: Any]
        #expect(desc?["version"] as? Int == 1)
        #expect(desc?["type"] as? String == "doc")

        let labels = fields?["labels"] as? [String]
        #expect(labels == ["backend", "audit", "security"])
    }

    @Test("buildIssueTransitionRequest constructs valid status transition request")
    func testBuildIssueTransitionRequest() throws {
        let req = JiraIntegrationAuditor.buildIssueTransitionRequest(
            domain: "apexagent.atlassian.net",
            userEmail: "bot@apexagent.com",
            apiToken: "jira_audit_tok_12345",
            issueKey: "APEX-42",
            transitionId: "31"
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://apexagent.atlassian.net/rest/api/3/issue/APEX-42/transitions")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let trans = bodyJson?["transition"] as? [String: String]
        #expect(trans?["id"] == "31")
    }

    @Test("formatJiraAuditReportMarkdown renders markdown summary table")
    func testMarkdownReport() {
        let report = JiraIntegrationAuditor.auditConfiguration(
            domain: "myorg.atlassian.net",
            userEmail: "lead@myorg.com",
            apiToken: "jira_audit_tok_12345"
        )

        let md = JiraIntegrationAuditor.formatJiraAuditReportMarkdown(report)
        #expect(md.contains("Atlassian Jira Cloud Integration Audit"))
        #expect(md.contains("myorg.atlassian.net"))
        #expect(md.contains("lead@myorg.com"))
        #expect(md.contains("✅ Compliant"))
    }
}
