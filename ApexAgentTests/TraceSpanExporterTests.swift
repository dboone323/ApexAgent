import Foundation
import Testing
@testable import ApexAgentCore

@Suite("TraceSpanExporter Tests (Batch 51)")
struct TraceSpanExporterTests {

    @Test("Converts TraceEvents into OpenTelemetry Spans and validates OTLP JSON")
    func convertsTraceEventsToOTelSpans() throws {
        let trace = W3CTraceContext.generate()
        let event1 = TraceEvent(
            source: "MCPClient",
            operation: "callTool",
            detail: "execute bash command",
            durationMs: 45.0,
            metadata: ["traceparent": trace.traceparent]
        )
        let event2 = TraceEvent(
            source: "ContainerManager",
            operation: "startMicroVM",
            detail: "boot alpine container",
            durationMs: 120.0,
            metadata: [
                "traceparent": trace.traceparent,
                "parentSpanId": trace.spanId
            ]
        )

        let report = TraceSpanExporter.export(events: [event1, event2])
        #expect(report.passed)
        #expect(report.totalSpans == 2)
        #expect(report.validHierarchySpans == 2)
        #expect(report.spans[0].traceId == trace.traceId)
        #expect(report.spans[1].parentSpanId == trace.spanId)

        let otlpJSON = report.toOTLPJSON()
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(otlpJSON.utf8)) as? [String: Any])
        let resourceSpans = try #require(parsed["resourceSpans"] as? [[String: Any]])
        #expect(resourceSpans.count == 1)
        #expect(report.toMarkdown().contains("Distributed Trace & OTel Export (`PASS`)"))
    }

    @Test("Detects malformed parent span identifiers in trace hierarchy")
    func detectsMalformedParentSpanId() {
        let event = TraceEvent(
            source: "AgentOrchestrator",
            operation: "dispatch",
            detail: "",
            durationMs: 10.0,
            metadata: ["parentSpanId": "invalid-short"]
        )

        let report = TraceSpanExporter.export(events: [event])
        #expect(!report.passed)
        #expect(report.findings.count == 1)
        #expect(report.findings[0].contains("malformed parentSpanId"))
    }
}
