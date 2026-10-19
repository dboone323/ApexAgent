import Foundation
import FoundationModels

struct AppleShortcutsTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "run_shortcut"
    let description = "Wraps the macOS shortcuts CLI to list or run Apple Shortcuts."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Action to perform: 'list' or 'run'")
        var action: String
        
        @Guide(description: "Name of the shortcut to run")
        var shortcutName: String?
        
        @Guide(description: "Optional text input to pass to the shortcut")
        var input: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let riskDesc: String? = arguments.action == "run" ? "Running Apple Shortcut '\(arguments.shortcutName ?? "")'" : nil
        
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: riskDesc) {
            
            if arguments.action == "run" {
                guard let name = arguments.shortcutName, !name.isEmpty else {
                    return "ERROR: shortcutName is required for 'run' action."
                }
            }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            
            var args = [arguments.action]
            if arguments.action == "run", let name = arguments.shortcutName {
                args.append(name)
                if let input = arguments.input {
                    args.append(contentsOf: ["--input-type", "text", "--input", input])
                }
            }
            process.arguments = args
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return String(decoding: data, as: UTF8.self)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    process.terminate()
                    throw NSError(domain: "AppleShortcutsTool", code: -2, userInfo: [NSLocalizedDescriptionKey: "Command timed out after 60 seconds."])
                }
                
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        }
    }
}
