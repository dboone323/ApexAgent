import Foundation

/// Represents the completed evaluation and report for a gate queue job.
public struct GateJobReport: Sendable {
    public let jobSpec: GateJobSpec
    public let exitCode: Int32
    public let duration: TimeInterval
    public let logFileURL: URL
    public let sentinelFileURL: URL
    public let reportFileURL: URL
    public let completedAt: Date
    public let analysis: GateLogAnalysis

    public init(
        jobSpec: GateJobSpec,
        exitCode: Int32,
        duration: TimeInterval,
        logFileURL: URL,
        sentinelFileURL: URL,
        reportFileURL: URL,
        completedAt: Date,
        analysis: GateLogAnalysis
    ) {
        self.jobSpec = jobSpec
        self.exitCode = exitCode
        self.duration = duration
        self.logFileURL = logFileURL
        self.sentinelFileURL = sentinelFileURL
        self.reportFileURL = reportFileURL
        self.completedAt = completedAt
        self.analysis = analysis
    }

    /// Renders the Markdown report conforming to Worker Semantics §3.
    public func renderMarkdown() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: completedAt)
        let statusString = exitCode == 0 ? "PASS" : "FAIL"
        let commandString = jobSpec.gateCommand.joined(separator: " ")
        let durationFormatted = String(format: "%.2f", duration)

        var md = """
        # Gate Job Report: \(jobSpec.jobName)

        - **Target Project:** `\(jobSpec.targetProject)`
        - **Job Name:** `\(jobSpec.jobName)`
        - **Job ID:** `\(jobSpec.id)`
        - **Gate Command:** `\(commandString)`
        - **Exit Code:** `\(exitCode)` (\(statusString))
        - **Duration:** \(durationFormatted)s
        - **Completed At:** \(timestamp)
        - **Log File:** `\(logFileURL.lastPathComponent)`
        - **Sentinel:** `\(sentinelFileURL.lastPathComponent)`

        ## Summary Totals

        """

        if let totals = analysis.totals {
            md += """
            | Metric | Count |
            |---|---|
            | Total Tests | \(totals.total) |
            | Passed | \(totals.passed) |
            | Failed | \(totals.failed) |
            | Skipped | \(totals.skipped) |

            """
        } else {
            md += "*No standard test summary totals line was detected in the log output.*\n\n"
        }

        md += """
        ## Non-Green Alert Scan

        | Category | Total Count | Baseline-Known | NEW |
        |---|---|---|---|

        """

        for category in AlertCategory.allCases {
            let counts = analysis.countsByCategory[category] ?? AlertCounts()
            md += "| `\(category.rawValue)` | \(counts.total) | \(counts.baselineKnown) | \(counts.newAlerts) |\n"
        }

        md += "\n### NEW Alerts (Action Required)\n\n"

        let newAlerts = analysis.alerts.filter { $0.classification == .newAlert }
        if newAlerts.isEmpty {
            md += "None — zero unclassified non-green alerts found.\n\n"
        } else {
            md += "⚠️ **\(newAlerts.count) new alert(s) detected that were not present in the baseline:**\n\n"
            for category in AlertCategory.allCases {
                let categoryNew = analysis.firstExamples[category]?.filter { $0.classification == .newAlert } ?? []
                if !categoryNew.isEmpty {
                    md += "#### Category: `\(category.rawValue)`\n"
                    for alert in categoryNew {
                        md += "- Line \(alert.lineNumber): `\(alert.lineText)`\n"
                    }
                    let totalNewForCat = analysis.countsByCategory[category]?.newAlerts ?? 0
                    if totalNewForCat > categoryNew.count {
                        md += "  *(... and \(totalNewForCat - categoryNew.count) more `\(category.rawValue)` alerts)*\n"
                    }
                    md += "\n"
                }
            }
        }

        md += "### Baseline-Known Alerts\n\n"
        let knownAlerts = analysis.alerts.filter { $0.classification == .baselineKnown }
        if knownAlerts.isEmpty {
            md += "None — no alerts matched baseline noise patterns.\n\n"
        } else {
            for category in AlertCategory.allCases {
                let categoryKnown = analysis.firstExamples[category]?.filter { $0.classification == .baselineKnown } ?? []
                if !categoryKnown.isEmpty {
                    md += "#### Category: `\(category.rawValue)` (Noise Pattern Matches)\n"
                    for alert in categoryKnown {
                        let pattern = alert.matchedNoisePattern ?? "unknown"
                        md += "- Line \(alert.lineNumber) (matched `\(pattern)`): `\(alert.lineText)`\n"
                    }
                    md += "\n"
                }
            }
        }

        return md
    }

    /// Writes the report to its destination URL.
    public func writeReport() throws {
        let content = renderMarkdown()
        try content.write(to: reportFileURL, atomically: true, encoding: .utf8)
    }
}
