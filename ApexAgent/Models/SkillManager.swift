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
        let skillsDir = ApexAgentStoragePaths.skills

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
        let skillsDir = ApexAgentStoragePaths.skills

        try? fileManager.removeItem(at: skillsDir.appendingPathComponent(skill.name + ".sh"))
        try? fileManager.removeItem(at: skillsDir.appendingPathComponent(skill.name + ".json"))

        modelContext?.delete(skill)
        try? modelContext?.save()
        DynamicToolbox.shared.loadTools()
    }

    // MARK: - Validation

    public func validateSkillManifest(at fileURL: URL) -> Result<SkillManifestInfo, SkillValidationError> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return .failure(.fileNotFound(fileURL.path))
        }

        guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
              let data = content.data(using: .utf8) else {
            return .failure(.unreadableFile(fileURL.path))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON("Failed to parse JSON dictionary"))
        }

        let skillName = fileURL.deletingPathExtension().lastPathComponent
        guard let desc = json["description"] as? String, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingDescription(skillName))
        }

        guard let script = json["script_path"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingScriptPath(skillName))
        }

        let resolvedScript = (script as NSString).expandingTildeInPath
        if !fm.fileExists(atPath: resolvedScript) && !fm.fileExists(atPath: fileURL.deletingLastPathComponent().appendingPathComponent(script).path) {
            return .failure(.scriptFileNotFound(script))
        }

        let paramDict = json["parameters"] as? [String: Any] ?? [:]
        let propCount = (paramDict["properties"] as? [String: Any])?.count ?? paramDict.count

        return .success(SkillManifestInfo(
            name: skillName,
            description: desc,
            scriptPath: script,
            parameterCount: propCount
        ))
    }

    // MARK: - Helpers

    var enabledSkills: [Skill] { skills.filter { $0.enabled } }
    func skill(named name: String) -> Skill? { skills.first { $0.name == name } }
}

// MARK: - Skill Manifest Pre-Flight Validator

public struct SkillManifestInfo: Sendable, Equatable {
    public let name: String
    public let description: String
    public let scriptPath: String
    public let parameterCount: Int
}

public enum SkillValidationError: LocalizedError, Sendable, Equatable {
    case fileNotFound(String)
    case unreadableFile(String)
    case invalidJSON(String)
    case missingDescription(String)
    case missingScriptPath(String)
    case scriptFileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "Skill manifest file not found: \(p)"
        case .unreadableFile(let p): return "Skill manifest file cannot be read: \(p)"
        case .invalidJSON(let err): return "Invalid JSON manifest: \(err)"
        case .missingDescription(let name): return "Skill '\(name)' manifest is missing 'description' field"
        case .missingScriptPath(let name): return "Skill '\(name)' manifest is missing 'script_path' field"
        case .scriptFileNotFound(let path): return "Executable script file referenced does not exist: \(path)"
        }
    }
}

extension SkillManifestInfo {
    public func formatAsMarkdown() -> String {
        var md = "### 🛠️ Skill Manifest: `\(name)`\n\n"
        md += "| Property | Value |\n"
        md += "|---|---|\n"
        md += "| Name | `\(name)` |\n"
        md += "| Description | \(description.prefix(200)) |\n"
        md += "| Script | `\(scriptPath)` |\n"
        md += "| Parameters | `\(parameterCount)` |\n"
        return md
    }
}
