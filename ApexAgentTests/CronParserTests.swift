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

@Suite("CronParserTests")
struct CronParserTests {
    @Test("Standard cron parsing")
    func testStandardCronParsing() throws {
        let schedule1 = try CronSchedule(expression: "* * * * *")
        #expect(schedule1.minutes.contains(0))
        #expect(schedule1.minutes.contains(59))
        
        let schedule2 = try CronSchedule(expression: "*/10 * * * *")
        #expect(schedule2.minutes.contains(0))
        #expect(schedule2.minutes.contains(10))
        #expect(schedule2.minutes.contains(50))
        #expect(!schedule2.minutes.contains(5))
        
        let schedule3 = try CronSchedule(expression: "0 9 * * 1-5")
        #expect(schedule3.minutes == [0])
        #expect(schedule3.hours == [9])
        #expect(schedule3.weekdays.contains(2))
        
        let schedule4 = try CronSchedule(expression: "15,45 8-17 * * *")
        #expect(schedule4.minutes == [15, 45])
        #expect(schedule4.hours.contains(8))
        #expect(schedule4.hours.contains(17))
    }
    
    @Test("matches(date:) with a constructed DateComponents")
    func testMatchesDate() throws {
        let schedule = try CronSchedule(expression: "0 9 * * 1-5") // Mon-Fri 9:00
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 26 // Wednesday
        components.hour = 9
        components.minute = 0
        
        let calendar = Calendar.current
        let date = calendar.date(from: components)!
        #expect(schedule.matches(date: date))
        
        var badComponents = components
        badComponents.minute = 1
        let badDate = calendar.date(from: badComponents)!
        #expect(!schedule.matches(date: badDate))
    }
    
    @Test("nextDate(after:) returns the correct future minute")
    func testNextDate() throws {
        let schedule = try CronSchedule(expression: "0 9 * * *")
        
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 26
        components.hour = 8
        components.minute = 30
        let calendar = Calendar.current
        let date = calendar.date(from: components)!
        
        let nextDate = schedule.nextDate(after: date)
        #expect(nextDate != nil)
        
        let nextComponents = calendar.dateComponents([.hour, .minute], from: nextDate!)
        #expect(nextComponents.hour == 9)
        #expect(nextComponents.minute == 0)
    }
    
    @Test("nextDates(after:count:) returns array of future dates")
    func testNextDates() throws {
        let schedule = try CronSchedule(expression: "*/30 * * * *")
        
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 26
        components.hour = 12
        components.minute = 15
        let calendar = Calendar.current
        let date = calendar.date(from: components)!
        
        let dates = schedule.nextDates(after: date, count: 3)
        #expect(dates.count == 3)
        
        let comps0 = calendar.dateComponents([.minute], from: dates[0])
        let comps1 = calendar.dateComponents([.minute], from: dates[1])
        let comps2 = calendar.dateComponents([.minute], from: dates[2])
        
        #expect(comps0.minute == 30)
        #expect(comps1.minute == 0)
        #expect(comps2.minute == 30)
    }
    
    @Test("CronSchedule.isValid(...) for valid and invalid strings")
    func testIsValid() {
        #expect(CronSchedule.isValid("* * * * *"))
        #expect(CronSchedule.isValid("*/10 9-17 * * 1,3,5"))
        #expect(!CronSchedule.isValid("* * *"))
        #expect(!CronSchedule.isValid("60 * * * *"))
        #expect(!CronSchedule.isValid("* 24 * * *"))
        #expect(!CronSchedule.isValid("invalid"))
    }
    
    @Test("Error throwing for malformed expressions")
    func testErrorThrowing() {
        #expect(throws: Error.self) {
            _ = try CronSchedule(expression: "* * *")
        }
        #expect(throws: Error.self) {
            _ = try CronSchedule(expression: "60 * * * *")
        }
    }
}

