import Foundation

/// Alert categories defined in Worker Semantics §3.
public enum AlertCategory: String, Sendable, CaseIterable, Codable {
    case error
    case warning
    case failed
    case cancelled
    case didNotRun = "did-not-run"
}

/// Alert classification against recorded baseline.
public enum AlertClassification: String, Sendable, Codable {
    case baselineKnown = "baseline-known"
    case newAlert = "NEW"
}

/// A detected non-green alert line with its context and classification.
public struct DetectedAlert: Sendable, Equatable, Codable {
    public let category: AlertCategory
    public let classification: AlertClassification
    public let lineText: String
    public let lineNumber: Int
    public let matchedNoisePattern: String?

    public init(
        category: AlertCategory,
        classification: AlertClassification,
        lineText: String,
        lineNumber: Int,
        matchedNoisePattern: String? = nil
    ) {
        self.category = category
        self.classification = classification
        self.lineText = lineText
        self.lineNumber = lineNumber
        self.matchedNoisePattern = matchedNoisePattern
    }
}

/// Summary test totals parsed from a gate execution log.
public struct GateLogTotals: Sendable, Equatable, Codable {
    public var total: Int
    public var passed: Int
    public var failed: Int
    public var skipped: Int

    public init(total: Int = 0, passed: Int = 0, failed: Int = 0, skipped: Int = 0) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
    }
}

/// Category counts breakdown.
public struct AlertCounts: Sendable, Equatable, Codable {
    public var total: Int
    public var baselineKnown: Int
    public var newAlerts: Int

    public init(total: Int = 0, baselineKnown: Int = 0, newAlerts: Int = 0) {
        self.total = total
        self.baselineKnown = baselineKnown
        self.newAlerts = newAlerts
    }
}

/// Complete analysis of a gate log file.
public struct GateLogAnalysis: Sendable, Equatable {
    public let totals: GateLogTotals?
    public let alerts: [DetectedAlert]
    public let countsByCategory: [AlertCategory: AlertCounts]
    public let firstExamples: [AlertCategory: [DetectedAlert]]

    public var hasNewAlerts: Bool {
        countsByCategory.values.contains { $0.newAlerts > 0 }
    }

    public var totalNewAlertsCount: Int {
        countsByCategory.values.reduce(0) { $0 + $1.newAlerts }
    }
}

/// Analyzes raw gate command logs for test totals and non-green alert patterns.
public final class GateLogAnalyzer: Sendable {
    public init() {}

    /// Analyzes the log string against an optional baseline.
    public func analyze(log: String, baseline: GateBaseline? = nil) -> GateLogAnalysis {
        let totals = parseTotals(from: log)
        let alerts = scanAlerts(log: log, baseline: baseline)

        var counts: [AlertCategory: AlertCounts] = [:]
        var examples: [AlertCategory: [DetectedAlert]] = [:]

        for category in AlertCategory.allCases {
            counts[category] = AlertCounts()
            examples[category] = []
        }

        for alert in alerts {
            var current = counts[alert.category] ?? AlertCounts()
            current.total += 1
            if alert.classification == .baselineKnown {
                current.baselineKnown += 1
            } else {
                current.newAlerts += 1
            }
            counts[alert.category] = current

            var list = examples[alert.category] ?? []
            if list.count < 5 {
                list.append(alert)
                examples[alert.category] = list
            }
        }

        return GateLogAnalysis(
            totals: totals,
            alerts: alerts,
            countsByCategory: counts,
            firstExamples: examples
        )
    }

