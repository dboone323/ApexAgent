import Foundation
import SwiftData
import SharedKit

@Model
public final class WeeklyReflection: Identifiable {
    @Attribute(.unique) public var id: UUID
    public var weekStartDate: Date
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), weekStartDate: Date = Date(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.weekStartDate = weekStartDate
        self.text = text
        self.createdAt = createdAt
    }
}

extension WeeklyReflection {
    public static func snapshot(text: String) -> WeeklyReflection {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekStart = calendar.date(from: components) ?? now
        return WeeklyReflection(weekStartDate: weekStart, text: text)
    }
}
