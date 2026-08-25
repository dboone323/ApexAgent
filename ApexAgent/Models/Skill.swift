import Foundation
import SwiftData

// MARK: - Skill: A persisted skill definition (visible in Settings + available to Bots)

@Model
final class Skill {
    @Attribute(.unique) var name: String
    var descriptionText: String
    var scriptPath: String
    var parameterSchemaJSON: String
    var category: String            // "procedural", "custom", "mcp"
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date
    // O8: SKILL.md-style catalog fields (defaults keep SwiftData lightweight
    // migration working for stores created before these existed).
    var triggerTermsJSON: String = "[]"
    var requiredCapabilitiesJSON: String = "[]"
    var version: String = "1.0.0"

    init(name: String,
         descriptionText: String,
         scriptPath: String,
         parameterSchemaJSON: String,
         category: String = "custom",
         enabled: Bool = true) {
        self.name = name
        self.descriptionText = descriptionText
        self.scriptPath = scriptPath
        self.parameterSchemaJSON = parameterSchemaJSON
        self.category = category
        self.enabled = enabled
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
