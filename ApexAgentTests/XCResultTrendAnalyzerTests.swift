import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 40 — xcresult Regression Diffing, Slow-Test Budget Gate & Workflows 16–20 Tests")
struct XCResultTrendAnalyzerTests {

    @Test("XCResultTrendAnalyzer passes when test count grows with zero failures and fast test timings")
    func passesHealthyTrendComparison() {
        let baseline = XCResultSummaryReport(result: "Passed", totalTestCount: 1055, passedTests: 1055, failedTests: 0)
        let current = XCResultSummaryReport(result: "Passed", totalTestCount: 1085, passedTests: 1085, failedTests: 0)
        let timings = [
            TestTimingRecord(identifier: "SuiteA/testFast1", durationSeconds: 0.05),
            TestTimingRecord(identifier: "SuiteB/testFast2", durationSeconds: 1.20)
        ]

        let report = XCResultTrendAnalyzer.compare(
            baseline: baseline,
            current: current,
            timings: timings,
            maxTestDurationSeconds: 5.0
        )
        #expect(report.passed)
        #expect(report.testCountDelta == 30)
        #expect(report.newFailureCount == 0)
        #expect(report.slowOutliers.isEmpty)
        #expect(report.reasons.isEmpty)

        let md = report.formatMarkdown()
        #expect(md.contains("### 📈 xcresult Quality & Trend Gate (✅ PASS)"))
        #expect(md.contains("| Test Count Delta | `+30` |"))
    }

    @Test("XCResultTrendAnalyzer flags new test failures, test count drops, and duration budget outliers")
    func detectsRegressionsAndSlowOutliers() {
        let baseline = XCResultSummaryReport(result: "Passed", totalTestCount: 1085, passedTests: 1085, failedTests: 0)
        let regressed = XCResultSummaryReport(result: "Failed", totalTestCount: 1080, passedTests: 1078, failedTests: 2)
        let timings = [
            TestTimingRecord(identifier: "FastSuite/testQuick", durationSeconds: 0.10),
            TestTimingRecord(identifier: "SlowSuite/testHang", durationSeconds: 14.5, passed: true)
        ]

        let report = XCResultTrendAnalyzer.compare(
            baseline: baseline,
            current: regressed,
            timings: timings,
            maxTestDurationSeconds: 5.0
        )
        #expect(!report.passed)
        #expect(report.testCountDelta == -5)
        #expect(report.newFailureCount == 2)
        #expect(report.slowOutliers.count == 1)
        #expect(report.slowOutliers.first?.identifier == "SlowSuite/testHang")
        #expect(report.reasons.count >= 4)

        let md = report.formatMarkdown()
        #expect(md.contains("❌ REGRESSION"))
    }

    @Test("Workflows 16 through 20 execute real Loop 5 subsystems and pass")
    @MainActor
    func workflows16Through20Pass() async {
        let results = await ApexWorkflows.run(ids: [16, 17, 18, 19, 20])
        #expect(results.count == 5)
        for id in [16, 17, 18, 19, 20] {
            guard let res = results.first(where: { $0.id == id }) else {
                Issue.record("Missing workflow result for ID \(id)")
                continue
            }
            #expect(res.passed, "Workflow \(id) failed: \(res.line)")
            #expect(res.line.hasPrefix("PASS [\(id)]"))
        }
    }
}
