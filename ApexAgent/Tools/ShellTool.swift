import Foundation
import FoundationModels

// MARK: - Shell Tool

struct ShellTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "run_shell_command"
    let description = "Runs a zsh shell command. Returns stdout, stderr, and exit code. Use for any terminal task."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The shell command to execute. Will be run via /bin/zsh -c")
        var command: String

        @Guide(description: "Working directory for the command. Defaults to user home if not specified.")
        var workingDirectory: String?

        @Guide(description: "Timeout in seconds before the command is killed. Default is 30.", .range(1...300))
        var timeoutSeconds: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let isContainer = UserDefaults.standard.bool(forKey: "apex.appleContainersEnabled")
        let riskDesc: String? = isContainer ? nil : "Executing command in your terminal"

        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: riskDesc) {
            let orchestrator = await self.orchestrator.orchestrator
            
            // Security Check 1: Verify command path safety properties (bypassed in isolated container)
            let isCmdAllowed = await MainActor.run { orchestrator.isCommandOrScriptAllowed(arguments.command, isContainerSandboxed: isContainer) }
            if !isCmdAllowed {
                return "ERROR: Access to restricted directories (Desktop, Documents, Downloads, or Music) is disabled by system security settings."
            }
            
            // Working Directory resolution and check
            var finalCommand = arguments.command
            if let workingDir = arguments.workingDirectory, !workingDir.isEmpty {
                let expandedDir = NSString(string: workingDir).expandingTildeInPath
                let standardizedDir = URL(fileURLWithPath: expandedDir).standardized.path
                
                if !isContainer {
                    let isDirAllowed = await MainActor.run { orchestrator.isPathAllowed(standardizedDir) }
                    if !isDirAllowed {
                        return "ERROR: Working directory '\(workingDir)' is restricted by system security settings."
                    }
                }
                
                // Securely transition to target directory using single-quote escaping to prevent command injection
                let escapedDir = "'" + expandedDir.replacingOccurrences(of: "'", with: "'\\''") + "'"
                finalCommand = "cd \(escapedDir) && \(finalCommand)"
            }
            
            let conversationId = await MainActor.run {
                orchestrator.currentConversation?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            }
            
            guard let pty = await orchestrator.ptySession(for: conversationId) else {
                return "ERROR: Failed to allocate or initialize a terminal session (PTY allocation failed)."
            }
            
            // Log the command run in the TerminalView
            await MainActor.run {
                orchestrator.appendTerminalOutput(conversationId: conversationId, text: "\r\n$ \(arguments.command)\r\n")
            }
            
            let timeout = arguments.timeoutSeconds ?? 30
            
            let buildCommands = ["build", "compile", "make", "gcc", "clang", "cargo", "xcodebuild", "tsc"]
            let isBuildCommand = buildCommands.contains { arguments.command.lowercased().contains($0) }
            
            let cmdToExecute = finalCommand
            do {
                let result = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await pty.runCommand(cmdToExecute)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        throw NSError(domain: "ShellTool", code: -2, userInfo: [NSLocalizedDescriptionKey: "Command timed out after \(timeout) seconds."])
                    }
                    
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                return result
            } catch {
                let nsErr = error as NSError
                var outputMsg = ""
                if let output = nsErr.userInfo["output"] as? String {
                    outputMsg = output + "\nERROR: Command failed with exit code \(nsErr.code)"
                } else {
                    outputMsg = "ERROR: \(error.localizedDescription)"
                }
                
                if isBuildCommand {
                    outputMsg += "\n\n[SYSTEM INSTRUCTION: The build failed. Please read the error log above, identify the failing lines in the code, use the appropriate tools to fix the code, and rerun the build command. Do not give up.]"
                }
                return outputMsg
            }
        }
    }
}
