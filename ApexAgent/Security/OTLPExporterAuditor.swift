//
//  OTLPExporterAuditor.swift
//  ApexAgent
//
//  Created for Batch 109: OpenTelemetry (OTLP) HTTP Trace Exporter & Attribute Sanitizer.
//

import Foundation

// MARK: - OTLP Exporter Configuration

public struct OTLPExporterConfig: Sendable, Codable, Equatable {
    public var endpointURL: URL
    public var headers: [String: String]
    public var batchTimeoutSeconds: TimeInterval
    public var maxBatchSize: Int
    public var scrubPIIAndSecrets: Bool

    public static let defaultEndpoint = URL(string: "https://api.honeycomb.io/v1/traces")!

    public init(
        endpointURL: URL = defaultEndpoint,
        headers: [String: String] = [:],
        batchTimeoutSeconds: TimeInterval = 5.0,
        maxBatchSize: Int = 512,
        scrubPIIAndSecrets: Bool = true
    ) {
        self.endpointURL = endpointURL
        self.headers = headers
        self.batchTimeoutSeconds = batchTimeoutSeconds
        self.maxBatchSize = maxBatchSize
        self.scrubPIIAndSecrets = scrubPIIAndSecrets
    }
}

// MARK: - OTLP Trace Span & Payload Models

public struct OTLPSpanAttribute: Sendable, Codable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public func toDict() -> [String: Any] {
        ["key": key, "value": ["stringValue": value]]
    }
}

public struct OTLPTraceSpan: Sendable, Equatable {
    public let traceId: String // 32 hex chars
    public let spanId: String // 16 hex chars
    public let parentSpanId: String?
    public let name: String
    public let kind: Int // 1: INTERNAL, 2: SERVER, 3: CLIENT
    public let startTimeUnixNano: UInt64
    public let endTimeUnixNano: UInt64
    public let attributes: [OTLPSpanAttribute]
    public let statusCode: Int // 0: UNSET, 1: OK, 2: ERROR

    public init(
        traceId: String,
        spanId: String,
        parentSpanId: String? = nil,
        name: String,
        kind: Int = 1,
        startTimeUnixNano: UInt64,
        endTimeUnixNano: UInt64,
        attributes: [OTLPSpanAttribute] = [],
        statusCode: Int = 1
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
    }

    public func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "traceId": traceId,
            "spanId": spanId,
            "name": name,
            "kind": kind,
            "startTimeUnixNano": String(startTimeUnixNano),
            "endTimeUnixNano": String(endTimeUnixNano),
            "attributes": attributes.map { $0.toDict() },
            "status": ["code": statusCode]
        ]
        if let parent = parentSpanId, !parent.isEmpty {
            dict["parentSpanId"] = parent
        }
        return dict
    }
}

public struct OTLPTracePayloadBuilder: Sendable {
    public static func buildPayload(
        serviceName: String = "ApexAgent",
        serviceVersion: String = "1.0.0",
        spans: [OTLPTraceSpan]
    ) -> [String: Any] {
        let resource: [String: Any] = [
            "attributes": [
                ["key": "service.name", "value": ["stringValue": serviceName]],
                ["key": "service.version", "value": ["stringValue": serviceVersion]]
            ]
        ]

        let scopeSpans: [[String: Any]] = [
            [
                "scope": ["name": "com.apexagent.telemetry"],
                "spans": spans.map { $0.toDict() }
            ]
        ]

        let resourceSpans: [[String: Any]] = [
            [
                "resource": resource,
                "scopeSpans": scopeSpans
            ]
        ]

        return ["resourceSpans": resourceSpans]
    }

    public static func serializePayloadJSON(spans: [OTLPTraceSpan]) -> Data? {
        let payload = buildPayload(spans: spans)
        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}

// MARK: - OTLP Exporter Auditor & Attribute Sanitizer

public struct OTLPViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct OTLPAuditReport: Sendable, Codable, Equatable {
    public let endpointURL: String
    public let spansEvaluated: Int
    public let isCompliant: Bool
    public let piiClean: Bool
    public let securityScore: Double
    public let violations: [OTLPViolation]

    public init(
        endpointURL: String,
        spansEvaluated: Int,
        isCompliant: Bool,
        piiClean: Bool,
        securityScore: Double,
        violations: [OTLPViolation]
    ) {
        self.endpointURL = endpointURL
        self.spansEvaluated = spansEvaluated
        self.isCompliant = isCompliant
        self.piiClean = piiClean
        self.securityScore = securityScore
        self.violations = violations
    }
}

public struct OTLPExporterAuditor: Sendable {

    private static let sensitiveAttributeKeys = [
        "authorization", "api_key", "apikey", "secret", "password", "token", "ssn", "credit_card"
    ]

    /// Sanitizes span attributes by redacting sensitive values.
    public static func sanitizeAttributes(_ attributes: [OTLPSpanAttribute]) -> [OTLPSpanAttribute] {
        attributes.map { attr in
            let lowerKey = attr.key.lowercased()
            let isSensitive = sensitiveAttributeKeys.contains { lowerKey.contains($0) }
            if isSensitive {
                return OTLPSpanAttribute(key: attr.key, value: "[REDACTED_BY_APEX_GATE]")
            }
            return attr
        }
    }

