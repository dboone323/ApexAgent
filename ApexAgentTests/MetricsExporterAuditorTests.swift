//
//  MetricsExporterAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 117: Prometheus/OpenMetrics Exposition & Datadog Metrics Exporter Auditor Tests.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 117 — Metrics Exporter, Prometheus & Datadog Auditor Tests")
struct MetricsExporterAuditorTests {

    @Test("Metric name validation enforces Prometheus identifier grammar")
    func testMetricNameValidation() {
        #expect(MetricsExporterAuditor.validateMetricName("apex_agent_turns_total"))
        #expect(MetricsExporterAuditor.validateMetricName("process:cpu:ratio"))
        #expect(MetricsExporterAuditor.validateMetricName("http_requests_duration_seconds"))

        // Rejections: starts with digit, contains hyphens or spaces
        #expect(!MetricsExporterAuditor.validateMetricName("123_invalid_start"))
        #expect(!MetricsExporterAuditor.validateMetricName("invalid-with-hyphens"))
        #expect(!MetricsExporterAuditor.validateMetricName("invalid with space"))
        #expect(!MetricsExporterAuditor.validateMetricName(""))
    }

    @Test("Label name validation enforces Prometheus label rules and blocks __ reserved prefixes")
    func testLabelNameValidation() {
        #expect(MetricsExporterAuditor.validateLabelName("env"))
        #expect(MetricsExporterAuditor.validateLabelName("subsystem_name"))

        // Rejections: __ reserved, begins with digit, contains hyphen
        #expect(!MetricsExporterAuditor.validateLabelName("__reserved_internal"))
        #expect(!MetricsExporterAuditor.validateLabelName("123label"))
        #expect(!MetricsExporterAuditor.validateLabelName("label-name"))
        #expect(!MetricsExporterAuditor.validateLabelName(""))
    }

    @Test("Valid metric series collection passes audit with 100% score")
    func testValidMetricSeriesAudit() {
        let sample1 = MetricSample(name: "apex_orchestrator_queue_depth", value: 3.0, labels: ["env": "prod", "cluster": "macos"])
        let sample2 = MetricSample(name: "apex_orchestrator_queue_depth", value: 0.0, labels: ["env": "staging", "cluster": "macos"])
        let series = MetricSeries(
            name: "apex_orchestrator_queue_depth",
            help: "Current count of active tasks queued in StateGraph.",
            type: .gauge,
            samples: [sample1, sample2]
        )

        let report = MetricsExporterAuditor.auditMetricSeries([series])
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.metricCount == 1)
        #expect(report.totalSamples == 2)
        #expect(report.violations.isEmpty)
    }

    @Test("Invalid metric name or CRLF in label values trip fatal violations")
    func testInvalidMetricNameAndLabelTripViolations() {
        let badSample = MetricSample(name: "bad-name", value: 1.0, labels: ["env": "prod\r\nINJECTION"])
        let series = MetricSeries(name: "bad-name", help: "Broken", type: .counter, samples: [badSample])

        let report = MetricsExporterAuditor.auditMetricSeries([series])
        #expect(!report.passed)
        #expect(report.violations.contains(where: { $0.code == "INVALID_METRIC_NAME" }))
        #expect(report.violations.contains(where: { $0.code == "CRLF_IN_LABEL_VALUE" }))
    }

    @Test("exportPrometheusExposition produces standard Prometheus plaintext output")
    func testExportPrometheusExposition() {
        let sample = MetricSample(
            name: "apex_agent_active_workers",
            value: 8.0,
            labels: ["pool": "primary", "role": "verifier"],
            timestampMilliseconds: 1728734400000
        )
        let series = MetricSeries(
            name: "apex_agent_active_workers",
            help: "Active autonomous worker bot count.",
            type: .gauge,
            samples: [sample]
        )

        let text = MetricsExporterAuditor.exportPrometheusExposition(series: [series])
        #expect(text.contains("# HELP apex_agent_active_workers Active autonomous worker bot count."))
        #expect(text.contains("# TYPE apex_agent_active_workers gauge"))
        #expect(text.contains("apex_agent_active_workers{pool=\"primary\",role=\"verifier\"} 8.0 1728734400000"))
    }

    @Test("buildDatadogSeriesRequest formats valid Series API v2 request")
    func testBuildDatadogSeriesRequest() throws {
        let pt = DatadogMetricPoint(timestamp: 1728734400, value: 99.5)
        let series = DatadogMetricSeries(
            metric: "apex.agent.uptime.percent",
            type: 1,
            points: [pt],
            tags: ["env:production", "service:apexagent"]
        )

        let req = MetricsExporterAuditor.buildDatadogSeriesRequest(
            apiKey: "dd_auditSampleKey123",
            series: [series],
            site: "datadoghq.com"
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.datadoghq.com/api/v2/series")
        #expect(request.value(forHTTPHeaderField: "DD-API-KEY") == "dd_auditSampleKey123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let seriesList = bodyJson?["series"] as? [[String: Any]]
        #expect(seriesList?.count == 1)
        #expect(seriesList?[0]["metric"] as? String == "apex.agent.uptime.percent")
        #expect(seriesList?[0]["type"] as? Int == 1)

        let points = seriesList?[0]["points"] as? [[String: Any]]
        #expect(points?[0]["value"] as? Double == 99.5)
    }

    @Test("formatMetricsAuditReportMarkdown renders markdown summary table")
    func testMarkdownFormatting() {
        let sample = MetricSample(name: "apex_mem_bytes", value: 1048576)
        let series = MetricSeries(name: "apex_mem_bytes", help: "Memory footprint", type: .gauge, samples: [sample])
        let report = MetricsExporterAuditor.auditMetricSeries([series])

        let md = MetricsExporterAuditor.formatMetricsAuditReportMarkdown(report)
        #expect(md.contains("Metrics Exporter & OpenMetrics Audit"))
        #expect(md.contains("✅ Compliant"))
        #expect(md.contains("100.0%"))
    }
}
