import Foundation

@MainActor
class DynamicToolbox {
    static let shared = DynamicToolbox()

    var orchestrator: OrchestratorProvider?

    struct DynamicToolEntry {
        let name: String
        let description: String
        let scriptPath: String? // nil for MCP tools
        let schema: [String: Any]
        let mcpServerId: UUID? // nil for script-based tools
    }

    private(set) var dynamicTools: [String: DynamicToolEntry] = [:]

    private var dirDescriptor: Int32 = -1
    private var watcherSource: DispatchSourceFileSystemObject?
    private var loadMCPToolsTask: Task<Void, Never>?

    func loadTools() {
        dynamicTools.removeAll()

        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let toolsDir = homeDir.appendingPathComponent(".apex/tools")
        let skillsDir = homeDir.appendingPathComponent(".apex/skills")

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
        loadMCPToolsTask?.cancel()
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
            print("Loaded dynamic script tool: \(name) -> \(scriptPath)")
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
                    var properties: [String: Any] = [:]
                    if let props = tool.inputSchema.properties {
                        for (k, v) in props {
                            properties[k] = [
                                "type": v.type,
                                "description": v.description ?? ""
                            ]
                        }
                    }

                    let schema: [String: Any] = [
                        "name": tool.name,
                        "description": tool.description ?? "",
                        "parameters": [
                            "type": "object",
                            "properties": properties,
                            "required": tool.inputSchema.required ?? []
                        ]
                    ]

                    let entry = DynamicToolEntry(
                        name: tool.name,
                        description: tool.description ?? "",
                        scriptPath: nil,
                        schema: schema,
                        mcpServerId: config.id
                    )
                    dynamicTools[tool.name] = entry
                    print("Loaded MCP tool: \(tool.name) from server \(config.name)")
                }
            } catch {
                print("Failed to load tools from MCP server \(config.name): \(error)")
            }
        }
    }

    func startWatcher() {
        stopWatcher()

        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let toolsDir = homeDir.appendingPathComponent(".apex/tools")

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
            print("Directory watcher triggered for ~/.apex/tools - reloading dynamic tools.")
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
        // 1. Validates scriptPath lives under ~/.apex/tools or ~/.apex/skills
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

    #if DEBUG
    func registerToolForTesting(name: String, entry: DynamicToolEntry) {
        dynamicTools[name] = entry
    }
    func removeToolForTesting(name: String) {
        dynamicTools.removeValue(forKey: name)
    }
    #endif
}
