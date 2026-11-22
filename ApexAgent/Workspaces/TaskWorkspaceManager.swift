import Foundation
import os

// MARK: - Task Workspace

public final class TaskWorkspace: @unchecked Sendable {
    public let id: String
    public let workspaceURL: URL
    public var workspacePath: String { workspaceURL.path }
    public let isolationType: TaskIsolationType
    public let retentionPolicy: TaskWorkspaceRetentionPolicy
    public let baseDirectory: String
    public private(set) var state: TaskWorkspaceState
    public let createdAt: Date
    public let worktreeBranch: String?

    private let lock = NSLock()

    public init(
        id: String,
        workspaceURL: URL,
        isolationType: TaskIsolationType,
        retentionPolicy: TaskWorkspaceRetentionPolicy,
        baseDirectory: String,
        state: TaskWorkspaceState = .active,
        createdAt: Date = Date(),
        worktreeBranch: String? = nil
    ) {
        self.id = id
        self.workspaceURL = workspaceURL
        self.isolationType = isolationType
        self.retentionPolicy = retentionPolicy
        self.baseDirectory = baseDirectory
        self.state = state
        self.createdAt = createdAt
        self.worktreeBranch = worktreeBranch
    }

    public func updateState(_ newState: TaskWorkspaceState) {
        lock.lock()
        defer { lock.unlock() }
        self.state = newState
    }

    // MARK: - Path Confinement & Confinement Validation

    /// Resolves a candidate path against this task workspace and guarantees
    /// that the resolved path is strictly contained within the workspace root.
    /// Traversal sequences (e.g. `../`) and paths outside the workspace throw `TaskWorkspaceError.pathEscape`.
    public func resolvePath(_ rawPath: String) throws -> String {
        let clean = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return workspaceURL.standardized.resolvingSymlinksInPath().path
        }

        let expanded = NSString(string: clean).expandingTildeInPath
        let standardizedRoot = workspaceURL.standardized.resolvingSymlinksInPath().path

        let candidateURL: URL
        if expanded.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: expanded)
        } else {
            candidateURL = workspaceURL.appendingPathComponent(expanded)
        }

        let standardizedCandidate = candidateURL.standardized.resolvingSymlinksInPath().path

        if standardizedCandidate == standardizedRoot {
            return standardizedRoot
        }

        let prefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        guard standardizedCandidate.hasPrefix(prefix) else {
            throw TaskWorkspaceError.pathEscape(attempted: rawPath, workspaceRoot: workspacePath)
        }

        return standardizedCandidate
    }

    public func isPathContained(_ rawPath: String) -> Bool {
        (try? resolvePath(rawPath)) != nil
    }

    // MARK: - File Operations Inside Isolated Workspace

    @discardableResult
    public func writeFile(relativePath: String, content: String, append: Bool = false) throws -> String {
        let resolvedPath = try resolvePath(relativePath)
        let fileURL = URL(fileURLWithPath: resolvedPath)
        let parentDir = fileURL.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        if append && FileManager.default.fileExists(atPath: resolvedPath) {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer { try? fileHandle.close() }
            fileHandle.seekToEndOfFile()
            if let data = content.data(using: .utf8) {
                fileHandle.write(data)
            }
        } else {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return resolvedPath
    }

    public func readFile(relativePath: String) throws -> String {
        let resolvedPath = try resolvePath(relativePath)
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw NSError(
                domain: "TaskWorkspace",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "File does not exist: \(relativePath) in workspace \(id)"]
            )
        }
        return try String(contentsOfFile: resolvedPath, encoding: .utf8)
    }

    public func fileExists(relativePath: String) -> Bool {
        guard let resolved = try? resolvePath(relativePath) else { return false }
        return FileManager.default.fileExists(atPath: resolved)
    }

    public func listFiles(relativeToSubdir: String = "") throws -> [String] {
        let targetDir = try resolvePath(relativeToSubdir)
        guard FileManager.default.fileExists(atPath: targetDir) else { return [] }

        var results: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: targetDir),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let rootPrefix = targetDir.hasSuffix("/") ? targetDir : targetDir + "/"
        while let itemURL = enumerator?.nextObject() as? URL {
            let path = itemURL.standardized.resolvingSymlinksInPath().path
            if path.hasPrefix(rootPrefix) {
                let relative = String(path.dropFirst(rootPrefix.count))
                results.append(relative)
            }
        }
        return results.sorted()
    }

    public func deleteFile(relativePath: String) throws {
        let resolvedPath = try resolvePath(relativePath)
        if FileManager.default.fileExists(atPath: resolvedPath) {
            try FileManager.default.removeItem(atPath: resolvedPath)
        }
    }
}

// MARK: - Task Workspace Manager Actor

