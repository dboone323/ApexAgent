import Foundation
import FoundationModels

// MARK: - Shell Tool

struct ShellTool: Tool {
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
        return try await executeWithLogging(arguments: arguments, riskDescription: "Executing command in your terminal") {
            guard let orchestrator = await (MainActor.run { AgentOrchestrator.shared }) else {
                throw NSError(domain: "ShellTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "AgentOrchestrator not available"])
            }
            
            let conversationId = await MainActor.run {
                orchestrator.currentConversation?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            }
            
            let pty = await MainActor.run {
                orchestrator.ptySession(for: conversationId)
            }
            
            // Log the command run in the TerminalView
            await MainActor.run {
                orchestrator.appendTerminalOutput(conversationId: conversationId, text: "\r\n$ \(arguments.command)\r\n")
            }
            
            let timeout = arguments.timeoutSeconds ?? 30
            
            let buildCommands = ["build", "compile", "make", "gcc", "clang", "cargo", "xcodebuild", "tsc"]
            let isBuildCommand = buildCommands.contains { arguments.command.lowercased().contains($0) }
            
            do {
                let result = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await pty.runCommand(arguments.command)
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
