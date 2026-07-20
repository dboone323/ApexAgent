import Foundation
import FoundationModels

struct CreateSkillTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "create_skill"
    let description = "Creates a new reusable skill (tool) for the agent. Saves the script and its JSON schema parameter manifest in ~/.apex/skills/ so it can be dynamically loaded and run in subsequent turns."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Unique name of the new skill (use snake_case, e.g. 'count_source_lines')")
        var skillName: String

        @Guide(description: "Clear description of what the skill does and what it returns")
        var skillDescription: String

        @Guide(description: "The executable shell script code (typically zsh/bash, starting with '#!/bin/zsh'). It will receive arguments via the environment variable APEX_ARGS.")
        var scriptContent: String

        @Guide(description: "JSON string describing the parameters schema of the tool, matching standard JSON Schema format (e.g. '{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\", \"description\": \"Directory path\"}}, \"required\": [\"path\"]}')")
        var parameterSchemaJSON: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(
            arguments: arguments,
            orchestrator: orchestrator,
            riskDescription: "Creates and loads a new executable shell script skill '\(arguments.skillName)' which can run arbitrary commands on the system."
        ) {
            let fileManager = FileManager.default
            let homeDir = fileManager.homeDirectoryForCurrentUser
            let skillsDir = homeDir.appendingPathComponent(".apex/skills")

            // 1. Ensure skills directory exists
            try? fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true, attributes: nil)

            let sanitizedName = arguments.skillName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitizedName.isEmpty else {
                return "ERROR: skillName cannot be empty"
            }

            // Allowlist validation to prevent path traversal / shell escape
            let allowedPattern = try? NSRegularExpression(pattern: "^[a-z0-9_-]+$")
            let range = NSRange(sanitizedName.startIndex..., in: sanitizedName)
            if allowedPattern?.firstMatch(in: sanitizedName, range: range) == nil {
                return "ERROR: skillName must contain only lowercase letters, numbers, hyphens, and underscores"
            }

            let jsonPath = skillsDir.appendingPathComponent("\(sanitizedName).json")
            let scriptPath = skillsDir.appendingPathComponent("\(sanitizedName).sh")

            // 2. Parse parameter schema
            guard let schemaData = arguments.parameterSchemaJSON.data(using: .utf8),
                  let parsedSchema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
                return "ERROR: Failed to parse parameterSchemaJSON. Ensure it is valid JSON."
            }

            // 3. Write manifest JSON
            let manifest: [String: Any] = [
                "name": sanitizedName,
                "description": arguments.skillDescription,
                "script_path": "~/.apex/skills/\(sanitizedName).sh",
                "parameters": parsedSchema
            ]

            guard let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) else {
                return "ERROR: Failed to serialize skill manifest"
            }

            // Write both to temporary paths first
            let tempManifestPath = skillsDir.appendingPathComponent(".tmp_\(sanitizedName).json")
            let tempScriptPath = skillsDir.appendingPathComponent(".tmp_\(sanitizedName).sh")

            do {
                try manifestData.write(to: tempManifestPath)

                var finalScript = arguments.scriptContent
                if !finalScript.hasPrefix("#!") {
                    finalScript = "#!/bin/zsh\n" + finalScript
                }
                try finalScript.write(to: tempScriptPath, atomically: true, encoding: .utf8)

                // If both succeeded, move to final locations
                if fileManager.fileExists(atPath: jsonPath.path) {
                    try fileManager.removeItem(at: jsonPath)
                }
                if fileManager.fileExists(atPath: scriptPath.path) {
                    try fileManager.removeItem(at: scriptPath)
                }

                try fileManager.moveItem(at: tempManifestPath, to: jsonPath)
                try fileManager.moveItem(at: tempScriptPath, to: scriptPath)
            } catch {
                // Clean up any remaining temp files on error
                try? fileManager.removeItem(at: tempManifestPath)
                try? fileManager.removeItem(at: tempScriptPath)
                return "ERROR: Failed to write skill files: \(error.localizedDescription)"
            }

            // 5. Make script executable
            let chmodProcess = Process()
            chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmodProcess.arguments = ["+x", scriptPath.path]
            try chmodProcess.run()
            let chmodWatchdog = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if chmodProcess.isRunning { chmodProcess.terminate() }
            }
            chmodProcess.waitUntilExit()
            chmodWatchdog.cancel()

            // 6. Reload the DynamicToolbox on the MainActor
            await MainActor.run {
                DynamicToolbox.shared.loadTools()
            }

            return "SUCCESS: Skill '\(sanitizedName)' successfully created and loaded into the toolbox! You can now call it like a regular tool in subsequent turns."
        }
    }
}