    /// Verifies trace and span IDs against W3C tracecontext specification.
    public static func isValidTraceId(_ hex: String) -> Bool {
        guard hex.count == 32 else { return false }
        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return CharacterSet(charactersIn: hex).isSubset(of: hexChars) && hex != String(repeating: "0", count: 32)
    }

    public static func isValidSpanId(_ hex: String) -> Bool {
        guard hex.count == 16 else { return false }
        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return CharacterSet(charactersIn: hex).isSubset(of: hexChars) && hex != String(repeating: "0", count: 16)
    }

    /// Audits collector configuration and spans payload for compliance and security leaks.
    public static func audit(
        config: OTLPExporterConfig,
        spans: [OTLPTraceSpan]
    ) -> OTLPAuditReport {
        var violations: [OTLPViolation] = []
        var piiClean = true

        // 1. Endpoint Scheme Check
        let isLocal = (config.endpointURL.host == "localhost" || config.endpointURL.host == "127.0.0.1")
        if config.endpointURL.scheme?.lowercased() != "https" {
            if isLocal {
                violations.append(OTLPViolation(
                    code: "LOCAL_COLLECTOR_HTTP_ALLOWED",
                    message: "Plaintext HTTP collector endpoint permitted for local OpenTelemetry daemon.",
                    isFatal: false
                ))
            } else {
                violations.append(OTLPViolation(
                    code: "INSECURE_OTLP_ENDPOINT",
                    message: "Remote OTLP collector endpoint must use HTTPS to prevent span telemetry interception.",
                    isFatal: true
                ))
            }
        }

        // 2. Span ID & Timestamp Validation
        for span in spans {
            if !isValidTraceId(span.traceId) {
                violations.append(OTLPViolation(
                    code: "INVALID_TRACE_ID_FORMAT",
                    message: "Trace ID '\(span.traceId)' does not conform to 32-hex character W3C specification.",
                    isFatal: true
                ))
            }
            if !isValidSpanId(span.spanId) {
                violations.append(OTLPViolation(
                    code: "INVALID_SPAN_ID_FORMAT",
                    message: "Span ID '\(span.spanId)' does not conform to 16-hex character W3C specification.",
                    isFatal: true
                ))
            }
            if span.endTimeUnixNano < span.startTimeUnixNano {
                violations.append(OTLPViolation(
                    code: "INVERTED_SPAN_TIMESTAMPS",
                    message: "Span '\(span.name)' has endTime earlier than startTime.",
                    isFatal: true
                ))
            }

            // 3. Sensitive Attributes / DLP Check
            for attr in span.attributes {
                let lowerKey = attr.key.lowercased()
                for sensitive in sensitiveAttributeKeys {
                    if lowerKey.contains(sensitive) && attr.value != "[REDACTED_BY_APEX_GATE]" {
                        piiClean = false
                        violations.append(OTLPViolation(
                            code: "UNSANITIZED_SENSITIVE_ATTRIBUTE",
                            message: "Span '\(span.name)' contains unredacted credential attribute '\(attr.key)'.",
                            isFatal: false
                        ))
                        break
                    }
                }
            }
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let warnCount = violations.filter { !$0.isFatal }.count
        let rawScore = 1.0 - (Double(fatalCount) * 0.4) - (Double(warnCount) * 0.1)
        let score = max(0.0, min(1.0, rawScore))
        let compliant = fatalCount == 0

        return OTLPAuditReport(
            endpointURL: config.endpointURL.absoluteString,
            spansEvaluated: spans.count,
            isCompliant: compliant,
            piiClean: piiClean,
            securityScore: score,
            violations: violations
        )
    }

    public static func formatOTLPReportMarkdown(_ report: OTLPAuditReport) -> String {
        var md = "### 📡 OpenTelemetry (OTLP) Exporter & Telemetry Audit\n\n"
        md += "| Parameter | Value | Status |\n"
        md += "|---|---|---|\n"
        md += "| Collector Endpoint | `\(report.endpointURL)` | 🌐 Exporter Target |\n"
        md += "| Spans Audited | `\(report.spansEvaluated)` | 📊 Batch Volume |\n"
        md += "| Compliance | \(report.isCompliant ? "✅ Compliant" : "❌ Non-Compliant") | W3C Standard |\n"
        md += "| Secret & PII Scrubbing | \(report.piiClean ? "🛡️ Clean / Scrubbed" : "⚠️ Potential Leaks") | DLP Protection |\n"
        md += "| Security Score | `\(Int(report.securityScore * 100))%` | \(report.securityScore >= 0.8 ? "🛡️ Solid" : "⚠️ Attention Required") |\n\n"

        if !report.violations.isEmpty {
            md += "#### Findings\n"
            for v in report.violations {
                let badge = v.isFatal ? "🔴 **[FATAL]**" : "🟡 **[WARN]**"
                md += "- \(badge) `\(v.code)`: \(v.message)\n"
            }
        }
        return md
    }
}
