import Foundation

// MARK: - Batch 40: xcresult Regression Diffing & Slow-Test Budget Gate

/// Timing and pass/fail record for an individual test case.
public struct TestTimingRecord: Codable, Sendable, Equatable {
    public let identifier: String
    public let durationSeconds: Double
    public let passed: Bool

    public init(identifier: String, durationSeconds: Double, passed: Bool = true) {
        self.identifier = identifier
        self.durationSeconds = durationSeconds
        self.passed = passed
    }
}

/// Regression comparison and duration-budget report produced by ``XCResultTrendAnalyzer``.
public struct XCResultRegressionReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let testCountDelta: Int
    public let newFailureCount: Int
    public let passRateDelta: Double
    public let slowOutliers: [TestTimingRecord]
    public let reasons: [String]

    public init(
        passed: Bool,
        testCountDelta: Int,
        newFailureCount: Int,
        passRateDelta: Double,
        slowOutliers: [TestTimingRecord],
        reasons: [String]
    ) {
        self.passed = passed
        self.testCountDelta = testCountDelta
        self.newFailureCount = newFailureCount
        self.passRateDelta = passRateDelta
        self.slowOutliers = slowOutliers
        self.reasons = reasons
    }

    public func formatMarkdown() -> String {
        let badge = passed ? "✅ PASS" : "❌ REGRESSION"
        let deltaSign = testCountDelta >= 0 ? "+\(testCountDelta)" : "\(testCountDelta)"
        var md = "### 📈 xcresult Quality & Trend Gate (\(badge))\n\n"
        md += "| Metric | Value |\n"
        md += "|---|---|\n"
        md += "| Verdict | **\(badge)** |\n"
        md += "| Test Count Delta | `\(deltaSign)` |\n"
        md += "| New Failures | `\(newFailureCount)` |\n"
        md += "| Pass Rate Delta | `\(String(format: "%+.2f%%", passRateDelta))` |\n"
        md += "| Slow Outliers | `\(slowOutliers.count)` |\n"

        if !reasons.isEmpty {
            md += "\n#### Findings\n"
            for reason in reasons {
                md += "- \(reason)\n"
            }
        }
        return md
    }
}

/// Compares baseline vs. current ``XCResultSummaryReport`` snapshots and enforces per-test duration budgets.
public enum XCResultTrendAnalyzer {

    public static let defaultMaxTestDurationSeconds: Double = 10.0

    /// Compares `current` against `baseline` and evaluates `timings` against `maxTestDurationSeconds`.
    public static func compare(
        baseline: XCResultSummaryReport,
        current: XCResultSummaryReport,
        timings: [TestTimingRecord] = [],
        maxTestDurationSeconds: Double = defaultMaxTestDurationSeconds,
        allowTestCountDrop: Bool = false
    ) -> XCResultRegressionReport {
        var reasons: [String] = []
        let countDelta = current.totalTestCount - baseline.totalTestCount
        let newFailures = max(0, current.failedTests - baseline.failedTests)
        let rateDelta = current.passRatePercent - baseline.passRatePercent

        if !current.meetsQualityGate {
            reasons.append("Current test bundle failed quality gate (result=\(current.result), failedTests=\(current.failedTests), total=\(current.totalTestCount)).")
        }
        if newFailures > 0 {
            reasons.append("Introduced \(newFailures) new test failure(s) compared to baseline.")
        }
        if !allowTestCountDrop && countDelta < 0 {
            reasons.append("Total test count dropped by \(abs(countDelta)) (baseline=\(baseline.totalTestCount), current=\(current.totalTestCount)).")
        }
        if rateDelta < -1e-6 {
            reasons.append(String(format: "Pass rate decreased by %.2f%%.", abs(rateDelta)))
        }

        let slowOutliers = timings
            .filter { $0.durationSeconds > maxTestDurationSeconds }
            .sorted { $0.durationSeconds > $1.durationSeconds }

        if !slowOutliers.isEmpty {
            reasons.append("\(slowOutliers.count) test(s) exceeded the \(String(format: "%.1fs", maxTestDurationSeconds)) duration budget.")
        }

        return XCResultRegressionReport(
            passed: reasons.isEmpty,
            testCountDelta: countDelta,
            newFailureCount: newFailures,
            passRateDelta: rateDelta,
            slowOutliers: slowOutliers,
            reasons: reasons
        )
    }
}
