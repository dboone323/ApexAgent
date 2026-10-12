//
//  LinearIntegrationAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 104: Linear Project Management Integration Tests.
//

import Testing
import Foundation
import CryptoKit
@testable import ApexAgentCore

@Suite("Batch 104 — Linear Integration & GraphQL Security Auditor Tests")
struct LinearIntegrationAuditorTests {

    private let testWebhookSecret = "linear_whsec_sample_secret_key_12345"

    private func generateSignature(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    @Test("Valid Linear configuration passes audit with 100% score")
    func testValidLinearConfigPasses() {
        let config = LinearClientConfiguration(
            endpointURL: URL(string: "https://api.linear.app/graphql")!,
            apiToken: "lin_api_sample_token_production_998877",
            webhookSigningSecret: testWebhookSecret
        )

        let report = LinearIntegrationAuditor.auditConfiguration(config)

        #expect(report.isCompliant)
        #expect(report.securityScore >= 0.95)
        #expect(report.hasToken)
        #expect(report.hasWebhookSecret)
        #expect(report.violations.isEmpty)
    }

    @Test("Insecure HTTP endpoint and missing token trip fatal violations")
    func testInsecureEndpointAndMissingToken() {
        let config = LinearClientConfiguration(
            endpointURL: URL(string: "http://api.linear.app/graphql")!,
            apiToken: "",
            webhookSigningSecret: nil
        )

        let report = LinearIntegrationAuditor.auditConfiguration(config)

        #expect(!report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "INSECURE_GRAPHQL_ENDPOINT" && $0.isFatal }))
        #expect(report.violations.contains(where: { $0.code == "MISSING_LINEAR_TOKEN" && $0.isFatal }))
        #expect(report.violations.contains(where: { $0.code == "MISSING_WEBHOOK_SECRET" && !$0.isFatal }))
    }

    @Test("Linear webhook signature verification succeeds with correct HMAC-SHA256")
    func testWebhookSignatureVerification() {
        let payload = "{\"action\":\"create\",\"type\":\"Issue\",\"data\":{\"id\":\"iss_1\"}}"
        let bodyData = Data(payload.utf8)
        let sig = generateSignature(body: bodyData, secret: testWebhookSecret)

        let (valid, reason) = LinearWebhookSignatureVerifier.verify(
            signatureHeader: sig,
            rawBody: bodyData,
            signingSecret: testWebhookSecret
        )

        #expect(valid)
        #expect(reason == nil)
    }

    @Test("Tampered webhook body fails signature verification")
    func testTamperedWebhookFails() {
        let originalData = Data("{\"id\":\"1\"}".utf8)
        let tamperedData = Data("{\"id\":\"2\"}".utf8)
        let sig = generateSignature(body: originalData, secret: testWebhookSecret)

        let (valid, reason) = LinearWebhookSignatureVerifier.verify(
            signatureHeader: sig,
            rawBody: tamperedData,
            signingSecret: testWebhookSecret
        )

        #expect(!valid)
        #expect(reason != nil)
    }

    @Test("GraphQL query builders produce valid queries and serialized payloads")
    func testGraphQLQueryBuilders() {
        let viewer = LinearGraphQLBuilder.buildViewerQuery()
        #expect(viewer.query.contains("query Viewer"))
        let viewerData = viewer.toJSONData()
        #expect(viewerData != nil)

        let teamQuery = LinearGraphQLBuilder.buildIssuesQuery(teamId: "team-eng", first: 15)
        #expect(teamQuery.variables["teamId"] == "team-eng")
        #expect(teamQuery.variables["first"] == "15")

        let draft = LinearIssueDraft(
            title: "Fix memory leak in websocket proxy",
            description: "Observed spike in memory",
            teamId: "team-eng",
            priority: 1
        )
        let mutation = LinearGraphQLBuilder.buildCreateIssueMutation(draft: draft)
        #expect(mutation.query.contains("mutation CreateIssue"))
        #expect(mutation.variables["title"] == "Fix memory leak in websocket proxy")
        #expect(mutation.variables["priority"] == "1")
    }

    @Test("Query auditor flags suspicious comments and SQL/injection syntax")
    func testQueryAuditorFlagsInjection() {
        let cleanQuery = "query { viewer { id } }"
        #expect(LinearIntegrationAuditor.auditGraphQLQuery(cleanQuery).isEmpty)

        let maliciousQuery = "query { viewer { id } } -- drop table users"
        let violations = LinearIntegrationAuditor.auditGraphQLQuery(maliciousQuery)
        #expect(violations.contains(where: { $0.code == "SUSPICIOUS_QUERY_SYNTAX" && $0.isFatal }))
    }

    @Test("formatLinearAuditReportMarkdown produces complete markdown table")
    func testMarkdownFormatting() {
        let report = LinearAuditReport(
            endpointURL: "https://api.linear.app/graphql",
            hasToken: true,
            hasWebhookSecret: true,
            isCompliant: true,
            securityScore: 1.0,
            violations: []
        )
        let md = LinearIntegrationAuditor.formatLinearAuditReportMarkdown(report)
        #expect(md.contains("### 📐 Linear Integration & GraphQL Security Audit"))
        #expect(md.contains("100%"))
        #expect(md.contains("api.linear.app/graphql"))
    }
}
