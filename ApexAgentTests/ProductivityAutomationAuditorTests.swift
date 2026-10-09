import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 95 — Personal Productivity Event Sanitizer Gate Tests")
struct ProductivityAutomationAuditorTests {

    @Test("Valid email recipient passes email validation")
    func validEmailPasses() {
        let valid = "developer@apple.com"
        let result = ProductivityAutomationAuditor.validateEmailRecipient(valid)

        #expect(result.isValid)
        #expect(result.sanitizedEmail == valid)
        #expect(!result.hasHeaderInjection)
    }

    @Test("Email recipient with CRLF injection is rejected as header injection")
    func emailWithCRLFRejected() {
        let injected = "victim@example.com\r\nBcc: attacker@evil.com"
        let result = ProductivityAutomationAuditor.validateEmailRecipient(injected)

        #expect(!result.isValid)
        #expect(result.sanitizedEmail == nil)
        #expect(result.hasHeaderInjection)
    }

    @Test("Email recipient with Bcc/Cc/To keywords is rejected as header injection")
    func emailWithHeaderKeywordRejected() {
        let injected = "victim@example.com bcc:evil@example.com"
        let result = ProductivityAutomationAuditor.validateEmailRecipient(injected)

        #expect(!result.isValid)
        #expect(result.sanitizedEmail == nil)
        #expect(result.hasHeaderInjection)
    }

    @Test("Invalid email syntax without injection fails validation cleanly")
    func invalidEmailSyntaxFails() {
        let invalid = "not-an-email-address"
        let result = ProductivityAutomationAuditor.validateEmailRecipient(invalid)

        #expect(!result.isValid)
        #expect(result.sanitizedEmail == nil)
        #expect(!result.hasHeaderInjection)
    }

    @Test("Valid calendar event passes audit with full score")
    func validCalendarEventPasses() {
        let start = Date()
        let end = start.addingTimeInterval(3600.0) // 1 hour

        let report = ProductivityAutomationAuditor.auditCalendarEvent(
            title: "Sprint Planning",
            startDate: start,
            endDate: end,
            location: "Conference Room A"
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)
    }

    @Test("Calendar event with end date preceding start date is rejected")
    func calendarEventEndBeforeStartFails() {
        let start = Date()
        let end = start.addingTimeInterval(-3600.0) // 1 hour in the past

        let report = ProductivityAutomationAuditor.auditCalendarEvent(
            title: "Sprint Planning",
            startDate: start,
            endDate: end
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "END_DATE_PRECEDES_START_DATE" })
    }

    @Test("Calendar event with empty title is rejected")
    func calendarEventEmptyTitleFails() {
        let start = Date()
        let end = start.addingTimeInterval(1800.0)

        let report = ProductivityAutomationAuditor.auditCalendarEvent(
            title: "   \n",
            startDate: start,
            endDate: end
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "EMPTY_EVENT_TITLE" })
    }

    @Test("Calendar event with excessive duration produces non-fatal warning")
    func calendarEventExcessiveDurationWarns() {
        let start = Date()
        let end = start.addingTimeInterval(86400.0 * 14.0) // 14 days

        let report = ProductivityAutomationAuditor.auditCalendarEvent(
            title: "Long Hackathon",
            startDate: start,
            endDate: end
        )

        #expect(report.passed) // Non-fatal warning allows passing
        #expect(report.score == 90.0)
        #expect(report.violations.contains { $0.code == "EXCESSIVE_EVENT_DURATION" })
    }

    @Test("Valid reminder passes audit")
    func validReminderPasses() {
        let report = ProductivityAutomationAuditor.auditReminder(
            title: "Review PR #17",
            priority: 5,
            notes: "Ensure all 100 batches pass"
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)
    }

    @Test("Reminder with invalid priority out of 0..9 range fails")
    func reminderInvalidPriorityFails() {
        let report = ProductivityAutomationAuditor.auditReminder(
            title: "Review PR #17",
            priority: 15
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "INVALID_REMINDER_PRIORITY" })
    }

    @Test("Text sanitizer strips control characters")
    func textSanitizerStripsControlChars() {
        let dirty = "Hello\u{0000}\u{0007} World!\t\n"
        let cleaned = ProductivityAutomationAuditor.sanitizeTextContent(dirty)

        #expect(cleaned == "Hello World!\t\n")
    }
}
