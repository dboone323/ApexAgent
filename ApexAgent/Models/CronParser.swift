import Foundation

public struct CronSchedule: Sendable, Equatable {
    public let rawExpression: String
    
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    public let daysOfWeek: Set<Int>
    public var weekdays: Set<Int> { daysOfWeek }
    
    public init(expression: String) throws {
        self.rawExpression = expression
        let parts = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5 else {
            throw NSError(domain: "CronParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid cron expression"])
        }
        
        self.minutes = try Self.parsePart(parts[0], min: 0, max: 59)
        self.hours = try Self.parsePart(parts[1], min: 0, max: 23)
        self.daysOfMonth = try Self.parsePart(parts[2], min: 1, max: 31)
        self.months = try Self.parsePart(parts[3], min: 1, max: 12)
        
        let parsedDaysOfWeek = try Self.parsePart(parts[4], min: 0, max: 7)
        var normalizedDaysOfWeek = parsedDaysOfWeek
        if normalizedDaysOfWeek.contains(7) {
            normalizedDaysOfWeek.remove(7)
            normalizedDaysOfWeek.insert(0)
        }
        self.daysOfWeek = normalizedDaysOfWeek
    }
    
    private static func parsePart(_ part: String, min: Int, max: Int) throws -> Set<Int> {
        var results = Set<Int>()
        let subparts = part.split(separator: ",")
        
        for subpart in subparts {
            let s = String(subpart)
            if s == "*" {
                results.formUnion(min...max)
            } else if s.hasPrefix("*/") {
                let stepStr = s.dropFirst(2)
                guard let step = Int(stepStr), step > 0 else {
                    throw NSError(domain: "CronParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid step"])
                }
                results.formUnion(stride(from: min, through: max, by: step))
            } else if s.contains("-") {
                if let slashIndex = s.firstIndex(of: "/") {
                    let rangeStr = s[..<slashIndex]
                    let stepStr = s[s.index(after: slashIndex)...]
                    
                    let rangeParts = rangeStr.split(separator: "-")
                    guard rangeParts.count == 2,
                          let start = Int(rangeParts[0]),
                          let end = Int(rangeParts[1]),
                          let step = Int(stepStr),
                          start >= min, end <= max, start <= end, step > 0 else {
                        throw NSError(domain: "CronParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid range with step"])
                    }
                    results.formUnion(stride(from: start, through: end, by: step))
                } else {
                    let rangeParts = s.split(separator: "-")
                    guard rangeParts.count == 2,
                          let start = Int(rangeParts[0]),
                          let end = Int(rangeParts[1]),
                          start >= min, end <= max, start <= end else {
                        throw NSError(domain: "CronParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid range"])
                    }
                    results.formUnion(start...end)
                }
            } else {
                guard let val = Int(s), val >= min, val <= max else {
                    throw NSError(domain: "CronParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid value"])
                }
                results.insert(val)
            }
        }
        
        if results.isEmpty {
            throw NSError(domain: "CronParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty part"])
        }
        
        return results
    }
    
    public func matches(date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        
        guard let minute = components.minute,
              let hour = components.hour,
              let day = components.day,
              let month = components.month,
              let weekday = components.weekday else {
            return false
        }
        
        // In Swift Calendar, Sunday is 1, Monday is 2... Saturday is 7
        // In our cron, Sunday is 0, Monday is 1... Saturday is 6
        let cronWeekday = weekday - 1
        
        return minutes.contains(minute) &&
               hours.contains(hour) &&
               daysOfMonth.contains(day) &&
               months.contains(month) &&
               daysOfWeek.contains(cronWeekday)
    }
    
    public func nextDate(after startDate: Date = Date(), calendar: Calendar = .current) -> Date? {
        let nextDates = self.nextDates(after: startDate, count: 1, calendar: calendar)
        return nextDates.first
    }
    
    public func nextDates(after startDate: Date = Date(), count: Int, calendar: Calendar = .current) -> [Date] {
        var results: [Date] = []
        var currentDate = startDate
        
        guard let nextMinuteDate = calendar.date(byAdding: .minute, value: 1, to: currentDate) else { return [] }
        currentDate = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: nextMinuteDate)) ?? nextMinuteDate
        
        let maxDate = calendar.date(byAdding: .year, value: 5, to: startDate) ?? startDate
        
        while results.count < count && currentDate < maxDate {
            if matches(date: currentDate, calendar: calendar) {
                results.append(currentDate)
            }
            guard let nextDate = calendar.date(byAdding: .minute, value: 1, to: currentDate) else { break }
            currentDate = nextDate
        }
        
        return results
    }
    
    public var humanReadableDescription: String {
        switch rawExpression {
        case "* * * * *": return "Every minute"
        case "*/5 * * * *": return "Every 5 minutes"
        case "*/15 * * * *": return "Every 15 minutes"
        case "0 * * * *": return "Every hour at minute 0"
        case "0 0 * * *": return "Every day at midnight"
        case "0 9 * * 1-5": return "Weekdays at 9:00 AM"
        case "0 12 * * *": return "Every day at noon"
        default: return "Cron: \(rawExpression)"
        }
    }

    public func formatNextRunsTable(count: Int = 5, from startDate: Date = Date(), calendar: Calendar = .current) -> String {
        let dates = nextDates(after: startDate, count: count, calendar: calendar)
        guard !dates.isEmpty else {
            return "No upcoming scheduled execution dates found for `\(rawExpression)`."
        }

        var md = "### ⏱️ Upcoming Scheduled Executions: `\(rawExpression)` (\(humanReadableDescription))\n\n"
        md += "| # | Scheduled Time | Relative Offset |\n"
        md += "|---|---|---|\n"

        for (idx, date) in dates.enumerated() {
            let offsetSec = Int(date.timeIntervalSince(startDate))
            let offsetDesc: String
            if offsetSec < 60 {
                offsetDesc = "In \(offsetSec)s"
            } else if offsetSec < 3600 {
                offsetDesc = "In \(offsetSec / 60)m"
            } else {
                offsetDesc = "In \(offsetSec / 3600)h \((offsetSec % 3600) / 60)m"
            }
            md += "| `\(idx + 1)` | `\(date)` | \(offsetDesc) |\n"
        }
        return md
    }
    
    public static func isValid(_ expression: String) -> Bool {
        do {
            _ = try CronSchedule(expression: expression)
            return true
        } catch {
            return false
        }
    }
}

