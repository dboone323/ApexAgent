import Foundation
import SharedKit

public struct ApexAgentPersonalContext: Sendable {
    public let name: String
    public let routines: [String]
    public let goals: [String]
    public let energyPeakHours: [Int]
    public let updatedAt: Date

    public init(
        name: String,
        routines: [String] = [],
        goals: [String] = [],
        energyPeakHours: [Int] = []
    ) {
        self.name = name
        self.routines = routines
        self.goals = goals
        self.energyPeakHours = energyPeakHours
        self.updatedAt = Date()
    }

    public static let live = ApexAgentPersonalContext(
        name: "Daniel",
        routines: ["Check morning brief", "Review FocusSessions", "Update weekly plan"],
        goals: ["Ship Momentum Phases 6-8", "Maintain ApexAgent usability", "Ship ApexAgent macOS 27 build"],
        energyPeakHours: [8, 9, 10, 11]
    )
}
