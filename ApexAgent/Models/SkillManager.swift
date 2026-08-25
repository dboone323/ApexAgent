import Foundation
import SwiftData
import Observation

// MARK: - SkillManager: discovers, persists, and syncs skills with DynamicToolbox

@MainActor
final class SkillManager: Observable {
    static let shared = SkillManager()

    var skills: [Skill] = []
    weak var modelContext: ModelContext?

    // MARK: - Disk sync

    func syncFromDisk() {
        guard let context = modelContext else { return }
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let skillsDir = homeDir.appendingPathComponent(".apex/skills")

        guard let files = try? fileManager.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) else { return }
        let jsonFiles = files.filter { $0.pathExtension == "json" }

        // Build a set of skill names present on disk (excluding auto-generated procedural ones)
        var diskNames: Set<String> = []

        for file in jsonFiles {
            let rawName = file.deletingPathExtension().lastPathComponent
            // Skip reflection-generated procedural skills — they live in SwiftData memory only
            if rawName.hasSuffix("_procedural") { continue }
            diskNames.insert(rawName)

            // Check whether this skill is already persisted
            let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.name == rawName })
            if let existing = try? context.fetch(descriptor).first {
                if existing.scriptPath != file.path {
                    existing.scriptPath = file.path
                    existing.updatedAt = Date()
                }
                continue
            }

            // New on disk — parse manifest and insert
            guard let content = try? String(contentsOf: file, encoding: .utf8),
                  let data = content.data(using: .utf8),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let desc = manifest["description"] as? String,
                  let scriptPath = manifest["script_path"] as? String else { continue }

            let paramsJSON: String
            if let params = manifest["parameters"] {
                if let pData = try? JSONSerialization.data(withJSONObject: params),
                   let pStr = String(data: pData, encoding: .utf8) {
                    paramsJSON = pStr
                } else {
                    paramsJSON = "{}"
                }
            } else {
                paramsJSON = "{}"
            }

            let skill = Skill(
                name: rawName,
                descriptionText: desc,
                scriptPath: scriptPath,
                parameterSchemaJSON: paramsJSON,
                category: "custom"
            )
            context.insert(skill)
        }

        // Prune skills whose manifest was deleted from disk (preserve procedural memories)
        let allSkills = (try? context.fetch(FetchDescriptor<Skill>())) ?? []
        for skill in allSkills {
            if !diskNames.contains(skill.name) {
                context.delete(skill)
            }
        }

        try? context.save()
        DynamicToolbox.shared.loadTools()
    }

    // MARK: - Enable / Disable / Delete

    func enable(_ skill: Skill) {
        skill.enabled = true
        skill.updatedAt = Date()
        try? modelContext?.save()
        DynamicToolbox.shared.loadTools()
    }

    func disable(_ skill: Skill) {
        skill.enabled = false
        skill.updatedAt = Date()
        try? modelContext?.save()
        DynamicToolbox.shared.loadTools()
    }

    func delete(_ skill: Skill) {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let skillsDir = homeDir.appendingPathComponent(".apex/skills")

        try? fileManager.removeItem(at: skillsDir.appendingPathComponent(skill.name + ".sh"))
        try? fileManager.removeItem(at: skillsDir.appendingPathComponent(skill.name + ".json"))

        modelContext?.delete(skill)
        try? modelContext?.save()
        DynamicToolbox.shared.loadTools()
    }

    // MARK: - Helpers

    var enabledSkills: [Skill] { skills.filter { $0.enabled } }
    func skill(named name: String) -> Skill? { skills.first { $0.name == name } }
}
