import Foundation
import FoundationModels
import AppKit

// MARK: - AppleScript Tool

struct AppleScriptTool: Tool {
    let orchestrator: OrchestratorProvider
    var timeoutNanoseconds: UInt64

    init(orchestrator: OrchestratorProvider, timeoutNanoseconds: UInt64 = 30_000_000_000) {
        self.orchestrator = orchestrator
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    let name = "run_applescript"
    let description = """
    Executes an AppleScript string and returns the result. \
    Use this to control any scriptable macOS application (Finder, Safari, Mail, Calendar, Reminders, Terminal, etc.). \
    Also useful for UI automation tasks that don't have a direct API.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The AppleScript code to execute")
        var script: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: "Executing script controlling system applications") {
            let orchestrator = await self.orchestrator.orchestrator
            let isAllowed = await MainActor.run { orchestrator.isCommandOrScriptAllowed(arguments.script) }
            if !isAllowed {
                return "ERROR: Access to restricted directories (Desktop, Documents, Downloads, or Music) is disabled by system security settings."
            }
            
            let timeoutNanos = self.timeoutNanoseconds
            do {
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            DispatchQueue.global(qos: .userInitiated).async {
                                var error: NSDictionary?
                                let appleScript = NSAppleScript(source: arguments.script)
                                let result = appleScript?.executeAndReturnError(&error)

                                if let error = error {
                                    let errorMsg = error[NSAppleScript.errorMessage] as? String
                                        ?? error[NSAppleScript.errorNumber].map { "Error \($0)" }
                                        ?? "Unknown AppleScript error"
                                    continuation.resume(returning: "ERROR: \(errorMsg)")
                                } else if let result = result {
                                    continuation.resume(returning: result.stringValue ?? "Script executed successfully (no return value)")
                                } else {
                                    continuation.resume(returning: "Script executed successfully")
                                }
                            }
                        }
                    }

                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutNanos)
                        return "ERROR: AppleScript execution timed out after 30 seconds."
                    }

                    let first = try await group.next() ?? "Script executed successfully"
                    group.cancelAll()
                    return first
                }
            } catch {
                return "ERROR: AppleScript execution timed out after 30 seconds."
            }
        }
    }
}

// MARK: - Get Frontmost App Tool

struct GetFrontmostAppTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    
    let name = "get_frontmost_app"
    let description = "Returns the bundle ID, name, and process ID of the currently active (frontmost) macOS application."

    @Generable
    struct Arguments: Decodable {}

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            return await MainActor.run {
                guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
                    return "No frontmost application found"
                }
                let name = frontmostApp.localizedName ?? "Unknown"
                let bundleID = frontmostApp.bundleIdentifier ?? "Unknown"
                let pid = frontmostApp.processIdentifier
                return "Frontmost App:\nName: \(name)\nBundle ID: \(bundleID)\nPID: \(pid)"
            }
        }
    }
}
