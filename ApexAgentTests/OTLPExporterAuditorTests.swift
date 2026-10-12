//
//  OTLPExporterAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 109: OpenTelemetry Trace Exporter & Attribute Sanitizer Tests.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 109 — OpenTelemetry (OTLP) Exporter & Attribute Sanitizer Tests")
struct OTLPExporterAuditorTests {

    private let validTraceId = "4bf92f3577b34da6a3ce929d0e0e4736"
    private let validSpanId = "00f067aa0ba902b7"

    @Test("Valid OTLP spans and HTTPS endpoint pass audit with 100% compliance")
    func testValidOTLPExportPasses() {
        let config = OTLPExporterConfig(
            endpointURL: URL(string: "https://api.honeycomb.io/v1/traces")!,
            headers: ["x-honeycomb-team": "test-dataset-api-key"]
        )

        let span = OTLPTraceSpan(
            traceId: validTraceId,
            spanId: validSpanId,
            name: "agent.execute_tool",
            startTimeUnixNano: 1700000000000000000,
            endTimeUnixNano: 1700000000500000000,
            attributes: [
                OTLPSpanAttribute(key: "tool.name", value: "web_search"),
                OTLPSpanAttribute(key: "tool.duration_ms", value: "500")
            ]
        )

        let report = OTLPExporterAuditor.audit(config: config, spans: [span])

        #expect(report.isCompliant)
        #expect(report.piiClean)
        #expect(report.securityScore >= 0.95)
        #expect(report.violations.isEmpty)
        #expect(report.spansEvaluated == 1)
    }

    @Test("Insecure remote HTTP collector trips fatal violation")
    func testInsecureEndpointTripsFatal() {
        let config = OTLPExporterConfig(
            endpointURL: URL(string: "http://otlp.remote-collector.com/v1/traces")!
        )
        let report = OTLPExporterAuditor.audit(config: config, spans: [])

        #expect(!report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "INSECURE_OTLP_ENDPOINT" && $0.isFatal }))
    }

    @Test("Localhost HTTP endpoint permitted for local OpenTelemetry daemon")
    func testLocalhostCollectorPermitted() {
        let config = OTLPExporterConfig(
            endpointURL: URL(string: "http://127.0.0.1:4318/v1/traces")!
        )
        let report = OTLPExporterAuditor.audit(config: config, spans: [])

        #expect(report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "LOCAL_COLLECTOR_HTTP_ALLOWED" && !$0.isFatal }))
    }

    @Test("W3C TraceId and SpanId validators reject non-hex and incorrect lengths")
    func testTraceIdAndSpanIdValidation() {
        #expect(OTLPExporterAuditor.isValidTraceId(validTraceId))
        #expect(OTLPExporterAuditor.isValidSpanId(validSpanId))

        #expect(!OTLPExporterAuditor.isValidTraceId("too-short"))
        #expect(!OTLPExporterAuditor.isValidTraceId(String(repeating: "0", count: 32))) // all zeroes is invalid
        #expect(!OTLPExporterAuditor.isValidTraceId("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")) // non-hex
        #expect(!OTLPExporterAuditor.isValidSpanId("short"))
    }

    @Test("Inverted timestamps trip fatal violation")
    func testInvertedTimestampsTripsFatal() {
        let config = OTLPExporterConfig()
        let invertedSpan = OTLPTraceSpan(
            traceId: validTraceId,
            spanId: validSpanId,
            name: "invalid.time",
            startTimeUnixNano: 2000,
            endTimeUnixNano: 1000 // Inverted!
        )

        let report = OTLPExporterAuditor.audit(config: config, spans: [invertedSpan])
        #expect(!report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "INVERTED_SPAN_TIMESTAMPS" && $0.isFatal }))
    }

    @Test("Attribute sanitizer redacts sensitive API keys and authorization headers")
    func testAttributeSanitizerRedactsSecrets() {
        let dirtyAttributes = [
            OTLPSpanAttribute(key: "http.request.header.authorization", value: "Bearer sk-12345"),
            OTLPSpanAttribute(key: "openai.api_key", value: "sk-secret-key-123"),
            OTLPSpanAttribute(key: "user.role", value: "admin")
        ]

        let cleanAttributes = OTLPExporterAuditor.sanitizeAttributes(dirtyAttributes)

        #expect(cleanAttributes[0].value == "[REDACTED_BY_APEX_GATE]")
        #expect(cleanAttributes[1].value == "[REDACTED_BY_APEX_GATE]")
        #expect(cleanAttributes[2].value == "admin")
    }

    @Test("OTLPTracePayloadBuilder produces compliant JSON dictionary and serialized data")
    func testPayloadSerialization() {
        let span = OTLPTraceSpan(
            traceId: validTraceId,
            spanId: validSpanId,
            name: "test.span",
            startTimeUnixNano: 1000,
            endTimeUnixNano: 2000,
            attributes: [OTLPSpanAttribute(key: "test", value: "value")]
        )

        let dict = OTLPTracePayloadBuilder.buildPayload(spans: [span])
        guard let resourceSpans = dict["resourceSpans"] as? [[String: Any]],
              let firstRes = resourceSpans.first,
              let scopeSpans = firstRes["scopeSpans"] as? [[String: Any]],
              let firstScope = scopeSpans.first,
              let spans = firstScope["spans"] as? [[String: Any]] else {
            Issue.record("Malformed OTLP JSON dictionary")
            return
        }

        #expect(spans.count == 1)
        #expect(spans.first?["traceId"] as? String == validTraceId)

        let jsonData = OTLPTracePayloadBuilder.serializePayloadJSON(spans: [span])
        #expect(jsonData != nil)
        #expect((jsonData?.count ?? 0) > 100)
    }

    @Test("formatOTLPReportMarkdown formats markdown report table")
    func testMarkdownFormatting() {
        let report = OTLPAuditReport(
            endpointURL: "https://api.honeycomb.io/v1/traces",
            spansEvaluated: 12,
            isCompliant: true,
            piiClean: true,
            securityScore: 1.0,
            violations: []
        )
        let md = OTLPExporterAuditor.formatOTLPReportMarkdown(report)
        #expect(md.contains("### 📡 OpenTelemetry (OTLP) Exporter & Telemetry Audit"))
        #expect(md.contains("api.honeycomb.io"))
        #expect(md.contains("12"))
        #expect(md.contains("100%"))
    }
}
