import Foundation

public actor SeatbeltBackend {
    public let spaceID: String
    public private(set) var workspacePath: String
    public let allowNetwork: Bool
    private var seeded: Bool = false
    private let fm = FileManager.default

    public init(spaceID: String, workspacePath: String = "", allowNetwork: Bool = true) {
        self.spaceID = spaceID
        self.workspacePath = workspacePath
        self.allowNetwork = allowNetwork
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func configure(workspacePath: String) async throws {
        self.workspacePath = workspacePath
        try ensureWorkspaceStructure()
    }

    public var profilePath: String {
        let apexDir = (workspacePath as NSString).appendingPathComponent(".apex")
        return (apexDir as NSString).appendingPathComponent("seatbelt.sb")
    }

    public var tempDirectory: String {
        (workspacePath as NSString).appendingPathComponent(".apex/tmp")
    }

    public var derivedDataDirectory: String {
        (workspacePath as NSString).appendingPathComponent(".apex/DerivedData")
    }

    @discardableResult
    public func ensureWorkspaceStructure() throws -> String {
        guard !workspacePath.isEmpty else {
            throw NSError(domain: "SeatbeltBackend", code: 1, userInfo: [NSLocalizedDescriptionKey: "Workspace path cannot be empty"])
        }
        let apexDir = (workspacePath as NSString).appendingPathComponent(".apex")
        let tmpDir = tempDirectory
        let ddDir = derivedDataDirectory
        let moduleCacheDir = (ddDir as NSString).appendingPathComponent("ModuleCache")

        try fm.createDirectory(atPath: apexDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: ddDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: moduleCacheDir, withIntermediateDirectories: true)

        let profile = SeatbeltProfile(workspacePath: workspacePath, allowNetwork: allowNetwork)
        let content = profile.generate()
        let path = profilePath
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    public func seed(workspacePath sourcePath: String?) async throws {
        guard let src = sourcePath, !src.isEmpty else {
            if !self.workspacePath.isEmpty {
                _ = try ensureWorkspaceStructure()
                seeded = true
                return
            }
            throw NSError(domain: "SeatbeltBackend", code: 1, userInfo: [NSLocalizedDescriptionKey: "workspacePath required for seeding"])
        }

        if self.workspacePath.isEmpty {
            self.workspacePath = src
        } else if self.workspacePath != src {
            // If the target workspace has no .git, clone --shared from src
            let targetGit = (self.workspacePath as NSString).appendingPathComponent(".git")
            let srcGit = (src as NSString).appendingPathComponent(".git")
            if !fm.fileExists(atPath: targetGit) && fm.fileExists(atPath: srcGit) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                proc.arguments = ["clone", "--shared", src, self.workspacePath]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "git clone --shared failed"
                    throw NSError(domain: "SeatbeltBackend", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
                }
            }
        }

        _ = try ensureWorkspaceStructure()
        seeded = true
    }

    public func runShell(command: String, timeout: Int = 30) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let pPath = try ensureWorkspaceStructure()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        proc.arguments = ["-f", pPath, "/bin/sh", "-c", "cd \(shellEscape(workspacePath)) && \(command)"]

        var env = ProcessInfo.processInfo.environment
        let tmpDir = tempDirectory
        let ddDir = derivedDataDirectory
        env["TMPDIR"] = tmpDir
        env["IDEDerivedDataPathOverride"] = ddDir
        env["XCODE_DERIVED_DATA_PATH"] = ddDir
        env["CLANG_MODULE_CACHE_PATH"] = (ddDir as NSString).appendingPathComponent("ModuleCache")
        env["SWIFTPM_MODULE_CACHE_PATH"] = (ddDir as NSString).appendingPathComponent("ModuleCache")
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: workspacePath)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        let deadline = Date().addingTimeInterval(Double(timeout))
        while proc.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning {
            proc.terminate()
            return ("", "ERROR: Command timed out after \(timeout) seconds", -1)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (stdout, stderr, proc.terminationStatus)
    }

    public func readFile(relativePath: String) async throws -> String {
        let (out, err, code) = try await runShell(command: "cat \(shellEscape(relativePath))")
        if code != 0 {
            throw NSError(domain: "SeatbeltBackend", code: Int(code), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "Failed to read file \(relativePath)" : err])
        }
        return out
    }

    public func writeFile(relativePath: String, content: String) async throws {
        let pPath = try ensureWorkspaceStructure()
        let dir = (relativePath as NSString).deletingLastPathComponent
        if !dir.isEmpty && dir != "." {
            _ = try await runShell(command: "mkdir -p \(shellEscape(dir))")
        }

        let targetPath = (workspacePath as NSString).appendingPathComponent(relativePath)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        proc.arguments = ["-f", pPath, "/bin/sh", "-c", "cat > \(shellEscape(targetPath))"]

        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = tempDirectory
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: workspacePath)

        let inPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardError = errPipe

        try proc.run()

        if let data = content.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "write failed"
            throw NSError(domain: "SeatbeltBackend", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
        }
    }

    public func deleteFile(relativePath: String) async throws {
        _ = try await runShell(command: "rm -f \(shellEscape(relativePath))")
    }

    public func moveFile(from: String, to: String) async throws {
        _ = try await runShell(command: "mv \(shellEscape(from)) \(shellEscape(to))")
    }

    public func listDirectory(relativePath: String) async throws -> String {
        let (out, _, _) = try await runShell(command: "ls -la \(shellEscape(relativePath.isEmpty ? "." : relativePath))")
        return out
    }

    public func createDirectory(relativePath: String) async throws {
        _ = try await runShell(command: "mkdir -p \(shellEscape(relativePath))")
    }

    public func searchFiles(pattern: String, path: String) async throws -> String {
        let (out, _, _) = try await runShell(command: "grep -rn \(shellEscape(pattern)) \(shellEscape(path)) 2>/dev/null || true")
        return out
    }

    public func git(arguments: [String]) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let args = arguments.map { shellEscape($0) }.joined(separator: " ")
        return try await runShell(command: "git -C \(shellEscape(workspacePath)) \(args)")
    }
}
