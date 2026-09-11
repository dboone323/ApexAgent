import Foundation

// MARK: - SkillCatalog: SKILL.md-style manifests + trigger-term matching (O8, port of OpenMausBot skill-library.ts)
//
// A bundled/user skill is a directory with manifest.json + SKILL.md. The
// manifest declares trigger terms and required capabilities; enabled skills
// whose trigger terms match the current turn get surfaced to the bot without
// changing any provider driver.

struct SkillManifest: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let description: String
    let defaultEnabled: Bool
    let triggerTerms: [String]
    let requiredCapabilities: [String]
}

enum SkillManifestError: Error, Equatable {
    case invalidManifest(String)
}

enum SkillCatalog {

    /// Lowercase kebab ids only — a folder name doubles as the id.
    static let safeIdPattern = #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#
    static let semVerPattern = #"^\d+\.\d+\.\d+$"#

    private static func strings(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        var out: [String] = []
        for item in array {
            guard let s = item as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            out.append(s.trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    private static func matches(_ string: String, _ pattern: String) -> Bool {
        string.range(of: pattern, options: .regularExpression) != nil
    }

    /// Validate + decode one manifest dictionary. Mirrors the upstream checks:
    /// id must be safe AND equal to the directory name; version must be semver;
    /// name/description non-empty; defaultEnabled required; ≥1 trigger term.
    static func parseManifest(_ value: Any, directoryName: String) throws -> SkillManifest {
        guard let raw = value as? [String: Any] else {
            throw SkillManifestError.invalidManifest("\(directoryName)/manifest.json is invalid")
        }
        let id = raw["id"] as? String ?? ""
        let triggerTerms = strings(raw["triggerTerms"])
        let requiredCapabilities = strings(raw["requiredCapabilities"])

        guard matches(id, safeIdPattern), id == directoryName.lowercased() || id == directoryName else {
            throw SkillManifestError.invalidManifest("\(directoryName)/manifest.json has an invalid id")
        }
        guard let name = raw["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SkillManifestError.invalidManifest("\(directoryName)/manifest.json has no name")
        }
        guard let version = raw["version"] as? String, matches(version, semVerPattern) else {
            throw SkillManifestError.invalidManifest("\(directoryName)/manifest.json has an invalid version")
        }
        guard let description = raw["description"] as? String,
              !description.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SkillManifestError.invalidManifest("\(directoryName)/manifest.json has no description")
        }
        guard let defaultEnabled = raw["defaultEnabled"] as? Bool else {
            throw SkillManifestError.invalidManifest("\(directoryName)/manifest.json has no defaultEnabled flag")
        }
        guard let triggerTerms, !triggerTerms.isEmpty else {
            throw SkillManifestError.invalidManifest("\(directoryName)/manifest.json has no trigger terms")
        }
        guard let requiredCapabilities else {
            throw SkillManifestError.invalidManifest("\(directoryName)/manifest.json has invalid capabilities")
        }
        return SkillManifest(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            version: version,
            description: description.trimmingCharacters(in: .whitespaces),
            defaultEnabled: defaultEnabled,
            triggerTerms: triggerTerms,
            requiredCapabilities: requiredCapabilities)
    }

    /// Load every valid skill directory under `root`; invalid folders are
    /// isolated (skipped) instead of taking down the bot turn.
    static func loadSkills(root: URL) -> [(manifest: SkillManifest, instructions: String)] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var skills: [(SkillManifest, String)] = []
        for name in names.sorted() {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) else { continue }
            let manifestUrl = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestUrl),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            guard let manifest = try? parseManifest(json, directoryName: name) else { continue }
            let instructions = (try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !instructions.isEmpty else { continue }
            skills.append((manifest, instructions))
        }
        return skills
    }

    /// The enabled skills whose trigger terms appear in the prompt.
    /// An empty `enabledIds` falls back to each manifest's defaultEnabled.
    static func matchingSkills(
        prompt: String,
        skills: [(manifest: SkillManifest, instructions: String)],
        enabledIds: Set<String> = []
    ) -> [SkillManifest] {
        let loweredPrompt = prompt.lowercased()
        return skills.compactMap { entry in
            let isEnabled = enabledIds.isEmpty
                ? entry.manifest.defaultEnabled
                : enabledIds.contains(entry.manifest.id)
            guard isEnabled else { return nil }
            let hit = entry.manifest.triggerTerms.contains { term in
                loweredPrompt.contains(term.lowercased())
            }
            return hit ? entry.manifest : nil
        }
    }

    // MARK: Skill model (SwiftData) helpers

    static func decodeTerms(fromJSON json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    static func encodeTerms(_ terms: [String]) -> String {
        guard let data = try? JSONEncoder().encode(terms) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
