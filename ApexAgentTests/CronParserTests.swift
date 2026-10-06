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

// MARK: - Input validation hardening for cron expressions

@Suite("CronScheduleValidationTests")
struct CronScheduleValidationTests {
    @Test func cronValidated() {
        #expect(CronSchedule.validated(expression: "not a cron") == nil)
        #expect(CronSchedule.validated(expression: "0 9 * * 1-5") != nil)
        #expect(CronSchedule.validationMessage(for: "junk").contains("Invalid"))
        #expect(CronSchedule.validationMessage(for: "0 9 * * 1-5").contains("Valid"))
    }
}
