//
//  MetricsExporterAuditor.swift
//  ApexAgent
//
//  Created for Batch 117: Prometheus/OpenMetrics Exposition & Datadog Metrics Exporter Auditor.
//

import Foundation

// MARK: - Metric Types & Models

public enum MetricType: String, Sendable, Codable, Equatable {
    case gauge
    case counter
    case histogram
    case summary
}

public struct MetricSample: Sendable, Codable, Equatable {
    public let name: String
    public let value: Double
    public let labels: [String: String]
    public let timestampMilliseconds: Int64?

    public init(
        name: String,
        value: Double,
        labels: [String: String] = [:],
        timestampMilliseconds: Int64? = nil
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = value
        self.labels = labels
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public struct MetricSeries: Sendable, Codable, Equatable {
    public let name: String
    public let help: String
    public let type: MetricType
    public let samples: [MetricSample]

    public init(name: String, help: String, type: MetricType, samples: [MetricSample]) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.help = help.trimmingCharacters(in: .whitespacesAndNewlines)
        self.type = type
        self.samples = samples
    }
}

public struct DatadogMetricPoint: Sendable, Codable, Equatable {
    public let timestamp: Int64
    public let value: Double

    public init(timestamp: Int64 = Int64(Date().timeIntervalSince1970), value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}

public struct DatadogMetricSeries: Sendable, Codable, Equatable {
    public let metric: String
    public let type: Int // 1 = gauge, 2 = count, 3 = rate
    public let points: [DatadogMetricPoint]
    public let tags: [String]

    public init(metric: String, type: Int = 1, points: [DatadogMetricPoint], tags: [String] = []) {
        self.metric = metric.trimmingCharacters(in: .whitespacesAndNewlines)
        self.type = type
        self.points = points
        self.tags = tags
    }
}

// MARK: - Metrics Audit Violation & Report

public struct MetricsAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct MetricsAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let metricCount: Int
    public let totalSamples: Int
    public let violations: [MetricsAuditViolation]

    public init(
        passed: Bool,
        score: Double,
        metricCount: Int,
        totalSamples: Int,
        violations: [MetricsAuditViolation]
    ) {
        self.passed = passed
        self.score = score
        self.metricCount = metricCount
        self.totalSamples = totalSamples
        self.violations = violations
    }
}

// MARK: - Metrics Exporter Auditor

public enum MetricsExporterAuditor {

    // MARK: - Name & Label Validation

    /// Validates Prometheus metric identifier: ^[a-zA-Z_:][a-zA-Z0-9_:]*$
    public static func validateMetricName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        let firstScalar = name.unicodeScalars.first!
        let validFirst = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_:")
        guard validFirst.contains(firstScalar) else { return false }

        let validRest = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:")
        return name.unicodeScalars.allSatisfy { validRest.contains($0) }
    }

    /// Validates Prometheus label identifier: ^[a-zA-Z_][a-zA-Z0-9_]*$ (cannot start with __ unless reserved)
    public static func validateLabelName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        if name.hasPrefix("__") { return false } // Reserved for Prometheus internals

        let firstScalar = name.unicodeScalars.first!
        let validFirst = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        guard validFirst.contains(firstScalar) else { return false }

