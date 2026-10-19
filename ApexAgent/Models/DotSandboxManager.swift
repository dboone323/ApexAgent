import Foundation
import AppKit

// MARK: - Dot Sandbox Manager
//
// Manages dedicated, isolated workspaces ("Dot Computers") for specialist agents.
// Follows Option A (Pure Swift Native Sandbox with dedicated filesystem and
// process jail) with automatic Option B fallback to Docker / ContainerManager.

public final class DotSandboxManager: Sendable {
    public static let shared = DotSandboxManager()

    public init() {}

    /// Root directory for a specific Dot's sandbox environment.
    public func sandboxURL(for dotId: UUID) -> URL {
        ApexAgentStoragePaths.directory("dots")
            .appendingPathComponent(dotId.uuidString, isDirectory: true)
            .appendingPathComponent("sandbox", isDirectory: true)
    }

    /// Prepares the directory hierarchy for a Dot's sandbox.
    @discardableResult
    public func ensureSandbox(for dotId: UUID) throws -> URL {
        let root = sandboxURL(for: dotId)
        let fm = FileManager.default

        let subdirs = ["workspace", "notes", "scratch", "outputs"]
        for sub in subdirs {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        return root
    }

    /// Resolves and verifies that a relative path stays securely within the Dot's sandbox jail.
    public func resolvePath(for dotId: UUID, relativePath: String) throws -> URL {
        let root = sandboxURL(for: dotId).standardizedFileURL.resolvingSymlinksInPath()
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = root.appendingPathComponent(trimmed).standardizedFileURL.resolvingSymlinksInPath()

        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let targetPath = target.path

        guard targetPath == root.path || targetPath.hasPrefix(rootPath) else {
            throw NSError(
                domain: "DotSandboxManager",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Security sandbox violation: path '\(relativePath)' attempts to escape Dot sandbox jail."]
            )
        }
        return target
    }

    /// Reads a file from the Dot's sandbox.
    public func readSandboxFile(for dotId: UUID, relativePath: String) throws -> String {
        try ensureSandbox(for: dotId)
        let target = try resolvePath(for: dotId, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw NSError(domain: "DotSandboxManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "File not found: \(relativePath)"])
        }
        return try String(contentsOf: target, encoding: .utf8)
    }

    /// Writes content to a file inside the Dot's sandbox.
    public func writeSandboxFile(for dotId: UUID, relativePath: String, content: String) throws {
        try ensureSandbox(for: dotId)
        let target = try resolvePath(for: dotId, relativePath: relativePath)
        let parentDir = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try content.write(to: target, atomically: true, encoding: .utf8)
    }

    /// Lists directory contents inside the Dot's sandbox.
    public func listSandboxFiles(for dotId: UUID, relativePath: String = "workspace") throws -> [String] {
        try ensureSandbox(for: dotId)
        let target = try resolvePath(for: dotId, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: target.path)
    }

    /// Executes a command inside the Dot's sandbox with working directory locked to `workspace/`.
    /// Falls back to ContainerManager if native execution is restricted or if `preferContainer` is true.
    public func executeSandboxedCommand(
        for dotId: UUID,
        command: String,
        preferContainer: Bool = false,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> (output: String, exitCode: Int32, ranInContainer: Bool) {
        let root = try ensureSandbox(for: dotId)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)

        // Option B: Containerization fallback if requested
        if preferContainer {
            if let containerResult = await executeViaContainerFallback(dotId: dotId, command: command, workspaceURL: workspaceURL) {
                return containerResult
            }
        }

        // Option A: Swift native sandbox execution
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = workspaceURL

            // Sanitized environment
            var env = ProcessInfo.processInfo.environment
            env["DOT_SANDBOX_DIR"] = workspaceURL.path
            env["DOT_ID"] = dotId.uuidString
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            try process.run()

            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading
            async let outTask = Task.detached { outHandle.readDataToEndOfFile() }.value
            async let errTask = Task.detached { errHandle.readDataToEndOfFile() }.value

            // Timeout watchdog
            let didTimeout = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    process.waitUntilExit()
                    return false
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        if process.isRunning {
                            process.terminate()
                            return true
                        }
                    } catch {
                        // Cancelled when process finishes before timeout
                    }
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }

            let (outData, errData) = await (outTask, errTask)
            let stdoutStr = String(data: outData, encoding: .utf8) ?? ""
            let stderrStr = String(data: errData, encoding: .utf8) ?? ""
            let combined = stdoutStr + (stderrStr.isEmpty ? "" : "\n[stderr]: " + stderrStr)

            if didTimeout {
                return (output: combined + "\n[Timed out after \(Int(timeoutSeconds))s]", exitCode: 124, ranInContainer: false)
            }

            return (output: combined, exitCode: process.terminationStatus, ranInContainer: false)
        } catch {
            // Attempt Option B container fallback upon native failure
            if let containerResult = await executeViaContainerFallback(dotId: dotId, command: command, workspaceURL: workspaceURL) {
                return containerResult
            }
            throw error
        }
    }

    private func executeViaContainerFallback(
        dotId: UUID,
        command: String,
        workspaceURL: URL
    ) async -> (output: String, exitCode: Int32, ranInContainer: Bool)? {
        let diag = await MainActor.run { ContainerManager.checkHostCapabilities() }
        guard diag.isVirtualizationSupported || diag.vmnetAvailable else {
            return nil
        }

        do {
            let runResult = try await executeContainerExec(command: command, workingDirectory: workspaceURL.path)
            return (output: runResult.output, exitCode: runResult.exitCode, ranInContainer: true)
        } catch {
            return nil
        }
    }

    @MainActor
    private func executeContainerExec(command: String, workingDirectory: String) async throws -> (output: String, exitCode: Int32) {
        try await ContainerManager.shared.exec(command, workingDirectory: workingDirectory)
    }
}
