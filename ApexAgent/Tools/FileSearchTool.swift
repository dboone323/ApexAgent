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

        @Guide(description: "Maximum number of matches to return (defaults to 50).", .range(1...200))
        var maxResults: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let orchestrator = await self.orchestrator.orchestrator
        let (env, spaceWs) = await ExecutionEnvironmentResolver.resolveCurrent(orchestrator: orchestrator)
        if case .seatbelt(let spaceID) = env {
            let mainWs = await MainActor.run { orchestrator.currentWorkspacePath }
            let wp = spaceWs ?? mainWs
            guard !wp.isEmpty else { return "ERROR: No workspace path for Seatbelt Space." }
            let backend = await SeatbeltBackendRegistry.shared.backend(for: spaceID, workspacePath: wp)
            do { try await backend.seed(workspacePath: wp) } catch { return "ERROR: \(error.localizedDescription)" }
            let dir: String
            if let d = arguments.directory { dir = d } else { dir = wp }
            let guestDir: String
            do { guestDir = try ExecutionEnvironmentResolver.mapPath(dir, workspacePath: wp) } catch { return "ERROR: \(error.localizedDescription)" }
            var cmd = "grep -rnI --exclude-dir=.git --exclude-dir=.build --exclude-dir=.swiftpm"
            if let pattern = arguments.filePattern {
                let sanitized = pattern.replacingOccurrences(of: "'", with: "'\\''")
                cmd += " --include='\(sanitized)'"
            }
            cmd += " -e '\(arguments.query.replacingOccurrences(of: "'", with: "'\\''"))' '\(guestDir.replacingOccurrences(of: "'", with: "'\\''"))'"
            let maxCount = arguments.maxResults ?? 50
            cmd += " -m \(maxCount)"
            do {
                let res = try await backend.runShell(command: cmd)
                let out = res.stdout.isEmpty ? res.stderr : res.stdout
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return "No matches found for '\(arguments.query)' in directory: \(guestDir)" }
                return trimmed
            } catch { return "ERROR: \(error.localizedDescription)" }
        }
        return try await executeWithLogging(arguments: arguments, orchestrator: self.orchestrator) {
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
            args.append("-e")
            args.append(arguments.query)
            args.append(expandedDir)
            
            process.arguments = args
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if process.isRunning {
                    process.terminate()
                }
            }
            defer { timeoutTask.cancel() }

            try process.run()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            let output = String(data: data, encoding: .utf8) ?? ""
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "No matches found for '\(arguments.query)' in directory: \(expandedDir)"
            }

            let lines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let maxCount = arguments.maxResults ?? 50
            let displayed = lines.prefix(maxCount)

            var md = "### File Search Results: `\(arguments.query)` (\(lines.count) matches)\n\n"
            md += "| File | Line | Snippet |\n"
            md += "|---|---|---|\n"

            for line in displayed {
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count >= 3 {
                    let file = String(parts[0]).replacingOccurrences(of: expandedDir + "/", with: "")
                    let lineNum = String(parts[1])
                    let snippet = String(parts[2]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|")
                    let truncatedSnippet = snippet.count > 100 ? String(snippet.prefix(97)) + "..." : snippet
                    md += "| `\(file)` | `\(lineNum)` | `\(truncatedSnippet)` |\n"
                } else {
                    md += "| - | - | `\(line.replacingOccurrences(of: "|", with: "\\|"))` |\n"
                }
            }

            if lines.count > maxCount {
                md += "\n*(Showing \(maxCount) of \(lines.count) matches. Increase maxResults to see more.)*\n"
            }

            return md
        }
    }
}
