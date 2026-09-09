import Foundation
import FoundationModels

// MARK: - File Read Tool

struct FileReadTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    let name = "read_file"
    let description = "Reads a file and returns its contents. Supports tilde paths (~/)."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Absolute or tilde-expanded path to the file to read")
        var path: String

        @Guide(description: "Maximum number of lines to read. Reads entire file if not specified.", .range(1...10000))
        var maxLines: Int?
    }

    private func resolveExistingFilePath(_ inputPath: String) -> String? {
        let expanded = NSString(string: inputPath).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return expanded
        }
        
        let cwd = FileManager.default.currentDirectoryPath
        let relCwd = (cwd as NSString).appendingPathComponent(inputPath)
        if FileManager.default.fileExists(atPath: relCwd) {
            return relCwd
        }
        
        // Check if the path missed an inner directory with the same name (common in Xcode projects like ApexAgent/ApexAgent/...)
        let expandedURL = URL(fileURLWithPath: expanded)
        let filename = expandedURL.lastPathComponent
        let parentURL = expandedURL.deletingLastPathComponent()
        let parentDirName = parentURL.lastPathComponent
        let candidateInSubdir = parentURL.appendingPathComponent(parentDirName).appendingPathComponent(filename).path
        if FileManager.default.fileExists(atPath: candidateInSubdir) {
            return candidateInSubdir
        }

        // Check workspace candidates
        let workspaceCandidates = [
            UserDefaults.standard.string(forKey: "apex.workspacePath"),
            ProcessInfo.processInfo.environment["APEX_WORKSPACE"],
            cwd
        ].compactMap { $0 }.filter { !$0.isEmpty }

        for ws in workspaceCandidates {
            let direct = (ws as NSString).appendingPathComponent(inputPath)
            if FileManager.default.fileExists(atPath: direct) {
                return direct
            }
            let wsName = (ws as NSString).lastPathComponent
            let sub = (ws as NSString).appendingPathComponent(wsName)
            let inSub = (sub as NSString).appendingPathComponent(inputPath)
            if FileManager.default.fileExists(atPath: inSub) {
                return inSub
            }
            let directFilename = (sub as NSString).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: directFilename) {
                return directFilename
            }
        }
        return nil
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let effectivePath = resolveExistingFilePath(arguments.path) ?? NSString(string: arguments.path).expandingTildeInPath
            let isAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(effectivePath) }
            guard isAllowed else {
                return "ERROR: Access to path is disabled in settings: \(effectivePath)"
            }
            let url = URL(fileURLWithPath: effectivePath)

            guard FileManager.default.fileExists(atPath: effectivePath) else {
                return "ERROR: File not found at path: \(effectivePath)"
            }

            guard FileManager.default.isReadableFile(atPath: effectivePath) else {
                return "ERROR: File is not readable: \(effectivePath)"
            }

            // Check file size — refuse to load > 10MB text files
            let attrs = try FileManager.default.attributesOfItem(atPath: effectivePath)
            let size = attrs[.size] as? Int64 ?? 0
            if size > 10_000_000 {
                return "ERROR: File too large (\(size) bytes). Maximum is 10MB. Use shell tool with `head` or `tail` for large files."
            }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                // Try reading as binary and describe
                let data = try Data(contentsOf: url)
                return "BINARY FILE: \(effectivePath)\nSize: \(data.count) bytes\nFirst 128 bytes (hex): \(data.prefix(128).map { String(format: "%02x", $0) }.joined(separator: " "))"
            }

            if let maxLines = arguments.maxLines {
                let lines = content.components(separatedBy: "\n")
                let truncated = lines.prefix(maxLines).joined(separator: "\n")
                let remaining = max(0, lines.count - maxLines)
                if remaining > 0 {
                    return truncated + "\n\n[... \(remaining) more lines not shown ...]"
                }
                return truncated
            }

            return content
        }
    }
}

// MARK: - File Write Tool

struct FileWriteTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    let name = "write_file"
    let description = "Writes text content to a file. Creates the file and parent directories if needed."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Absolute or tilde-expanded path to write to")
        var path: String

        @Guide(description: "The text content to write to the file")
        var content: String

        @Guide(description: "If true, appends to existing file instead of overwriting")
        var append: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        let expandedPath = NSString(string: arguments.path).expandingTildeInPath
        let isAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(expandedPath) }
        guard isAllowed else {
            return "ERROR: Access to path is disabled in settings: \(expandedPath)"
        }
        let url = URL(fileURLWithPath: expandedPath)
        
        let oldContent = (try? String(contentsOfFile: expandedPath, encoding: .utf8)) ?? ""
        let shouldAppend = arguments.append ?? false
        let newContent = shouldAppend ? (oldContent + arguments.content) : arguments.content
        
        return try await executeWithLogging(
            arguments: arguments,
            orchestrator: orchestrator,
            riskDescription: "Writing to file \(expandedPath)",
            oldContent: oldContent,
            newContent: newContent,
            filePath: expandedPath
        ) {
            // Create parent directories
            let parentDir = url.deletingLastPathComponent().path
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

            if shouldAppend && FileManager.default.fileExists(atPath: expandedPath) {
                let fileHandle = try FileHandle(forWritingTo: url)
                fileHandle.seekToEndOfFile()
                if let data = arguments.content.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
                return "✅ Appended \(arguments.content.count) characters to \(expandedPath)"
            } else {
                // WS5.7: snapshot the previous contents before overwriting so
                // the write can be rolled back.
                FileRollback.snapshot(path: expandedPath)
                try arguments.content.write(to: url, atomically: true, encoding: .utf8)
                return "✅ Written \(arguments.content.count) characters to \(expandedPath)"
            }
        }
    }
}

