import Foundation
import FoundationModels

struct ConfirmCompletionTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "confirm_completion"
    let description = """
    Informs the user that the task is complete and requests final approval. \
    Provide a detailed summary of what was completed, list of files modified, \
    and validation/testing results. If the user approves, the task is marked done. \
    If denied, the user will specify further changes needed.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "A comprehensive summary of the changes and actions completed.")
        var summary: String

        @Guide(description: "Comma-separated list of file paths that were modified or created, if any.")
        var filesModified: String?

        @Guide(description: "Detailed description of how the changes were verified/tested.")
        var verificationResults: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let orch = await orchestrator.orchestrator
            
            let displayArgs = """
            Summary: \(arguments.summary)
            Files Modified: \(arguments.filesModified ?? "None")
            Verification: \(arguments.verificationResults ?? "None")
            """
            
            let approved = await orch.requestConfirmation(
                toolName: self.name,
                arguments: displayArgs,
                riskDescription: "This will complete the task and finalize execution. Do you approve of the work done?"
            )
            
            if approved {
                return "SUCCESS: The user has approved task completion. You may now stop and output the final response."
            } else {
                return "DENIED: The user did NOT approve task completion. Please ask the user for feedback and continue working on the remaining or corrected items."
            }
        }
    }
}

// MARK: - Verify Execution Tool (WS7 End-to-End Execution Verification)

struct VerifyExecutionTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "verify_execution"
    let description = """
    Performs independent end-to-end execution verification of state mutations (files, terminal commands, or build products) before reporting success. \
    Approval and exit status alone are not proof. Use this tool to verify file existence, check file contents, or assert command outcomes.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Type of verification: 'file_exists', 'file_contains', 'file_not_contains', 'command_succeeds', or 'directory_not_empty'")
        var verificationType: String

        @Guide(description: "Absolute or relative file or directory path to check")
        var targetPath: String?

        @Guide(description: "Expected string or regex pattern to search for in the file or command output")
        var expectedPattern: String?

        @Guide(description: "Shell command to execute to verify the end state (returns verification success if exit code is 0)")
        var command: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let wsPath = await MainActor.run { self.orchestrator.orchestrator.currentWorkspacePath }
            let vType = arguments.verificationType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            switch vType {
            case "file_exists":
                guard let path = arguments.targetPath, !path.isEmpty else {
                    return "VERIFICATION_FAILED: 'targetPath' is required for file_exists check."
                }
                let resolved = resolvePath(path, wsPath: wsPath)
                if FileManager.default.fileExists(atPath: resolved) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
                    let size = attrs?[.size] as? Int64 ?? 0
                    return "VERIFIED: File exists on disk at '\(resolved)' (Size: \(size) bytes)."
                } else {
                    return "VERIFICATION_FAILED: File does NOT exist on disk at '\(resolved)'."
                }

            case "file_contains":
                guard let path = arguments.targetPath, !path.isEmpty else {
                    return "VERIFICATION_FAILED: 'targetPath' is required for file_contains check."
                }
                guard let pattern = arguments.expectedPattern, !pattern.isEmpty else {
                    return "VERIFICATION_FAILED: 'expectedPattern' is required for file_contains check."
                }
                let resolved = resolvePath(path, wsPath: wsPath)
                guard FileManager.default.fileExists(atPath: resolved) else {
                    return "VERIFICATION_FAILED: File does not exist at '\(resolved)'."
                }
                guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
                    return "VERIFICATION_FAILED: File could not be read as UTF-8 text at '\(resolved)'."
                }
                if content.contains(pattern) {
                    return "VERIFIED: File '\(resolved)' contains expected pattern '\(pattern)'."
                } else {
                    return "VERIFICATION_FAILED: File '\(resolved)' does NOT contain expected pattern '\(pattern)'."
                }

            case "file_not_contains":
                guard let path = arguments.targetPath, !path.isEmpty else {
                    return "VERIFICATION_FAILED: 'targetPath' is required for file_not_contains check."
                }
                guard let pattern = arguments.expectedPattern, !pattern.isEmpty else {
                    return "VERIFICATION_FAILED: 'expectedPattern' is required for file_not_contains check."
                }
                let resolved = resolvePath(path, wsPath: wsPath)
                guard FileManager.default.fileExists(atPath: resolved) else {
                    return "VERIFIED: File does not exist at '\(resolved)' (pattern absent)."
                }
                guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
                    return "VERIFICATION_FAILED: File could not be read as UTF-8 text at '\(resolved)'."
                }
                if !content.contains(pattern) {
                    return "VERIFIED: File '\(resolved)' correctly does NOT contain pattern '\(pattern)'."
                } else {
                    return "VERIFICATION_FAILED: File '\(resolved)' unexpectedly contains forbidden pattern '\(pattern)'."
                }

            case "directory_not_empty":
                guard let path = arguments.targetPath, !path.isEmpty else {
                    return "VERIFICATION_FAILED: 'targetPath' is required for directory_not_empty check."
                }
                let resolved = resolvePath(path, wsPath: wsPath)
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: resolved) else {
                    return "VERIFICATION_FAILED: Directory does not exist or cannot be read at '\(resolved)'."
                }
                if !contents.isEmpty {
                    return "VERIFIED: Directory at '\(resolved)' contains \(contents.count) items."
                } else {
                    return "VERIFICATION_FAILED: Directory at '\(resolved)' is empty."
                }

            case "command_succeeds":
                guard let cmd = arguments.command, !cmd.isEmpty else {
                    return "VERIFICATION_FAILED: 'command' is required for command_succeeds check."
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", cmd]
                if FileManager.default.fileExists(atPath: wsPath) {
                    process.currentDirectoryURL = URL(fileURLWithPath: wsPath)
                }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: data, encoding: .utf8) ?? ""
                    if process.terminationStatus == 0 {
                        if let pattern = arguments.expectedPattern, !pattern.isEmpty {
                            if out.contains(pattern) {
                                return "VERIFIED: Command succeeded (exit 0) and output matched pattern '\(pattern)'."
                            } else {
                                return "VERIFICATION_FAILED: Command succeeded (exit 0) but output did NOT match '\(pattern)'. Output:\n\(out)"
                            }
                        }
                        return "VERIFIED: Command succeeded with exit code 0."
                    } else {
                        return "VERIFICATION_FAILED: Command exited with code \(process.terminationStatus).\nOutput:\n\(out)"
                    }
                } catch {
                    return "VERIFICATION_FAILED: Failed to execute verification process: \(error.localizedDescription)"
                }

            default:
                return "VERIFICATION_FAILED: Unknown verificationType '\(arguments.verificationType)'. Supported types: file_exists, file_contains, file_not_contains, directory_not_empty, command_succeeds."
            }
        }
    }

    private func resolvePath(_ path: String, wsPath: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return (wsPath as NSString).appendingPathComponent(expanded)
    }
}
