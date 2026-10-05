import Foundation
import FoundationModels

// MARK: - Shell Tool

struct ShellTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "run_shell_command"
    let description = "Runs a zsh shell command. Returns stdout, stderr, and exit code. Use for terminal tasks, testing, or building. After a command that changes state or performs an action, verify the requested end state with a separate read-only tool before reporting success; approval and exit status alone are not proof. For exploring files or project directories, prefer targeted tools like directory_tree, list_directory, or find_by_name rather than unbounded recursive commands like `ls -R`."

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
            
            let isMicroVMSandbox = UserDefaults.standard.bool(forKey: "apex.microvmSandboxEnabled")
            if isMicroVMSandbox {
                do {
                    let sandboxResult = try await VirtualizationMicroVMSandbox.shared.executeInIsolatedSandbox(
                        command: finalCommand,
                        timeoutSeconds: Double(arguments.timeoutSeconds ?? 30)
                    )
                    let output = sandboxResult.stdout + (sandboxResult.stderr.isEmpty ? "" : "\nSTDERR:\n" + sandboxResult.stderr)
                    return output.isEmpty ? "[Command executed successfully with no output in microVM sandbox]" : output
                } catch {
                    return "ERROR in microVM sandbox: \(error.localizedDescription)"
                }
            }
            
            // Use a stable conversation ID: prefer the orchestrator's current conversation,
            // then fall back to a deterministic "bot-shell" UUID so that bot-delegated
            // calls share a single reusable PTY session instead of failing on nil.
            let botShellUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
            let conversationId = await MainActor.run {
                orchestrator.currentConversation?.id ?? botShellUUID
            }
            
            let wsPath = await MainActor.run { orchestrator.currentWorkspacePath }
            if arguments.workingDirectory == nil || (arguments.workingDirectory?.isEmpty ?? true) {
                let escapedWs = "'" + wsPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
                finalCommand = "cd \(escapedWs) && \(finalCommand)"
            }

            // Log the command run in the TerminalView
            await MainActor.run {
                orchestrator.appendTerminalOutput(conversationId: conversationId, text: "\r\n$ \(arguments.command)\r\n")
            }

            let timeout = arguments.timeoutSeconds ?? 30
            let buildCommands = ["build", "compile", "make", "gcc", "clang", "cargo", "xcodebuild", "tsc"]
            let isBuildCommand = buildCommands.contains { arguments.command.lowercased().contains($0) }
            let cmdToExecute = finalCommand

            if let pty = await orchestrator.ptySession(for: conversationId) {
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
                        outputMsg += "\n\n[REMEDIATION GUIDANCE: The build failed. Please read the error log above, identify the failing lines in the code, use the appropriate tools to fix the code, and rerun the build command. Do not give up.]"
                    }
                    return outputMsg
                }
            } else {
                // Direct Process fallback when PTY allocation is unavailable
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", cmdToExecute]
                if FileManager.default.fileExists(atPath: wsPath) {
                    process.currentDirectoryURL = URL(fileURLWithPath: wsPath)
                }
                var env = ProcessInfo.processInfo.environment
                env["TERM"] = "xterm-color"
                env["NO_COLOR"] = "1"
                let currentPath = env["PATH"] ?? ""
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + currentPath
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    await MainActor.run {
                        orchestrator.appendTerminalOutput(conversationId: conversationId, text: output)
                    }
                    if process.terminationStatus != 0 {
                        var msg = output + "\nERROR: Command failed with exit code \(process.terminationStatus)"
                        if isBuildCommand {
                            msg += "\n\n[REMEDIATION GUIDANCE: The build failed. Please read the error log above, identify the failing lines in the code, use the appropriate tools to fix the code, and rerun the build command. Do not give up.]"
                        }
                        return msg
                    }
                    return output
                } catch {
                    return "ERROR: Failed to run process: \(error.localizedDescription)"
                }
            }
        }
    }
}