        let validRest = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        return name.unicodeScalars.allSatisfy { validRest.contains($0) }
    }

    // MARK: - Audit Series

    public static func auditMetricSeries(_ seriesList: [MetricSeries]) -> MetricsAuditReport {
        var violations: [MetricsAuditViolation] = []
        var totalSamples = 0

        if seriesList.isEmpty {
            violations.append(MetricsAuditViolation(
                code: "EMPTY_METRIC_SERIES_LIST",
                message: "Metrics series collection is empty.",
                isFatal: false
            ))
        }

        for series in seriesList {
            totalSamples += series.samples.count

            if !validateMetricName(series.name) {
                violations.append(MetricsAuditViolation(
                    code: "INVALID_METRIC_NAME",
                    message: "Metric name '\(series.name)' violates Prometheus naming grammar [a-zA-Z_:][a-zA-Z0-9_:]*.",
                    isFatal: true
                ))
            }

            if series.help.isEmpty {
                violations.append(MetricsAuditViolation(
                    code: "MISSING_METRIC_HELP",
                    message: "Metric '\(series.name)' lacks a descriptive # HELP line.",
                    isFatal: false
                ))
            }

            for sample in series.samples {
                for (labelKey, labelVal) in sample.labels {
                    if !validateLabelName(labelKey) {
                        violations.append(MetricsAuditViolation(
                            code: "INVALID_LABEL_NAME",
                            message: "Label key '\(labelKey)' on metric '\(sample.name)' violates Prometheus label grammar.",
                            isFatal: true
                        ))
                    }
                    if labelVal.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) {
                        violations.append(MetricsAuditViolation(
                            code: "CRLF_IN_LABEL_VALUE",
                            message: "Label value for '\(labelKey)' contains forbidden newline characters.",
                            isFatal: true
                        ))
                    }
                }
            }
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let nonFatalCount = violations.filter { !$0.isFatal }.count
        let rawScore = 100.0 - (Double(fatalCount) * 50.0) - (Double(nonFatalCount) * 15.0)
        let finalScore = max(0.0, min(100.0, rawScore))
        let passed = (fatalCount == 0)

        return MetricsAuditReport(
            passed: passed,
            score: finalScore,
            metricCount: seriesList.count,
            totalSamples: totalSamples,
            violations: violations
        )
    }

    // MARK: - OpenMetrics / Prometheus Exposition Format

    public static func exportPrometheusExposition(series: [MetricSeries]) -> String {
        var lines: [String] = []

        for item in series {
            if !item.help.isEmpty {
                lines.append("# HELP \(item.name) \(item.help)")
            }
            lines.append("# TYPE \(item.name) \(item.type.rawValue)")

            for sample in item.samples {
                var line = sample.name
                if !sample.labels.isEmpty {
                    let sortedLabels = sample.labels.sorted { $0.key < $1.key }
                    let labelPairs = sortedLabels.map { key, val in
                        let escapedVal = val.replacingOccurrences(of: "\\", with: "\\\\")
                                            .replacingOccurrences(of: "\"", with: "\\\"")
                                            .replacingOccurrences(of: "\n", with: "\\n")
                        return "\(key)=\"\(escapedVal)\""
                    }.joined(separator: ",")
                    line += "{\(labelPairs)}"
                }
                line += " \(sample.value)"
                if let ts = sample.timestampMilliseconds {
                    line += " \(ts)"
                }
                lines.append(line)
            }
            lines.append("") // Empty newline separator
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Datadog Request Builder

    public static func buildDatadogSeriesRequest(
        apiKey: String,
        series: [DatadogMetricSeries],
        site: String = "datadoghq.com"
    ) -> URLRequest? {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !series.isEmpty else { return nil }

        guard let url = URL(string: "https://api.\(site)/api/v2/series") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cleanKey, forHTTPHeaderField: "DD-API-KEY")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        let seriesArray = series.map { s in
            [
                "metric": s.metric,
                "type": s.type,
                "points": s.points.map { ["timestamp": $0.timestamp, "value": $0.value] },
                "tags": s.tags
            ] as [String: Any]
        }

        let bodyDict: [String: Any] = ["series": seriesArray]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return nil }
        req.httpBody = data
        return req
    }

    // MARK: - Markdown Formatter

    public static func formatMetricsAuditReportMarkdown(_ report: MetricsAuditReport) -> String {
        var md = "### 📊 Metrics Exporter & OpenMetrics Audit\n\n"
        md += "| Parameter | Value |\n"
        md += "|---|---|\n"
        md += "| **Status** | \(report.passed ? "✅ Compliant" : "❌ Non-Compliant") |\n"
        md += "| **Score** | `\(String(format: "%.1f", report.score))%` |\n"
        md += "| **Series Count** | `\(report.metricCount)` |\n"
        md += "| **Total Samples** | `\(report.totalSamples)` |\n\n"

        if report.violations.isEmpty {
            md += "✨ **Zero violations found.** All metric names, labels, and exposition formats conform to Prometheus standards.\n"
        } else {
            md += "#### Violations (\(report.violations.count))\n\n"
            for v in report.violations {
                let badge = v.isFatal ? "🔴 FATAL" : "🟡 WARN"
                md += "- \(badge) `\(v.code)`: \(v.message)\n"
            }
        }
        return md
    }
}
