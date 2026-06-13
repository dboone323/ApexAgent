import Foundation

@MainActor
class DynamicToolbox {
    static let shared = DynamicToolbox()
    
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
        
        // 3. Load MCP tools asynchronously
        Task {
            await loadMCPTools()
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
            let client = MCPManager.shared.getClient(for: config)
            do {
                try await client.start()
                let toolsList = try await client.listTools()
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
        
        if let mcpServerId = tool.mcpServerId {
            guard let config = MCPManager.shared.servers.first(where: { $0.id == mcpServerId }) else {
                throw NSError(domain: "DynamicToolbox", code: -1, userInfo: [NSLocalizedDescriptionKey: "MCP Server config not found"])
            }
            let client = MCPManager.shared.getClient(for: config)
            
            guard let data = jsonArguments.data(using: .utf8),
                  let argsDict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
                throw NSError(domain: "DynamicToolbox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON arguments for tool \(name)"])
            }
            
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
        
        return try await Task.detached(priority: .userInitiated) {
            let resolvedPath = (scriptPath as NSString).expandingTildeInPath
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "\(resolvedPath)"]
            
            var env = ProcessInfo.processInfo.environment
            env["APEX_ARGS"] = jsonArguments
            
            if AgentOrchestrator.isFolderAccessRestricted() {
                let fm = FileManager.default
                let homeDir = fm.homeDirectoryForCurrentUser
                let sandboxDir = homeDir.appendingPathComponent(".apex/sandbox")
                try? fm.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
                env["HOME"] = sandboxDir.path
            }
            
            process.environment = env
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            
            try process.run()
            
            if let data = jsonArguments.data(using: .utf8) {
                try? inputPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? inputPipe.fileHandleForWriting.close()
            
            let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            
            process.waitUntilExit()
            
            let outputStr = String(data: outputData, encoding: .utf8) ?? ""
            let errorStr = String(data: errorData, encoding: .utf8) ?? ""
            
            if process.terminationStatus == 0 {
                return outputStr
            } else {
                return "Execution failed with status \(process.terminationStatus)\nOutput: \(outputStr)\nError: \(errorStr)"
            }
        }.value
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
            
            var currentProp: String? = nil
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
}
