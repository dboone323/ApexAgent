//
//  IncidentManagementAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 118: PagerDuty Events API v2 Client & Opsgenie Incident Escalation Auditor Tests.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 118 — Incident Management & On-Call Dispatch Auditor Tests")
struct IncidentManagementAuditorTests {

    @Test("Valid PagerDuty routing key and HTTPS endpoint pass audit with 100% score")
    func testValidPagerDutyAudit() {
        let report = IncidentManagementAuditor.auditPagerDutyConfiguration(
            routingKey: "pd_auditKey_1234567890abcdef1234"
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.routingKeyConfigured)
        #expect(report.redactedKey?.contains("...") == true)
        #expect(report.violations.isEmpty)
    }

    @Test("Insecure HTTP transport and empty routing key trip fatal violations")
    func testInsecureAndEmptyKeyTripViolations() {
        let report = IncidentManagementAuditor.auditPagerDutyConfiguration(
            routingKey: "",
            endpointURL: URL(string: "http://events.pagerduty.com/v2/enqueue")!
        )

        #expect(!report.passed)
        #expect(report.violations.contains(where: { $0.code == "EMPTY_ROUTING_KEY" }))
        #expect(report.violations.contains(where: { $0.code == "INSECURE_PAGERDUTY_HTTP_ENDPOINT" }))
    }

    @Test("buildPagerDutyEventRequest formats valid Events API v2 JSON payload")
    func testBuildPagerDutyEventRequest() throws {
        let payload = PagerDutyEventPayload(
            eventAction: .trigger,
            summary: "Memory pressure exceeded 90% threshold in MLX worker",
            source: "macos-workstation-01",
            severity: .critical,
            dedupKey: "apexagent/oom/mlx/worker-4",
            component: "mlx-engine"
        )

        let req = IncidentManagementAuditor.buildPagerDutyEventRequest(
            routingKey: "pd_routing_test_key_12345678",
            payload: payload
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://events.pagerduty.com/v2/enqueue")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["routing_key"] as? String == "pd_routing_test_key_12345678")
        #expect(bodyJson?["event_action"] as? String == "trigger")
        #expect(bodyJson?["dedup_key"] as? String == "apexagent/oom/mlx/worker-4")

        let innerPayload = bodyJson?["payload"] as? [String: Any]
        #expect(innerPayload?["summary"] as? String == "Memory pressure exceeded 90% threshold in MLX worker")
        #expect(innerPayload?["source"] as? String == "macos-workstation-01")
        #expect(innerPayload?["severity"] as? String == "critical")
        #expect(innerPayload?["component"] as? String == "mlx-engine")
    }

    @Test("buildOpsgenieAlertRequest formats valid Opsgenie alert payload with GenieKey header")
    func testBuildOpsgenieAlertRequest() throws {
        let payload = OpsgenieAlertPayload(
            message: "Fatal security rule breach detected",
            alias: "security-gate-fail-pr18",
            description: "Detailed audit log of rejected network call.",
            priority: "P1",
            tags: ["security", "apexagent", "pre-push"],
            details: ["gate": "RepoHygieneAuditor", "loop": "14"]
        )

        let req = IncidentManagementAuditor.buildOpsgenieAlertRequest(
            apiKey: "genie_api_token_abc_123",
            payload: payload
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.opsgenie.com/v2/alerts")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "GenieKey genie_api_token_abc_123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["message"] as? String == "Fatal security rule breach detected")
        #expect(bodyJson?["priority"] as? String == "P1")
        #expect(bodyJson?["alias"] as? String == "security-gate-fail-pr18")
        let tags = bodyJson?["tags"] as? [String]
        #expect(tags == ["security", "apexagent", "pre-push"])
        let details = bodyJson?["details"] as? [String: String]
        #expect(details?["gate"] == "RepoHygieneAuditor")
    }

    @Test("formatIncidentAuditReportMarkdown renders markdown summary table")
    func testMarkdownFormatting() {
        let report = IncidentManagementAuditor.auditPagerDutyConfiguration(
            routingKey: "pd_auditKey_1234567890abcdef"
        )

        let md = IncidentManagementAuditor.formatIncidentAuditReportMarkdown(report)
        #expect(md.contains("Incident Management & On-Call Dispatch Audit"))
        #expect(md.contains("✅ Compliant"))
        #expect(md.contains("100.0%"))
    }
}
