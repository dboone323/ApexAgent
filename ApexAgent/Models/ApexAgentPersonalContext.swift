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

    /// Parses personal context from a USER.md markdown file.
    public static func from(markdown: String) -> ApexAgentPersonalContext {
        var name = "Daniel"
        var routines: [String] = []
        var goals: [String] = []
        var energyPeakHours: [Int] = []

        let lines = markdown.components(separatedBy: .newlines)
        var currentSection = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop(while: { $0 == "#" || $0 == " " }).lowercased()
                if heading.hasPrefix("name") {
                    let parts = trimmed.components(separatedBy: ":")
                    if parts.count > 1 {
                        name = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                } else if heading.contains("routine") {
                    currentSection = "routines"
                } else if heading.contains("goal") {
                    currentSection = "goals"
                } else if heading.contains("energy") || heading.contains("hour") {
                    currentSection = "energy"
                } else {
                    currentSection = ""
                }
                continue
            }

            if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
                let item = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if !item.isEmpty {
                    if currentSection == "routines" {
                        routines.append(item)
                    } else if currentSection == "goals" {
                        goals.append(item)
                    } else if currentSection == "energy" {
                        if let hour = Int(item.filter { $0.isNumber }) {
                            energyPeakHours.append(hour)
                        }
                    }
                }
            } else if trimmed.lowercased().hasPrefix("name:") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count > 1 {
                    name = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return ApexAgentPersonalContext(
            name: name,
            routines: routines.isEmpty ? live.routines : routines,
            goals: goals.isEmpty ? live.goals : goals,
            energyPeakHours: energyPeakHours.isEmpty ? live.energyPeakHours : energyPeakHours
        )
    }
}
