import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Markdown projection for cron schedules

@Suite("CronScheduleMarkdownTests")
struct CronScheduleMarkdownTests {
    @Test func cronScheduleMarkdown() throws {
        let sched = try CronSchedule(expression: "0 9 * * 1-5")
        let md = sched.formatScheduleSummaryMarkdown()
        #expect(md.contains("Weekdays"))
    }
}