    /// Parses summary totals from various test runner outputs (xcodebuild, swift test, etc.)
    public func parseTotals(from log: String) -> GateLogTotals? {
        let lines = log.components(separatedBy: .newlines)

        // 1. Check for: "1893 total / 1878 passed / 0 failed / 15 skipped"
        let standardPattern = try? NSRegularExpression(
            pattern: #"(\d+)\s+total\s*/\s*(\d+)\s+passed\s*/\s*(\d+)\s+failed\s*/\s*(\d+)\s+skipped"#,
            options: .caseInsensitive
        )

        // 2. Check for: "Executed 1893 tests, with 0 failures (0 unexpected) in 42.123 (45.678) seconds"
        let xcodePattern = try? NSRegularExpression(
            pattern: #"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?\s+\((\d+)\s+unexpected\)"#,
            options: .caseInsensitive
        )

        // 3. Check for: "Passed: 1878, Failed: 0, Skipped: 15"
        let verbosePattern = try? NSRegularExpression(
            pattern: #"Passed:\s*(\d+).*?Failed:\s*(\d+).*?Skipped:\s*(\d+)"#,
            options: .caseInsensitive
        )

        // Search in reverse order to find the final summary line
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let pattern = standardPattern {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = pattern.firstMatch(in: trimmed, range: range) {
                    if let r1 = Range(match.range(at: 1), in: trimmed),
                       let r2 = Range(match.range(at: 2), in: trimmed),
                       let r3 = Range(match.range(at: 3), in: trimmed),
                       let r4 = Range(match.range(at: 4), in: trimmed),
                       let t = Int(trimmed[r1]),
                       let p = Int(trimmed[r2]),
                       let f = Int(trimmed[r3]),
                       let s = Int(trimmed[r4]) {
                        return GateLogTotals(total: t, passed: p, failed: f, skipped: s)
                    }
                }
            }

            if let pattern = xcodePattern {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = pattern.firstMatch(in: trimmed, range: range) {
                    if let r1 = Range(match.range(at: 1), in: trimmed),
                       let r2 = Range(match.range(at: 2), in: trimmed),
                       let total = Int(trimmed[r1]),
                       let failed = Int(trimmed[r2]) {
                        let passed = max(0, total - failed)
                        return GateLogTotals(total: total, passed: passed, failed: failed, skipped: 0)
                    }
                }
            }

            if let pattern = verbosePattern {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = pattern.firstMatch(in: trimmed, range: range) {
                    if let r1 = Range(match.range(at: 1), in: trimmed),
                       let r2 = Range(match.range(at: 2), in: trimmed),
                       let r3 = Range(match.range(at: 3), in: trimmed),
                       let p = Int(trimmed[r1]),
                       let f = Int(trimmed[r2]),
                       let s = Int(trimmed[r3]) {
                        return GateLogTotals(total: p + f + s, passed: p, failed: f, skipped: s)
                    }
                }
            }
        }

        return nil
    }

    /// Scans log lines for non-green patterns and classifies against the baseline.
    private func scanAlerts(log: String, baseline: GateBaseline?) -> [DetectedAlert] {
        var alerts: [DetectedAlert] = []
        let lines = log.components(separatedBy: .newlines)

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Ignore positive / zero indicators
            if isFalsePositive(line) {
                continue
            }

            let lineNumber = index + 1
            let matchedCategory = categorizeLine(line)

            if let category = matchedCategory {
                let matchedNoise = baseline?.matchesKnownNoise(line)
                let classification: AlertClassification = (matchedNoise != nil) ? .baselineKnown : .newAlert
                alerts.append(DetectedAlert(
                    category: category,
                    classification: classification,
                    lineText: line,
                    lineNumber: lineNumber,
                    matchedNoisePattern: matchedNoise
                ))
            }
        }

        return alerts
    }

    /// Determines if a line is a false positive (e.g. "0 errors", "0 failures", "0 warnings", etc.)
    private func isFalsePositive(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("0 error") || lower.contains("0 failure") || lower.contains("0 warning") || lower.contains("0 failed") {
            return true
        }
        if lower.hasPrefix("passed:") || lower.hasPrefix("test passed") || lower.contains("** test passed **") {
            return true
        }
        return false
    }

    /// Matches a line to one of the 5 alert categories.
    private func categorizeLine(_ line: String) -> AlertCategory? {
        let lower = line.lowercased()

        // 1. Error
        if lower.contains("error:") || lower.contains("fatal error:") || line.contains("❌") || lower.contains("compilation error") {
            return .error
        }

        // 2. Failed
        if lower.contains("failed:") || lower.contains("fail:") || line.contains("✘ Test") ||
           lower.contains("test case") && lower.contains("failed") || lower.contains("** test failed **") ||
           line.hasPrefix("Failing tests:") {
            return .failed
        }

        // 3. Warning
        if lower.contains("warning:") || line.contains("⚠️") || lower.contains("[warning]") {
            return .warning
        }

        // 4. Cancelled
        if lower.contains("cancelled") || lower.contains("canceled") || lower.contains("[cancelled]") {
            return .cancelled
        }

        // 5. Did-not-run / Skipped
        if lower.contains("did not run") || lower.contains("did-not-run") || lower.contains("test skipped") || lower.contains("[skipped]") {
            return .didNotRun
        }

        return nil
    }
}
