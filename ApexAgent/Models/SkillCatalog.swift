import Foundation

// MARK: - SkillCatalog: SKILL.md-style manifests + trigger-term matching
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

    /// Synthesizes a valid SkillManifest from SKILL.md YAML frontmatter when manifest.json is absent.
    /// Supports standard YAML frontmatter (---\nname: ...\ndescription: ...\n---)
    static func synthesizeManifestFromFrontmatter(instructions: String, directoryName: String) -> SkillManifest? {
        let safeId = directoryName.lowercased()
        guard matches(safeId, safeIdPattern) else { return nil }

        var name = directoryName.replacingOccurrences(of: "-", with: " ").capitalized
        var description = "Skill instructions loaded from \(directoryName)/SKILL.md"
        var triggerTerms: [String] = [safeId, name.lowercased()]

        let lines = instructions.components(separatedBy: .newlines)
        if let firstLine = lines.first?.trimmingCharacters(in: .whitespaces), firstLine == "---" {
            var inFrontmatter = true
            var fmLines: [String] = []
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    inFrontmatter = false
                    break
                }
                fmLines.append(line)
            }
            if !inFrontmatter {
                for line in fmLines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("name:") {
                        let val = trimmed.dropFirst("name:".count)
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
                        if !val.isEmpty {
                            name = val
                            if !triggerTerms.contains(val.lowercased()) {
                                triggerTerms.append(val.lowercased())
                            }
                        }
                    } else if trimmed.hasPrefix("description:") {
                        let val = trimmed.dropFirst("description:".count)
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
                        if !val.isEmpty {
                            description = val
                        }
                    } else if trimmed.hasPrefix("triggers:") {
                        let val = trimmed.dropFirst("triggers:".count).trimmingCharacters(in: .whitespaces)
                        let parsed = val.components(separatedBy: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                              .trimmingCharacters(in: CharacterSet(charactersIn: "[]\"\'"))
                              .lowercased()
                        }.filter { !$0.isEmpty }
                        for t in parsed {
                            if !triggerTerms.contains(t) {
                                triggerTerms.append(t)
                            }
                        }
                    }
                }
            }
        }

        let parts = safeId.split(separator: "-").map(String.init).filter { $0.count >= 3 }
        for p in parts {
            if !triggerTerms.contains(p) {
                triggerTerms.append(p)
            }
        }

        return SkillManifest(
            id: safeId,
            name: name,
            version: "1.0.0",
            description: description,
            defaultEnabled: true,
            triggerTerms: triggerTerms,
            requiredCapabilities: []
        )
    }

    /// Load every valid skill directory under `root`; invalid folders are
    /// isolated (skipped) and corrupt `manifest.json` files are moved aside
    /// to `manifest.json.corrupt-<ts>` via ``ResilientJSONStore``.
    /// If `manifest.json` is missing, synthesizes a manifest from `SKILL.md` frontmatter.
    static func loadSkills(root: URL) -> [(manifest: SkillManifest, instructions: String)] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var skills: [(SkillManifest, String)] = []
        for name in names.sorted() {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let manifestUrl = dir.appendingPathComponent("manifest.json")
            let skillMdUrl = dir.appendingPathComponent("SKILL.md")

            var manifest: SkillManifest?

            if fileManager.fileExists(atPath: manifestUrl.path) {
                guard let json = ResilientJSONStore.shared.loadJSONObject(from: manifestUrl, subsystem: "SkillCatalog") else {
                    continue
                }
                do {
                    manifest = try parseManifest(json, directoryName: name)
                } catch {
                    ResilientJSONStore.shared.quarantineCorruptFile(
                        at: manifestUrl,
                        subsystem: "SkillCatalog",
                        errorDescription: String(describing: error)
                    )
                    continue
                }
            }

            guard fileManager.fileExists(atPath: skillMdUrl.path) else { continue }
            let instructions = (try? String(contentsOf: skillMdUrl, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !instructions.isEmpty else { continue }

            if manifest == nil {
                manifest = synthesizeManifestFromFrontmatter(instructions: instructions, directoryName: name)
            }

            guard let finalManifest = manifest else { continue }
            skills.append((finalManifest, instructions))
        }
        return skills
    }

    static func saveManifest(_ manifest: SkillManifest, to url: URL) throws {
        try ResilientJSONStore.shared.save(manifest, to: url, prettyPrinted: true)
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

    /// Discovers all available skills across standard locations:
    /// 1. User directory: ~/.apex/skills
    /// 2. Workspace directories: <workspacePath>/.agents/skills and <workspacePath>/.apex/skills
    static func discoverAllSkills(workspacePath: String? = nil) -> [(manifest: SkillManifest, instructions: String)] {
        var results: [(manifest: SkillManifest, instructions: String)] = []
        var seenIds = Set<String>()

        var roots: [URL] = [ApexAgentStoragePaths.skills]
        if let ws = workspacePath, !ws.isEmpty {
            let wsUrl = URL(fileURLWithPath: ws)
            roots.append(wsUrl.appendingPathComponent(".agents/skills", isDirectory: true))
            roots.append(wsUrl.appendingPathComponent(".apex/skills", isDirectory: true))
        }

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let loaded = loadSkills(root: root)
            for item in loaded {
                if !seenIds.contains(item.manifest.id) {
                    seenIds.insert(item.manifest.id)
                    results.append(item)
                }
            }
        }
        return results
    }

    /// Evaluates prompt against all available skills (user ~/.apex/skills and workspace .agents/skills)
    /// and formats instructional context to inject into an agent's turn.
    static func skillInstructions(for prompt: String, workspacePath: String? = nil) -> String {
        let skills = discoverAllSkills(workspacePath: workspacePath)
        guard !skills.isEmpty else { return "" }

        let matching = matchingSkills(prompt: prompt, skills: skills)
        if !matching.isEmpty {
            var section = "### 🛠️ Activated Skills for this Turn\n"
            section += "The following skills match the current user intent. Follow their workflows and principles strictly:\n\n"
            for m in matching {
                if let entry = skills.first(where: { $0.manifest.id == m.id }) {
                    section += "#### Skill: \(m.name) (`\(m.id)` v\(m.version))\n"
                    section += entry.instructions + "\n\n"
                }
            }
            return section.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            var summary = "### 🧩 Available Skills Catalog\n"
            summary += "You have access to the following specialized skills if needed for this project:\n"
            for skill in skills {
                summary += "- **\(skill.manifest.name)** (`\(skill.manifest.id)`): \(skill.manifest.description)\n"
            }
            return summary.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - Markdown Manifest Table

    static func exportManifestsMarkdown(_ manifests: [SkillManifest]) -> String {
        guard !manifests.isEmpty else {
            return "No skills currently discovered or installed."
        }

        var md = "### 🧩 Skills Catalog & Trigger Manifests (\(manifests.count) skills)\n\n"
        md += "| Skill ID | Name | Version | Triggers | Default | Required Capabilities |\n"
        md += "|---|---|---|---|---|---|\n"

        for m in manifests {
            let triggers = m.triggerTerms.joined(separator: ", ").replacingOccurrences(of: "|", with: "\\|")
            let caps = m.requiredCapabilities.isEmpty ? "None" : m.requiredCapabilities.joined(separator: ", ").replacingOccurrences(of: "|", with: "\\|")
            let defaultBadge = m.defaultEnabled ? "✅ Enabled" : "⚪️ Disabled"
            md += "| `\(m.id)` | **\(m.name)** | `v\(m.version)` | `\(triggers)` | \(defaultBadge) | `\(caps)` |\n"
        }
        return md
    }

}