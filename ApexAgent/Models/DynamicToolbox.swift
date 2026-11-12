import Foundation
import Darwin

// MARK: - §153 TestData retention: delete-on-exit + 7-day sweep backstop

/// Deletes this process's `$TMPDIR/ApexAgent-TestData-<pid>/` directory on process exit.
/// Registered via `atexit` when the storage root is first accessed in test mode.
func deleteTestDataOnExit() {
    guard KeychainManager.isTestProcess else { return }
    let testDataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApexAgent-TestData-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    try? FileManager.default.removeItem(at: testDataDir)
}

/// Sweeps stale `ApexAgent-TestData-*` folders from `$TMPDIR` as a 7-day backstop.
/// Never deletes a folder belonging to a live PID (checked via `kill(pid, 0)`).
/// Returns (deletedCount, skippedCount).
func sweepStaleTestData(maxAgeDays: Int = 7) -> (deleted: Int, skipped: Int) {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory
    guard let items = try? fm.contentsOfDirectory(
        at: tmpDir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return (0, 0)
    }
    let cutoff = Date().addingTimeInterval(-TimeInterval(maxAgeDays * 24 * 60 * 60))
    var deleted = 0
    var skipped = 0
    let prefix = "ApexAgent-TestData-"
    for item in items {
        let name = item.lastPathComponent
        guard name.hasPrefix(prefix) else { continue }
        let pidSubstring = name.dropFirst(prefix.count)
        guard let pidInt = Int(pidSubstring), pidInt > 0 else {
            skipped += 1
            continue
        }
        let pid = pid_t(pidInt)
        // Never delete a folder belonging to a live PID.
        // kill(pid, 0) == 0 means the process exists.
        // EPERM means it exists but we can't signal it (still alive — skip).
        if kill(pid, 0) == 0 || errno == EPERM {
            skipped += 1
            continue
        }
        // Age check: only delete folders older than maxAgeDays.
        let attrs = try? item.resourceValues(forKeys: [.contentModificationDateKey])
        let modDate = attrs?.contentModificationDate ?? Date.distantPast
        if modDate < cutoff {
            try? fm.removeItem(at: item)
            deleted += 1
        } else {
            skipped += 1
        }
    }
    return (deleted, skipped)
}

enum ApexAgentStoragePaths {
    /// One-time registration of the delete-on-exit atexit handler for test-mode TestData cleanup.
    private static let registerExitCleanup: Void = {
        if KeychainManager.isTestProcess {
            atexit(deleteTestDataOnExit)
        }
    }()

