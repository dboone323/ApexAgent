import Foundation

// MARK: - OpenTelemetry & W3C Trace Context Exporter (Batch 51)

/// An OpenTelemetry-compatible Span representation for distributed tracing.
public struct OTelSpan: Sendable, Equatable, Codable {
    public let traceId: String
    public let spanId: String
    public let parentSpanId: String?
    public let name: String
    public let kind: String
    public let startTimeUnixNano: UInt64
    public let endTimeUnixNano: UInt64
    public let attributes: [String: String]
    public let statusCode: String
    public let statusMessage: String?

    public init(
        traceId: String,
        spanId: String,
        parentSpanId: String? = nil,
        name: String,
        kind: String = "INTERNAL",
        startTimeUnixNano: UInt64,
        endTimeUnixNano: UInt64,
        attributes: [String: String] = [:],
        statusCode: String = "OK",
        statusMessage: String? = nil
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.name = name
        self.kind = kind
        self.startTimeUnixNano = startTimeUnixNano
        self.endTimeUnixNano = endTimeUnixNano
        self.attributes = attributes
        self.statusCode = statusCode
        self.statusMessage = statusMessage
    }
}

/// Aggregated export bundle for traces.
public struct TraceExportReport: Sendable, Equatable, Codable {
    public let passed: Bool
    public let totalSpans: Int
    public let validHierarchySpans: Int
    public let spans: [OTelSpan]
    public let findings: [String]

    public init(
        passed: Bool,
        totalSpans: Int,
        validHierarchySpans: Int,
        spans: [OTelSpan],
        findings: [String]
    ) {
        self.passed = passed
        self.totalSpans = totalSpans
        self.validHierarchySpans = validHierarchySpans
        self.spans = spans
        self.findings = findings
    }

    /// Serializes to OpenTelemetry OTLP JSON format.
    public func toOTLPJSON() -> String {
        let spanDicts: [[String: Any]] = spans.map { span in
            var dict: [String: Any] = [
                "traceId": span.traceId,
                "spanId": span.spanId,
                "name": span.name,
                "kind": span.kind,
                "startTimeUnixNano": "\(span.startTimeUnixNano)",
                "endTimeUnixNano": "\(span.endTimeUnixNano)",
                "attributes": span.attributes.map { ["key": $0.key, "value": ["stringValue": $0.value]] },
                "status": ["code": span.statusCode]
            ]
            if let parent = span.parentSpanId {
                dict["parentSpanId"] = parent
            }
            if let msg = span.statusMessage {
                dict["status"] = ["code": span.statusCode, "message": msg]
            }
            return dict
        }

        let otlp: [String: Any] = [
            "resourceSpans": [
                [
                    "resource": [
                        "attributes": [
                            ["key": "service.name", "value": ["stringValue": "ApexAgent"]],
                            ["key": "service.version", "value": ["stringValue": ApexCLIRouter.appVersion]]
                        ]
                    ],
                    "scopeSpans": [
                        [
                            "scope": ["name": "com.apexagent.tracing"],
                            "spans": spanDicts
                        ]
                    ]
                ]
            ]
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: otlp,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Distributed Trace & OTel Export (`\(badge)`)",
            "",
            "- **Total Spans**: `\(totalSpans)`",
            "- **Valid Hierarchy Spans**: `\(validHierarchySpans)`",
            "",
            "| Name | Trace ID | Span ID | Parent ID | Status | Duration (ns) |",
            "| :--- | :--- | :--- | :--- | :---: | :---: |"
        ]
        for s in spans.prefix(20) {
            let parent = s.parentSpanId ?? "root"
            let dur = s.endTimeUnixNano >= s.startTimeUnixNano ? s.endTimeUnixNano - s.startTimeUnixNano : 0
            lines.append("| `\(s.name)` | `\(s.traceId.prefix(8))...` | `\(s.spanId)` | `\(parent)` | \(s.statusCode) | \(dur) |")
        }
        if !findings.isEmpty {
            lines.append("")
            lines.append("### Findings")
            for f in findings {
                lines.append("- \(f)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum TraceSpanExporter {
    /// Converts a collection of `TraceEvent` objects into `OTelSpan` instances.
    public static func export(events: [TraceEvent]) -> TraceExportReport {
        var spans: [OTelSpan] = []
        var findings: [String] = []

        for event in events {
            let traceCtx: W3CTraceContext
            if let tp = event.metadata?["traceparent"], let parsed = W3CTraceContext.parse(tp) {
                traceCtx = parsed
            } else {
                traceCtx = W3CTraceContext.generate()
            }

            let startNano = UInt64(event.timestamp.timeIntervalSince1970 * 1_000_000_000)
            let durationNano = UInt64((event.durationMs ?? 0.0) * 1_000_000)
            let endNano = startNano + max(durationNano, 1000)

            var attrs: [String: String] = [
                "apex.source": event.source,
                "apex.operation": event.operation
            ]
            if !event.detail.isEmpty {
                attrs["apex.detail"] = event.detail
            }
            if let meta = event.metadata {
                for (k, v) in meta where k != "traceparent" {
                    attrs[k] = v
                }
            }

            let parentSpan = event.metadata?["parentSpanId"]

            let status = event.isSlow ? "SLOW" : "OK"
            spans.append(
                OTelSpan(
                    traceId: traceCtx.traceId,
                    spanId: traceCtx.spanId,
                    parentSpanId: parentSpan,
                    name: event.operation,
                    kind: "INTERNAL",
                    startTimeUnixNano: startNano,
                    endTimeUnixNano: endNano,
                    attributes: attrs,
                    statusCode: status
                )
            )
        }

        // Validate hierarchy: If parentSpanId is present, ensure it has valid 16-hex length
        var validHierarchy = 0
        for span in spans {
            if let parent = span.parentSpanId {
                if parent.count == 16 {
                    validHierarchy += 1
                } else {
                    findings.append("Span '\(span.name)' has malformed parentSpanId '\(parent)'.")
                }
            } else {
                validHierarchy += 1
            }
        }

        return TraceExportReport(
            passed: findings.isEmpty,
            totalSpans: spans.count,
            validHierarchySpans: validHierarchy,
            spans: spans,
            findings: findings
        )
    }

    /// Pulls recent events from `TraceBus.shared` and exports them.
    public static func exportFromTraceBus(limit: Int = 100) -> TraceExportReport {
        let events = TraceBus.shared.events
        let slice = Array(events.suffix(limit))
        return export(events: slice)
    }
}
