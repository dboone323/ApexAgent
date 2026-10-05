import Foundation
import FoundationModels

// MARK: - File Patch Tool (Surgical file editing)
//
// Replaces a single contiguous block of code/text in a file matching targetContent with
// replacementContent. Avoids overwriting or truncating large files.

struct FilePatchTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "patch_file"
    let description = "Surgically replaces a block of text in a file. Must provide exact targetContent to find and replacementContent to substitute. Optional startLine and endLine constrain the search range."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Absolute or tilde-expanded path to the file to modify")
        var path: String

        @Guide(description: "The exact substring to replace in the file (must match exactly including whitespace)")
        var targetContent: String

        @Guide(description: "The new content to replace targetContent with")
        var replacementContent: String

        @Guide(description: "Optional 1-indexed starting line number to constrain the search range")
        var startLine: Int?

        @Guide(description: "Optional 1-indexed ending line number to constrain the search range")
        var endLine: Int?

        @Guide(description: "If true, replaces all occurrences of targetContent; otherwise fails if multiple matches exist")
        var allowMultiple: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        let wsPath = await MainActor.run { self.orchestrator.orchestrator.currentWorkspacePath }
        let expandedPath = resolveToWorkspace(rawPath: arguments.path, workspacePath: wsPath)
        let isAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(expandedPath) }
        guard isAllowed else {
            return "ERROR: Access to path is disabled in settings: \(expandedPath)"
        }

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return "ERROR: File not found at path: \(expandedPath)"
        }

        guard FileManager.default.isWritableFile(atPath: expandedPath) else {
            return "ERROR: File is not writable at path: \(expandedPath)"
        }

        let url = URL(fileURLWithPath: expandedPath)
        guard let originalContent = try? String(contentsOf: url, encoding: .utf8) else {
            return "ERROR: Could not read file as UTF-8 text at path: \(expandedPath)"
        }

        // Compute search scope
        let lines = originalContent.components(separatedBy: "\n")
        let totalLines = lines.count

        let startLine = max(1, arguments.startLine ?? 1)
        let endLine = min(totalLines, arguments.endLine ?? totalLines)

        guard startLine <= endLine else {
            return "ERROR: Invalid line range [\(startLine), \(endLine)] for file with \(totalLines) lines."
        }

        let sliceLines = lines[(startLine - 1)..<endLine]
        let sliceText = sliceLines.joined(separator: "\n")

        guard sliceText.contains(arguments.targetContent) else {
            return "ERROR: targetContent not found within specified lines \(startLine)-\(endLine) in \(expandedPath)."
        }

        let occurrences = sliceText.components(separatedBy: arguments.targetContent).count - 1
        if occurrences > 1 && !(arguments.allowMultiple ?? false) {
            return "ERROR: Found \(occurrences) occurrences of targetContent in lines \(startLine)-\(endLine). Set allowMultiple=true to replace all, or narrow line range."
        }

        let replacedSlice = (arguments.allowMultiple ?? false)
            ? sliceText.replacingOccurrences(of: arguments.targetContent, with: arguments.replacementContent)
            : {
                if let range = sliceText.range(of: arguments.targetContent) {
                    var s = sliceText
                    s.replaceSubrange(range, with: arguments.replacementContent)
                    return s
                }
                return sliceText
            }()

        // Assemble final text
        let beforeSlice = startLine > 1 ? lines[0..<(startLine - 1)].joined(separator: "\n") + "\n" : ""
        let afterSlice = endLine < totalLines ? "\n" + lines[endLine..<totalLines].joined(separator: "\n") : ""
        let newFullContent = beforeSlice + replacedSlice + afterSlice

        return try await executeWithLogging(
            arguments: arguments,
            orchestrator: orchestrator,
            riskDescription: "Surgically patching file \(expandedPath)",
            oldContent: originalContent,
            newContent: newFullContent,
            filePath: expandedPath
        ) {
            FileRollback.snapshot(path: expandedPath)
            try newFullContent.write(to: url, atomically: true, encoding: .utf8)
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                return "ERROR: Verification failed — patched file missing at \(expandedPath)"
            }
            let verified = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return "✅ Successfully patched \(expandedPath). Replaced \(occurrences) occurrence(s). [Verified: \(verified.count) chars on disk]"
        }
    }
}
