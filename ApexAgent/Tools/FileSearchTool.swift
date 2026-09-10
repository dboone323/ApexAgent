import Foundation
import FoundationModels

// MARK: - File Search Tool

struct FileSearchTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "file_search"
    let description = "Searches for a text query or pattern across files recursively within a directory. Uses system grep."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The query string to search for inside files.")
        var query: String

        @Guide(description: "The directory path to search. Defaults to current workspace if not specified.")
        var directory: String?

        @Guide(description: "Optional file pattern/extension filter (e.g. '*.swift').")
        var filePattern: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let wsPath = await MainActor.run { self.orchestrator.orchestrator.currentWorkspacePath }
            let baseDir: String
            if let dir = arguments.directory {
                baseDir = dir
            } else {
                baseDir = wsPath
            }
            let expandedDir = resolveToWorkspace(rawPath: baseDir, workspacePath: wsPath)
            
            let isAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(expandedDir) }
            guard isAllowed else {
                return "ERROR: Access to path is disabled in settings: \(expandedDir)"
            }
            
            let fm = FileManager.default
            guard fm.fileExists(atPath: expandedDir) else {
                return "ERROR: Directory not found: \(expandedDir)"
            }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            
            var args = ["-rnI", "--exclude-dir=.git", "--exclude-dir=.build", "--exclude-dir=.swiftpm"]
            if let pattern = arguments.filePattern {
                args.append("--include=\(pattern)")
            }
            args.append(arguments.query)
            args.append(expandedDir)
            
            process.arguments = args
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            try process.run()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            let output = String(data: data, encoding: .utf8) ?? ""
            
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "No matches found for '\(arguments.query)' in directory: \(expandedDir)"
            }
            return output
        }
    }
}