    private static var root: URL {
        if KeychainManager.isTestProcess {
            _ = Self.registerExitCleanup
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ApexAgent-TestData-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent(".apex", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".apex", isDirectory: true)
    }

    static var apex: URL { root }

    static func directory(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    static var auditLogs: URL { directory("logs") }
    static var collaborationLogs: URL {
        KeychainManager.isTestProcess
            ? auditLogs
            : FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/ApexAgent", isDirectory: true)
    }

    static var tools: URL { directory("tools") }
    static var skills: URL { directory("skills") }
    static var scriptDirectories: [URL] { [tools, skills] }

    static func skillScriptReference(for name: String) -> String {
        KeychainManager.isTestProcess
            ? skills.appendingPathComponent("\(name).sh").path
            : "~/.apex/skills/\(name).sh"
    }
}

@MainActor
class DynamicToolbox {
    static let shared = DynamicToolbox()

    var orchestrator: OrchestratorProvider?

    init() {
        // §153: 7-day sweep backstop — remove stale TestData folders from previous runs.
        // Never deletes a folder belonging to a live PID (enforced inside sweepStaleTestData).
        let result = sweepStaleTestData(maxAgeDays: 7)
        AppLog.info(.toolbox, "TestData retention sweep: deleted \(result.deleted), skipped \(result.skipped)")
    }

    struct DynamicToolEntry {
        let name: String
        let description: String
        let scriptPath: String? // nil for MCP tools
        let schema: [String: Any]
        let mcpServerId: UUID? // nil for script-based tools
        let annotations: MCPToolAnnotations?

        init(
            name: String,
            description: String,
            scriptPath: String?,
            schema: [String: Any],
            mcpServerId: UUID?,
            annotations: MCPToolAnnotations? = nil
        ) {
            self.name = name
            self.description = description
            self.scriptPath = scriptPath
            self.schema = schema
            self.mcpServerId = mcpServerId
            self.annotations = annotations
        }
    }

    private(set) var dynamicTools: [String: DynamicToolEntry] = [:]

    func toolAnnotations(for name: String) -> MCPToolAnnotations? {
        dynamicTools[name]?.annotations
    }

    func requiresConfirmation(for name: String) -> Bool {
        guard let annotations = dynamicTools[name]?.annotations else { return false }
        if annotations.isDestructive { return true }
        if annotations.isReadOnly { return false }
        return false
    }

    @discardableResult
    func registerMCPTool(_ tool: MCPToolDefinition, serverId: UUID, serverName: String = "MCP") -> DynamicToolEntry {
        var properties: [String: Any] = [:]
        if let props = tool.inputSchema.properties {
            for (k, v) in props {
                properties[k] = [
                    "type": v.type,
                    "description": v.description ?? ""
                ]
            }
        }

        var schema: [String: Any] = [
            "name": tool.name,
            "description": tool.description ?? "",
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": tool.inputSchema.required ?? []
            ]
        ]
        if let annotations = tool.annotations {
            schema["annotations"] = [
                "title": annotations.title as Any,
                "readOnlyHint": annotations.readOnlyHint as Any,
                "destructiveHint": annotations.destructiveHint as Any,
                "idempotentHint": annotations.idempotentHint as Any,
                "openWorldHint": annotations.openWorldHint as Any
            ]
        }

        let entry = DynamicToolEntry(
            name: tool.name,
            description: tool.description ?? "",
            scriptPath: nil,
            schema: schema,
            mcpServerId: serverId,
            annotations: tool.annotations
        )
        dynamicTools[tool.name] = entry
        AppLog.info(.toolbox, "Loaded MCP tool: \(tool.name) from server \(serverName)")
        return entry
    }

    private var dirDescriptor: Int32 = -1
    private var watcherSource: DispatchSourceFileSystemObject?
    private var loadMCPToolsTask: Task<Void, Never>?

    func loadTools() {
        dynamicTools.removeAll()
        loadMCPToolsTask?.cancel()
        loadMCPToolsTask = nil
        if ProcessInfo.processInfo.environment["APEX_DISABLE_DYNAMIC_TOOLS"] == "1" {
            AppLog.notice(.toolbox, "Dynamic tool loading is disabled for this process.")
            return
        }

        let fileManager = FileManager.default
        let toolsDir = ApexAgentStoragePaths.tools
        let skillsDir = ApexAgentStoragePaths.skills

        // Ensure directories exist
        for dir in [toolsDir, skillsDir] {
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            }
        }

        // 1. Load custom tools
        loadScriptsFromDir(toolsDir)

        // 2. Load dynamically created skills
        loadScriptsFromDir(skillsDir)

        // 3. Load MCP tools asynchronously (skipped in test mode and in CLI mode when
        // the prompt does not require external MCP servers, preventing duplicate server
        // startup and 96-schema token bloat on standard CLI invocations)
        let isTesting = getenv("APEX_TEST_MODE") != nil
            || ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("xctest")
            || NSClassFromString("XCTestCase") != nil
        let args = CommandLine.arguments
        let isSkippedForCLI: Bool
        if let cliIdx = args.firstIndex(of: "--cli"), cliIdx + 1 < args.count {
            let cliPrompt = args[(cliIdx + 1)...].joined(separator: " ")
            isSkippedForCLI = !IntentToolSelector.requiresMCPServers(for: cliPrompt)
        } else {
            isSkippedForCLI = false
        }
        if !isTesting && !isSkippedForCLI {
            loadMCPToolsTask = Task { await loadMCPTools() }
        }
    }

