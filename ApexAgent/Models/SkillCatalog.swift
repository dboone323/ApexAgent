import Foundation
import SharedModels
import SharedLogging

// MARK: - Skill Disclosure Stages & Progressive Skills (Issue #88)

public enum SkillDisclosureStage: String, Codable, Sendable, Equatable {
    case metadataOnly = "metadata_only"
    case fullContentLoaded = "full_content_loaded"
    case invoked = "invoked"
}

public enum ProgressiveSkillSource: Sendable, Equatable {
    case filesystem(directoryURL: URL)
    case mcp(serverId: UUID, serverName: String, toolName: String)

    public var isMCP: Bool {
        if case .mcp = self { return true }
        return false
    }
}

public struct ProgressiveSkill: @unchecked Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let triggerTerms: [String]
    public let requiredCapabilities: [String]
    public let source: ProgressiveSkillSource
    public var stage: SkillDisclosureStage
    public var instructions: String?
    public var parameterSchema: [String: Any]?
    public var permissionManifest: SkillPermissionManifest?
    public var isKilled: Bool
    public var scriptPath: String?

    public init(
        id: String,
        name: String,
        version: String = "1.0.0",
        description: String,
        triggerTerms: [String] = [],
        requiredCapabilities: [String] = [],
        source: ProgressiveSkillSource,
        stage: SkillDisclosureStage = .metadataOnly,
        instructions: String? = nil,
        parameterSchema: [String: Any]? = nil,
        permissionManifest: SkillPermissionManifest? = nil,
        isKilled: Bool = false,
        scriptPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.triggerTerms = triggerTerms
        self.requiredCapabilities = requiredCapabilities
        self.source = source
        self.stage = stage
        self.instructions = instructions
        self.parameterSchema = parameterSchema
        self.permissionManifest = permissionManifest
        self.isKilled = isKilled
        self.scriptPath = scriptPath
    }

    public var isFullContentLoaded: Bool {
        stage == .fullContentLoaded || stage == .invoked
    }

    public mutating func loadFullContent() throws {
        guard stage == .metadataOnly else { return }

        if SkillSecurityManager.shared.isKilled(name: id) {
            let reason = SkillSecurityManager.shared.killReason(for: id) ?? "Disabled by kill-switch"
            throw NSError(
                domain: "SkillSecurity",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Cannot load content for skill '\(id)': disabled by kill-switch (\(reason))"]
            )
        }

        switch source {
        case .filesystem(let dir):
            let skillMd = dir.appendingPathComponent("SKILL.md")
            if FileManager.default.fileExists(atPath: skillMd.path) {
                let content = (try? String(contentsOf: skillMd, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.instructions = content
            } else {
                self.instructions = "# \(name)\n\(description)"
            }
            self.stage = .fullContentLoaded

        case .mcp(_, let serverName, let toolName):
            var text = "# MCP Skill: \(name) (`\(id)`)\n"
            text += "Source: MCP Server '\(serverName)'\n"
            text += "Tool: `\(toolName)`\n\n"
            text += "## Description\n\(description)\n\n"
            if let schema = parameterSchema,
               let data = try? JSONSerialization.data(withJSONObject: schema, options: .prettyPrinted),
               let schemaStr = String(data: data, encoding: .utf8) {
                text += "## Parameters Schema\n```json\n\(schemaStr)\n```\n"
            }
            self.instructions = text
            self.stage = .fullContentLoaded
        }
    }

    public mutating func invoke(arguments: String) async throws -> String {
        if stage == .metadataOnly {
            try loadFullContent()
        }

        if SkillSecurityManager.shared.isKilled(name: id) {
            let reason = SkillSecurityManager.shared.killReason(for: id) ?? "Disabled by kill-switch"
            throw NSError(
                domain: "SkillSecurity",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Skill '\(id)' execution refused: disabled by kill-switch (\(reason))"]
            )
        }

        switch source {
        case .filesystem(let dir):
            let effectiveScript = scriptPath ?? dir.appendingPathComponent("\(id).sh").path
            if FileManager.default.fileExists(atPath: effectiveScript) {
                try SkillSecurityManager.shared.validateExecution(
                    name: id,
                    scriptPath: effectiveScript,
                    workspacePath: dir.path
                )
                let result = try await executeDynamicScript(
                    scriptPath: effectiveScript,
                    jsonArguments: arguments
                )
                self.stage = .invoked
                if result.exitCode == 0 {
                    return result.stdout
                } else {
                    return "Execution failed (code \(result.exitCode))\nstdout: \(result.stdout)\nstderr: \(result.stderr)"
                }
            } else {
                self.stage = .invoked
                return instructions ?? description
            }

        case .mcp(let serverId, _, let toolName):
            if SkillSecurityManager.shared.isKilled(name: toolName) {
                let reason = SkillSecurityManager.shared.killReason(for: toolName) ?? "Disabled by kill-switch"
                throw NSError(
                    domain: "SkillSecurity",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "MCP Tool '\(toolName)' execution refused: disabled by kill-switch (\(reason))"]
                )
            }
            let config = await MainActor.run {
                MCPManager.shared.servers.first(where: { $0.id == serverId })
            }
            guard let serverConfig = config else {
                throw NSError(
                    domain: "MCPSkill",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "MCP Server not found for skill '\(id)'"]
                )
            }
            let client = await MainActor.run {
                MCPManager.shared.getClient(for: serverConfig)
            }
            try await client.start()
            let data = arguments.data(using: .utf8) ?? Data()
            let argsDict = (try? JSONDecoder().decode([String: AnyCodable].self, from: data)) ?? [:]
            let callResult = try await client.callTool(name: toolName, arguments: argsDict)
            self.stage = .invoked
            let texts = callResult.content.compactMap { $0.text }
            if callResult.isError == true {
                return "ERROR: " + texts.joined(separator: "\n")
            }
            return texts.joined(separator: "\n")
        }
    }

    public static func == (lhs: ProgressiveSkill, rhs: ProgressiveSkill) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.version == rhs.version &&
        lhs.description == rhs.description &&
        lhs.triggerTerms == rhs.triggerTerms &&
        lhs.requiredCapabilities == rhs.requiredCapabilities &&
        lhs.source == rhs.source &&
        lhs.stage == rhs.stage &&
        lhs.instructions == rhs.instructions &&
        lhs.isKilled == rhs.isKilled &&
        lhs.scriptPath == rhs.scriptPath
    }
}

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
            // Issue #107: A killed skill must never match or activate
            guard !SkillSecurityManager.shared.isKilled(name: entry.manifest.id) else { return nil }

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

    // MARK: - Progressive Disclosure & MCP Skills (Issue #88)

    /// Reads frontmatter only from a SKILL.md file without loading the entire body into memory.
    static func readFrontmatterOnly(from fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 4096)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first == "---" else {
            return nil
        }
        var fmLines = [first]
        for line in lines.dropFirst() {
            fmLines.append(line)
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                break
            }
        }
        return fmLines.joined(separator: "\n")
    }

    /// Loads skills under `root` with progressive disclosure: metadata only is loaded,
    /// full markdown instructions are NOT loaded into memory until requested or invoked.
    public static func loadProgressiveSkills(root: URL) -> [ProgressiveSkill] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var skills: [ProgressiveSkill] = []

        for name in names.sorted() {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let manifestUrl = dir.appendingPathComponent("manifest.json")
            let skillMdUrl = dir.appendingPathComponent("SKILL.md")

            var manifest: SkillManifest?
            var permManifest: SkillPermissionManifest?

            if fileManager.fileExists(atPath: manifestUrl.path) {
                guard let json = ResilientJSONStore.shared.loadJSONObject(from: manifestUrl, subsystem: "SkillCatalog") else {
                    continue
                }
                do {
                    manifest = try parseManifest(json, directoryName: name)
                    if let dict = json as? [String: Any] {
                        permManifest = SkillPermissionManifest.from(dictionary: dict)
                    }
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

            if manifest == nil {
                if let fm = readFrontmatterOnly(from: skillMdUrl) {
                    manifest = synthesizeManifestFromFrontmatter(instructions: fm, directoryName: name)
                }
            }

            guard let finalManifest = manifest else { continue }
            let isKilled = SkillSecurityManager.shared.isKilled(name: finalManifest.id)

            let scriptPath = dir.appendingPathComponent("\(finalManifest.id).sh").path
            let hasScript = fileManager.fileExists(atPath: scriptPath)

            let skill = ProgressiveSkill(
                id: finalManifest.id,
                name: finalManifest.name,
                version: finalManifest.version,
                description: finalManifest.description,
                triggerTerms: finalManifest.triggerTerms,
                requiredCapabilities: finalManifest.requiredCapabilities,
                source: .filesystem(directoryURL: dir),
                stage: .metadataOnly,
                instructions: nil, // Full content NOT loaded until invoked
                parameterSchema: nil,
                permissionManifest: permManifest,
                isKilled: isKilled,
                scriptPath: hasScript ? scriptPath : nil
            )
            skills.append(skill)
        }
        return skills
    }

    /// Discovers skills served over real local stdio MCP servers.
    public static func discoverMCPSkills() async -> [ProgressiveSkill] {
        var results: [ProgressiveSkill] = []
        let servers = await MainActor.run { MCPManager.shared.servers }
        for server in servers {
            let client = await MainActor.run { MCPManager.shared.getClient(for: server) }
            do {
                try await client.start()
                let tools = try await client.listTools()
                for tool in tools {
                    let safeServerName = server.name.lowercased().replacingOccurrences(of: " ", with: "-")
                    let safeToolName = tool.name.lowercased().replacingOccurrences(of: " ", with: "-")
                    let skillId = "mcp-\(safeServerName)-\(safeToolName)"
                    let isKilled = SkillSecurityManager.shared.isKilled(name: skillId)
                        || SkillSecurityManager.shared.isKilled(name: tool.name)

                    var triggers = [tool.name.lowercased()]
                    let toolDesc = tool.description ?? ""
                    let words = toolDesc.components(separatedBy: CharacterSet.alphanumerics.inverted)
                        .map { $0.lowercased() }
                        .filter { $0.count >= 4 }
                    for w in words.prefix(5) {
                        if !triggers.contains(w) { triggers.append(w) }
                    }

                    let permManifest = SkillPermissionManifest(
                        name: skillId,
                        version: "1.0.0",
                        description: toolDesc,
                        permissions: SkillPermissions(tools: [tool.name], allowNetwork: false, filesystemPaths: [], allowShell: false)
                    )

                    var schemaDict: [String: Any]? = nil
                    if let data = try? JSONEncoder().encode(tool.inputSchema),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        schemaDict = obj
                    }

                    let skill = ProgressiveSkill(
                        id: skillId,
                        name: tool.annotations?.title ?? tool.name,
                        version: "1.0.0",
                        description: toolDesc,
                        triggerTerms: triggers,
                        requiredCapabilities: ["mcp"],
                        source: .mcp(serverId: server.id, serverName: server.name, toolName: tool.name),
                        stage: .metadataOnly,
                        instructions: nil, // Full content NOT loaded until invoked
                        parameterSchema: schemaDict,
                        permissionManifest: permManifest,
                        isKilled: isKilled
                    )
                    results.append(skill)
                }
            } catch {
                AppLog.error(.toolbox, "Failed to discover MCP skills from \(server.name): \(error.localizedDescription)")
            }
        }
        return results
    }

    /// Discovers all available skills (filesystem and MCP) with progressive disclosure.
    public static func discoverProgressiveSkills(
        workspacePath: String? = nil,
        includeMCP: Bool = true
    ) async -> [ProgressiveSkill] {
        var results: [ProgressiveSkill] = []
        var seenIds = Set<String>()

        var roots: [URL] = [ApexAgentStoragePaths.skills]
        if let ws = workspacePath, !ws.isEmpty {
            let wsUrl = URL(fileURLWithPath: ws)
            roots.append(wsUrl.appendingPathComponent(".agents/skills", isDirectory: true))
            roots.append(wsUrl.appendingPathComponent(".apex/skills", isDirectory: true))
        }

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let loaded = loadProgressiveSkills(root: root)
            for item in loaded {
                if !seenIds.contains(item.id) {
                    seenIds.insert(item.id)
                    results.append(item)
                }
            }
        }

        if includeMCP {
            let mcpSkills = await discoverMCPSkills()
            for item in mcpSkills {
                if !seenIds.contains(item.id) {
                    seenIds.insert(item.id)
                    results.append(item)
                }
            }
        }

        return results
    }

    /// Finds a progressive skill by ID across discovered locations.
    public static func findProgressiveSkill(
        id: String,
        workspacePath: String? = nil
    ) async throws -> ProgressiveSkill {
        let all = await discoverProgressiveSkills(workspacePath: workspacePath)
        if let found = all.first(where: { $0.id == id || $0.name.lowercased() == id.lowercased() }) {
            return found
        }
        throw NSError(
            domain: "SkillCatalog",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Skill '\(id)' not found in discovered skills"]
        )
    }

    /// Loads the full content of a progressive skill on demand.
    public static func loadSkillContent(
        id: String,
        workspacePath: String? = nil
    ) async throws -> ProgressiveSkill {
        var skill = try await findProgressiveSkill(id: id, workspacePath: workspacePath)
        try skill.loadFullContent()
        return skill
    }

    /// Invokes a skill by ID through the progressive disclosure execution path.
    public static func invokeSkill(
        id: String,
        arguments: String,
        workspacePath: String? = nil
    ) async throws -> String {
        var skill = try await findProgressiveSkill(id: id, workspacePath: workspacePath)
        return try await skill.invoke(arguments: arguments)
    }

}