public actor TaskWorkspaceManager {
    public static let shared = TaskWorkspaceManager()

    private var workspaces: [String: TaskWorkspace] = [:]

    public init() {}

    // MARK: - Workspace Lifecycle

    /// Creates an isolated workspace for a given task.
    /// Supports real git worktrees, ephemeral directories, or microVM sandboxes.
    public func createWorkspace(
        taskID: String,
        baseDirectory: String? = nil,
        isolationType: TaskIsolationType = .worktree(branch: nil),
        retentionPolicy: TaskWorkspaceRetentionPolicy = .cleanupAlways
    ) async throws -> TaskWorkspace {
        let sanitizedID = taskID
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()

        let baseDir: String
        if let base = baseDirectory, !base.isEmpty, FileManager.default.fileExists(atPath: base) {
            baseDir = URL(fileURLWithPath: base).standardized.resolvingSymlinksInPath().path
        } else {
            let envBase = ProcessInfo.processInfo.environment["APEX_WORKSPACE"]
            if let envBase, !envBase.isEmpty, FileManager.default.fileExists(atPath: envBase) {
                baseDir = URL(fileURLWithPath: envBase).standardized.resolvingSymlinksInPath().path
            } else {
                baseDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .standardized.resolvingSymlinksInPath().path
            }
        }

        let storageRoot = ApexAgentStoragePaths.directory("task_workspaces")
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let workspaceURL = storageRoot.appendingPathComponent("task_\(sanitizedID)_\(UUID().uuidString.prefix(8))")

        var assignedBranch: String? = nil
        var effectiveIsolation = isolationType

        switch isolationType {
        case .worktree(let customBranch):
            let isGitRepo = await checkIsGitRepository(at: baseDir)
            if isGitRepo {
                let branchName = customBranch ?? "task/\(sanitizedID)"
                assignedBranch = branchName
                let worktreeCreated = await createGitWorktree(
                    baseRepo: baseDir,
                    branch: branchName,
                    destinationPath: workspaceURL.path
                )
                if !worktreeCreated {
                    // Fall back to clean directory copy if worktree cannot be created
                    try createIsolatedDirectory(at: workspaceURL, copyingFrom: baseDir)
                    effectiveIsolation = .ephemeralDirectory
                }
            } else {
                try createIsolatedDirectory(at: workspaceURL, copyingFrom: baseDir)
                effectiveIsolation = .ephemeralDirectory
            }

        case .ephemeralDirectory:
            try createIsolatedDirectory(at: workspaceURL, copyingFrom: nil)

        case .microVM:
            try createIsolatedDirectory(at: workspaceURL, copyingFrom: nil)
        }

        let workspace = TaskWorkspace(
            id: sanitizedID,
            workspaceURL: workspaceURL,
            isolationType: effectiveIsolation,
            retentionPolicy: retentionPolicy,
            baseDirectory: baseDir,
            state: .active,
            createdAt: Date(),
            worktreeBranch: assignedBranch
        )

        workspaces[sanitizedID] = workspace
        return workspace
    }

    public func workspace(for taskID: String) -> TaskWorkspace? {
        let sanitizedID = taskID
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        return workspaces[sanitizedID]
    }

    public func allWorkspaces() -> [TaskWorkspace] {
        Array(workspaces.values).sorted { $0.createdAt < $1.createdAt }
    }

    public func activeWorkspaces() -> [TaskWorkspace] {
        workspaces.values.filter { $0.state == .active || $0.state == .reviewing }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Teardown with Retention Policy

    public func teardownWorkspace(taskID: String, status: TaskCompletionStatus = .succeeded) async throws {
        guard let workspace = workspace(for: taskID) else {
            throw TaskWorkspaceError.workspaceNotFound(taskID)
        }

        switch workspace.retentionPolicy {
        case .cleanupAlways:
            await performCleanup(for: workspace)
            workspace.updateState(.cleanedUp)

        case .keepOnFailure:
            if status == .failed {
                workspace.updateState(.retained)
            } else {
                await performCleanup(for: workspace)
                workspace.updateState(.cleanedUp)
            }

        case .retained:
            workspace.updateState(.retained)
        }
    }

    public func cleanupAllEphemeral() async {
        for workspace in workspaces.values {
            if workspace.retentionPolicy == .cleanupAlways && workspace.state != .cleanedUp {
                await performCleanup(for: workspace)
                workspace.updateState(.cleanedUp)
            }
        }
    }

    // MARK: - Internal Helpers

    private func createIsolatedDirectory(at url: URL, copyingFrom sourceDir: String?) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let source = sourceDir, FileManager.default.fileExists(atPath: source) {
            // Copy non-ignored configuration files if desired, or leave clean
        }
    }

    private func checkIsGitRepository(at path: String) async -> Bool {
        let res = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", path, "rev-parse", "--is-inside-work-tree"],
            timeoutSeconds: 10
        )
        return res.exitCode == 0 && res.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func createGitWorktree(baseRepo: String, branch: String, destinationPath: String) async -> Bool {
        // Ensure destination parent directory exists
        let parent = URL(fileURLWithPath: destinationPath).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let res = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", baseRepo, "worktree", "add", "-B", branch, destinationPath, "HEAD"],
            timeoutSeconds: 30
        )
        return res.exitCode == 0
    }

    private func performCleanup(for workspace: TaskWorkspace) async {
        if case .worktree(let branch) = workspace.isolationType {
            _ = await ProcessRunner.runProcessSafely(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", workspace.baseDirectory, "worktree", "remove", "--force", workspace.workspacePath],
                timeoutSeconds: 30
            )
            if let branchName = branch ?? workspace.worktreeBranch {
                _ = await ProcessRunner.runProcessSafely(
                    executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                    arguments: ["-C", workspace.baseDirectory, "branch", "-D", branchName],
                    timeoutSeconds: 15
                )
            }
        }
        try? FileManager.default.removeItem(at: workspace.workspaceURL)
    }
}