extension CronSchedule {
    public func formatScheduleSummaryMarkdown() -> String {
        var md = "### ⏱️ Cron Schedule: `\(rawExpression)` (\(humanReadableDescription))\n\n"
        md += "| Field | Values |\n"
        md += "|---|---|\n"
        md += "| Minutes | `\(minutes.sorted().prefix(12).map(String.init).joined(separator: ","))\(minutes.count > 12 ? "…" : "")` |\n"
        md += "| Hours | `\(hours.sorted().map(String.init).joined(separator: ","))` |\n"
        md += "| Days of Month | `\(daysOfMonth.sorted().prefix(12).map(String.init).joined(separator: ","))\(daysOfMonth.count > 12 ? "…" : "")` |\n"
        md += "| Months | `\(months.sorted().map(String.init).joined(separator: ","))` |\n"
        md += "| Days of Week | `\(daysOfWeek.sorted().map(String.init).joined(separator: ","))` |\n"
        return md
    }
}

extension CronSchedule {
    /// Safe constructor returning nil instead of throwing.
    public static func validated(expression: String) -> CronSchedule? {
        try? CronSchedule(expression: expression)
    }

    /// Human summary for invalid input without throwing.
    public static func validationMessage(for expression: String) -> String {
        if (try? CronSchedule(expression: expression)) != nil {
            return "Valid cron expression."
        }
        return "Invalid cron expression: '\(expression)'. Expected 5 fields (minute hour day month weekday)."
    }
}