    private func loadScriptsFromDir(_ dir: URL) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }

        for file in files {
            guard file.pathExtension == "json" || file.pathExtension == "yaml" || file.pathExtension == "yml" else {
                continue
            }

            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }

            var manifest: [String: Any]?
            if file.pathExtension == "json" {
                if let data = content.data(using: .utf8) {
                    manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
            } else {
                manifest = parseYAML(content)
            }

            guard let parsed = manifest,
                  let name = parsed["name"] as? String,
                  let scriptPath = parsed["script_path"] as? String else {
                continue
            }

            // Clean schema for LLM (removing script_path)
            var llmSchema = parsed
            llmSchema.removeValue(forKey: "script_path")

            let entry = DynamicToolEntry(
                name: name,
                description: parsed["description"] as? String ?? "",
                scriptPath: scriptPath,
                schema: llmSchema,
                mcpServerId: nil
            )
            dynamicTools[name] = entry
            AppLog.info(.toolbox, "Loaded dynamic script tool: \(name) -> \(scriptPath)")
        }
    }

    func loadMCPTools() async {
        // Filter out existing MCP tools from registry before reloading
        dynamicTools = dynamicTools.filter { $0.value.mcpServerId == nil }

        for config in MCPManager.shared.servers {
            if Task.isCancelled { return }
            let client = MCPManager.shared.getClient(for: config)
            do {
                try await client.start()
                if Task.isCancelled { return }
                let toolsList = try await client.listTools()
                if Task.isCancelled { return }
                for tool in toolsList {
                    registerMCPTool(tool, serverId: config.id, serverName: config.name)
                }
            } catch {
                AppLog.error(.toolbox, "Failed to load tools from MCP server \(config.name): \(error)")
            }
        }
    }

    func startWatcher() {
        stopWatcher()

        let fileManager = FileManager.default
        let toolsDir = ApexAgentStoragePaths.tools

        if !fileManager.fileExists(atPath: toolsDir.path) {
            try? fileManager.createDirectory(at: toolsDir, withIntermediateDirectories: true, attributes: nil)
        }

        dirDescriptor = open(toolsDir.path, O_EVTONLY)
        guard dirDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirDescriptor,
            eventMask: .write,
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            AppLog.info(.toolbox, "Dynamic tool directory changed; reloading dynamic tools.")
            self.loadTools()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.dirDescriptor >= 0 {
                close(self.dirDescriptor)
                self.dirDescriptor = -1
            }
        }

        self.watcherSource = source
        source.resume()
    }

    func stopWatcher() {
        watcherSource?.cancel()
        watcherSource = nil
    }

    func executeTool(name: String, jsonArguments: String) async throws -> String {
        guard let tool = dynamicTools[name] else {
            throw NSError(domain: "DynamicToolbox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tool \(name) not found in dynamic tools"])
        }

        // Validate JSON arguments and schema before server or script dispatch
        guard let data = jsonArguments.data(using: .utf8),
              let argsDict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            throw NSError(domain: "DynamicToolbox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON arguments for tool \(name)"])
        }

        if let params = tool.schema["parameters"] as? [String: Any] {
            let properties = (params["properties"] as? [String: Any]) ?? [:]
            let required = (params["required"] as? [String]) ?? []

            for req in required {
                if argsDict[req] == nil {
                    throw NSError(domain: "DynamicToolbox", code: -2, userInfo: [
                        NSLocalizedDescriptionKey: "Tool '\(name)' invocation failed schema validation: missing required parameter '\(req)'"
                    ])
                }
            }

            if !properties.isEmpty {
                for (key, val) in argsDict {
                    guard let propDef = properties[key] as? [String: Any] else {
                        throw NSError(domain: "DynamicToolbox", code: -3, userInfo: [
                            NSLocalizedDescriptionKey: "Tool '\(name)' invocation failed schema validation: undeclared parameter '\(key)'"
                        ])
                    }
                    if let expectedType = propDef["type"] as? String {
                        if !Self.matchesType(value: val.value, expectedType: expectedType) {
                            throw NSError(domain: "DynamicToolbox", code: -4, userInfo: [
                                NSLocalizedDescriptionKey: "Tool '\(name)' invocation failed schema validation: parameter '\(key)' expected type '\(expectedType)' but received '\(type(of: val.value))'"
                            ])
                        }
                    }
                }
            }
        }

        if let mcpServerId = tool.mcpServerId {
            guard let config = MCPManager.shared.servers.first(where: { $0.id == mcpServerId }) else {
                throw NSError(domain: "DynamicToolbox", code: -1, userInfo: [NSLocalizedDescriptionKey: "MCP Server config not found"])
            }
            let client = MCPManager.shared.getClient(for: config)

            let result = try await client.callTool(name: name, arguments: argsDict)
            let texts = result.content.compactMap { $0.text }
            if result.isError == true {
                return "ERROR: " + texts.joined(separator: "\n")
            }
            return texts.joined(separator: "\n")
        }

        guard let scriptPath = tool.scriptPath else {
            throw NSError(domain: "DynamicToolbox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tool \(name) missing execution path"])
        }

        // H3: Route through the hardened executeDynamicScript executor which:
        // 1. Validates scriptPath lives under the configured dynamic tool directories
        // 2. Resolves symlinks to prevent escapes
        // 3. Executes directly (no shell -c interpolation → no injection)
        // 4. Enforces a 60-second kill deadline
        let result = try await executeDynamicScript(
            scriptPath: scriptPath,
            jsonArguments: jsonArguments
        )
        if result.exitCode == 0 {
            return result.stdout
        } else {
            return "Execution failed with status \(result.exitCode)\nOutput: \(result.stdout)\nError: \(result.stderr)"
        }
    }


    private func parseYAML(_ text: String) -> [String: Any]? {
        var dict: [String: Any] = [:]
        let lines = text.components(separatedBy: .newlines)

        var parameterLines: [String] = []
        var inParameters = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let nsLine = line as NSString
            let leadingSpaces = nsLine.range(of: "^\\s*", options: .regularExpression).length

            if leadingSpaces == 0 {
                inParameters = false
                let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count >= 1 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                if parts.count == 2 {
                    var val = parts[1].trimmingCharacters(in: .whitespaces)
                    if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                        val = String(val.dropFirst().dropLast())
                    }
                    dict[key] = val
                } else {
                    if key == "parameters" {
                        inParameters = true
                    }
                }
            } else if inParameters {
                parameterLines.append(line)
            }
        }

        if !parameterLines.isEmpty {
            var parametersDict: [String: Any] = ["type": "object", "properties": [String: Any]()]
            var properties: [String: Any] = [:]
            var required: [String] = []

            var currentProp: String?
            var propDict: [String: Any] = [:]

            for pLine in parameterLines {
                let pTrimmed = pLine.trimmingCharacters(in: .whitespaces)
                let parts = pTrimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count >= 1 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)

                if key == "properties" { continue }
                if key == "required" {
                    if parts.count == 2 {
                        let reqVal = parts[1].trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "[", with: "")
                            .replacingOccurrences(of: "]", with: "")
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "'", with: "")
                        required = reqVal.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                    continue
                }

                let nsPLine = pLine as NSString
                let spaces = nsPLine.range(of: "^\\s*", options: .regularExpression).length

                if spaces == 4 { // Property name
                    if let prevProp = currentProp {
                        properties[prevProp] = propDict
                    }
                    currentProp = key
                    propDict = [:]
                } else if spaces > 4, parts.count == 2 { // Property attribute
                    var val = parts[1].trimmingCharacters(in: .whitespaces)
                    if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                        val = String(val.dropFirst().dropLast())
                    }
                    propDict[key] = val
                }
            }
            if let prevProp = currentProp {
                properties[prevProp] = propDict
            }
            parametersDict["properties"] = properties
            if !required.isEmpty {
                parametersDict["required"] = required
            }
            dict["parameters"] = parametersDict
        }

        return dict
    }

    private static func matchesType(value: Any, expectedType: String) -> Bool {
        switch expectedType.lowercased() {
        case "string":
            return value is String
        case "integer", "int":
            return value is Int
        case "number", "float", "double":
            return (value is Int) || (value is Double) || (value is Float)
        case "boolean", "bool":
            return value is Bool
        case "array":
            return value is [Any]
        case "object":
            return value is [String: Any]
        default:
            return true
        }
    }

    /// Returns dynamic tool names permitted for the given bot profile under least-privilege MCP scoping.
    /// If bot.allowedMCPServers is empty, all dynamic tools are permitted.
    func allowedDynamicToolNames(for bot: BotProfile) -> [String] {
        if bot.allowedMCPServers.isEmpty {
            return Array(dynamicTools.keys)
        }
        return dynamicTools.compactMap { (name, entry) in
            guard let serverId = entry.mcpServerId else {
                return name
            }
            let server = MCPManager.shared.servers.first(where: { $0.id == serverId })
            let serverName = server?.name ?? ""
            let serverIdStr = serverId.uuidString
            let isAllowed = bot.allowedMCPServers.contains { allowed in
                allowed.caseInsensitiveCompare(serverName) == .orderedSame ||
                allowed.caseInsensitiveCompare(serverIdStr) == .orderedSame
            }
            return isAllowed ? name : nil
        }
    }

    #if DEBUG
    func registerToolForTesting(name: String, entry: DynamicToolEntry) {
        dynamicTools[name] = entry
    }
    func removeToolForTesting(name: String) {
        dynamicTools.removeValue(forKey: name)
    }
    #endif

    // MARK: - Markdown Dynamic Toolbox Catalog

    func exportToolboxCatalogMarkdown() -> String {
        guard !dynamicTools.isEmpty else {
            return "No dynamic tools currently registered in toolbox."
        }

        var md = "### 🧰 Dynamic Toolbox Registered Tools (\(dynamicTools.count) available)\n\n"
        md += "| Tool Name | Origin | Execution Target | Description |\n"
        md += "|---|---|---|---|\n"

        for (name, entry) in dynamicTools.sorted(by: { $0.key < $1.key }) {
            let origin = entry.mcpServerId != nil ? "🔌 MCP Server" : "📜 Dynamic Script"
            let target = (entry.scriptPath ?? entry.mcpServerId?.uuidString ?? "Internal").replacingOccurrences(of: "|", with: "\\|")
            let safeDesc = entry.description.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            md += "| `\(name)` | \(origin) | `\(target)` | \(safeDesc) |\n"
        }
        return md
    }

}