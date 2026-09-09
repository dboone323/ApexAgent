import Foundation
import FoundationModels

// MARK: - Git Operations Tool
//
// Provides safe, structured git operations without invoking raw unvetted shell commands.

struct GitOperationsTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "git_operation"
    let description = "Performs structured Git repository operations (status, diff, log, branch, checkout, commit, add, stash) within an allowed workspace repository."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The git action to execute: 'status', 'diff', 'log', 'branch', 'checkout', 'commit', 'add', 'stash'")
        var action: String

        @Guide(description: "Absolute or tilde-expanded path to the repository directory. Defaults to current workspace if omitted.")
        var repoPath: String?

        @Guide(description: "Commit message (required for 'commit')")
        var message: String?

        @Guide(description: "File paths to add, diff, or checkout")
        var paths: [String]?

        @Guide(description: "Branch name (for 'checkout' or 'branch')")
        var branchName: String?

        @Guide(description: "Whether to create a new branch during checkout (-b)")
        var createBranch: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        let repoDir: String = {
            if let p = arguments.repoPath, !p.isEmpty {
                return NSString(string: p).expandingTildeInPath
            }
            if let configured = UserDefaults.standard.string(forKey: "apex.workspacePath"), !configured.isEmpty {
                return NSString(string: configured).expandingTildeInPath
            }
            return FileManager.default.currentDirectoryPath
        }()

        let isAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(repoDir) }
        guard isAllowed else {
            return "ERROR: Access to repository directory is disabled in settings: \(repoDir)"
        }

        let isMutating = ["commit", "checkout", "add", "stash"].contains(arguments.action.lowercased())
        let riskDesc = isMutating
            ? "Executing Git mutating operation '\(arguments.action)' in \(repoDir)"
            : "Executing Git read operation '\(arguments.action)' in \(repoDir)"

        return try await executeWithLogging(
            arguments: arguments,
            orchestrator: orchestrator,
            riskDescription: riskDesc
        ) {
            switch arguments.action.lowercased() {
            case "status":
                return try runGit(repoDir: repoDir, args: ["status", "--short", "--branch"])

            case "diff":
                var args = ["diff"]
                if let paths = arguments.paths, !paths.isEmpty {
                    args.append("--")
                    args.append(contentsOf: paths)
                }
                let diffOut = try runGit(repoDir: repoDir, args: args)
                return diffOut.isEmpty ? "Clean: no unstaged changes." : diffOut

            case "log":
                return try runGit(repoDir: repoDir, args: ["log", "-n", "10", "--oneline", "--graph"])

            case "branch":
                return try runGit(repoDir: repoDir, args: ["branch", "-a"])

            case "add":
                guard let paths = arguments.paths, !paths.isEmpty else {
                    return "ERROR: 'paths' argument is required for 'add'."
                }
                var args = ["add"]
                args.append(contentsOf: paths)
                _ = try runGit(repoDir: repoDir, args: args)
                return "✅ Successfully staged \(paths.count) path(s)."

            case "commit":
                guard let msg = arguments.message, !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return "ERROR: 'message' argument is required for 'commit'."
                }
                let commitOut = try runGit(repoDir: repoDir, args: ["commit", "-m", msg])
                return "✅ Commit successful:\n\(commitOut)"

            case "checkout":
                guard let branch = arguments.branchName, !branch.isEmpty else {
                    return "ERROR: 'branchName' argument is required for 'checkout'."
                }
                var args = ["checkout"]
                if arguments.createBranch ?? false {
                    args.append("-b")
                }
                args.append(branch)
                let checkoutOut = try runGit(repoDir: repoDir, args: args)
                return "✅ Checked out \(branch):\n\(checkoutOut)"

            case "stash":
                let stashOut = try runGit(repoDir: repoDir, args: ["stash"])
                return "✅ Stash result:\n\(stashOut)"

            default:
                return "ERROR: Unsupported git action '\(arguments.action)'. Supported: status, diff, log, branch, add, commit, checkout, stash."
            }
        }
    }

    private func runGit(repoDir: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = URL(fileURLWithPath: repoDir)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && stdout.isEmpty {
            throw NSError(domain: "GitOperationsTool", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Git command failed with status \(process.terminationStatus): \(stderr)"
            ])
        }

        return stdout.isEmpty ? stderr : stdout
    }
}