// MARK: - List Directory Tool

struct ListDirectoryTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    let name = "list_directory"
    let description = "Lists files and subdirectories at a path with sizes. Supports tilde paths."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Path to the directory to list")
        var path: String

        @Guide(description: "If true, shows hidden files (starting with .)")
        var showHidden: Bool?

        @Guide(description: "Maximum depth for recursive listing. 1 = only immediate children.", .range(1...5))
        var depth: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let expandedPath = NSString(string: arguments.path).expandingTildeInPath
            let isAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(expandedPath) }
            guard isAllowed else {
                return "ERROR: Access to path is disabled in settings: \(expandedPath)"
            }
            let showHidden = arguments.showHidden ?? false
            let depth = arguments.depth ?? 1

            guard FileManager.default.fileExists(atPath: expandedPath) else {
                return "ERROR: Directory not found: \(expandedPath)"
            }

            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDir)
            guard isDir.boolValue else {
                return "ERROR: Path is not a directory: \(expandedPath)"
            }

            var output = "Directory: \(expandedPath)\n"
            output += listContents(at: expandedPath, indent: 0, maxDepth: depth, showHidden: showHidden)
            return output
        }
    }

    private func listContents(at path: String, indent: Int, maxDepth: Int, showHidden: Bool) -> String {
        guard indent < maxDepth else { return "" }

        let prefix = String(repeating: "  ", count: indent)
        var result = ""

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
            return "\(prefix)  [Unable to read directory]\n"
        }

        let sorted = contents.sorted()
        for item in sorted {
            if !showHidden && item.hasPrefix(".") { continue }

            let fullPath = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)

            if isDir.boolValue {
                result += "\(prefix)📁 \(item)/\n"
                result += listContents(at: fullPath, indent: indent + 1, maxDepth: maxDepth, showHidden: showHidden)
            } else {
                let size = (try? fm.attributesOfItem(atPath: fullPath))?[.size] as? Int64 ?? 0
                result += "\(prefix)📄 \(item) (\(formatSize(size)))\n"
            }
        }

        return result
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Create Directory Tool

struct CreateDirectoryTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    let name = "create_directory"
    let description = "Creates a directory (including parent directories) at the given path."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Path of the directory to create")
        var path: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let expandedPath = NSString(string: arguments.path).expandingTildeInPath
            let isAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(expandedPath) }
            guard isAllowed else {
                return "ERROR: Access to path is disabled in settings: \(expandedPath)"
            }
            do {
                try FileManager.default.createDirectory(atPath: expandedPath, withIntermediateDirectories: true)
                return "✅ Created directory: \(expandedPath)"
            } catch {
                return "ERROR: Could not create directory: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Delete File Tool

struct DeleteFileTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    let name = "delete_file"
    let description = "Moves a file or directory to Trash (or permanently deletes if permanent=true). DESTRUCTIVE."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Path of the file or directory to delete")
        var path: String

        @Guide(description: "If true, permanently deletes instead of moving to Trash. DANGEROUS.")
        var permanent: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: "Deleting a file or directory on your system") {
            let expandedPath = NSString(string: arguments.path).expandingTildeInPath
            let isAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(expandedPath) }
            guard isAllowed else {
                return "ERROR: Access to path is disabled in settings: \(expandedPath)"
            }
            let url = URL(fileURLWithPath: expandedPath)

            guard FileManager.default.fileExists(atPath: expandedPath) else {
                return "ERROR: File not found: \(expandedPath)"
            }

            let permanent = arguments.permanent ?? false

            do {
                if permanent {
                    // WS5.7: snapshot before permanent delete so it can be rolled back.
                    FileRollback.snapshot(path: expandedPath)
                    try FileManager.default.removeItem(at: url)
                    return "✅ Permanently deleted: \(expandedPath)"
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    return "✅ Moved to Trash: \(expandedPath)"
                }
            } catch {
                return "ERROR: Could not delete: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Move File Tool

struct MoveFileTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    let name = "move_file"
    let description = "Moves or renames a file or directory from source to destination."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Source path of the file/directory to move")
        var sourcePath: String

        @Guide(description: "Destination path (including new filename if renaming)")
        var destinationPath: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: "Moving or renaming a file or directory on your system") {
            let srcExpanded = NSString(string: arguments.sourcePath).expandingTildeInPath
            let dstExpanded = NSString(string: arguments.destinationPath).expandingTildeInPath
            
            let srcAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(srcExpanded) }
            let dstAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(dstExpanded) }
            guard srcAllowed && dstAllowed else {
                return "ERROR: Access to source or destination path is disabled in settings."
            }

            guard FileManager.default.fileExists(atPath: srcExpanded) else {
                return "ERROR: Source not found: \(srcExpanded)"
            }

            // Create parent dir of destination if needed
            let dstParent = URL(fileURLWithPath: dstExpanded).deletingLastPathComponent().path
            try? FileManager.default.createDirectory(atPath: dstParent, withIntermediateDirectories: true)

            do {
                // WS5.7: snapshot the source before moving so the move can be undone.
                FileRollback.snapshot(path: srcExpanded)
                try FileManager.default.moveItem(
                    at: URL(fileURLWithPath: srcExpanded),
                    to: URL(fileURLWithPath: dstExpanded)
                )
                return "✅ Moved: \(srcExpanded) → \(dstExpanded)"
            } catch {
                return "ERROR: Could not move: \(error.localizedDescription)"
            }
        }
    }
}
