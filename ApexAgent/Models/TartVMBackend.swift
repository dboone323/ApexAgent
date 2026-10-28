import Foundation

public actor TartVMBackend {
    public let spaceID: String
    public let manager: VMWorkspaceManager
    public let client: any TartClientProtocol
    public let guestCheckout: String = "~/ApexAgent"
    private var seeded: Bool = false

    public init(spaceID: String, manager: VMWorkspaceManager = VMWorkspaceManager(), client: (any TartClientProtocol)? = nil) {
        self.spaceID = spaceID
        self.manager = manager
        self.client = client ?? TartCLIClient()
    }

    public func vmName() -> String { VMWorkspaceManager.vmName(for: spaceID) }

    private func ensureReady() async throws {
        try await manager.ensureProvisioned(spaceID: spaceID)
        try await manager.startIfNeeded(spaceID: spaceID)
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runRaw(_ command: String) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await ensureReady()
        try await seedIfNeeded()
        let name = VMWorkspaceManager.vmName(for: spaceID)
        return try await client.exec(name: name, arguments: ["sh", "-c", command])
    }

    public func runShell(command: String, timeout: Int = 30) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let full = "cd \(guestCheckout) && \(command)"
        return try await runRaw(full)
    }

    public func seed(workspacePath: String?) async throws {
        try await seedIfNeeded(workspacePath: workspacePath)
    }

    public func seedIfNeeded(workspacePath: String? = nil) async throws {
        if seeded { return }
        try await ensureReady()
        let name = VMWorkspaceManager.vmName(for: spaceID)
        let check = try? await client.exec(name: name, arguments: ["sh", "-c", "test -d ~/ApexAgent/.git && echo SEEDED"])
        if let c = check, c.exitCode == 0 && c.stdout.contains("SEEDED") {
            seeded = true
            return
        }
        guard let wp = workspacePath, !wp.isEmpty else {
            throw NSError(domain: "TartVMBackend", code: 1, userInfo: [NSLocalizedDescriptionKey: "workspacePath required for seeding"])
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(spaceID)-\(UUID().uuidString).bundle")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.removeItem(atPath: tmp.path + ".lock")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(atPath: tmp.path + ".lock")
        }
        let branchProc = Process()
        branchProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        branchProc.arguments = ["-C", wp, "rev-parse", "--abbrev-ref", "HEAD"]
        let bp = Pipe(); branchProc.standardOutput = bp; branchProc.standardError = Pipe()
        try branchProc.run(); branchProc.waitUntilExit()
        let branch = String(data: bp.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "main"

        let bundleProc = Process()
        bundleProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        bundleProc.arguments = ["-C", wp, "bundle", "create", tmp.path, "HEAD"]
        try bundleProc.run(); bundleProc.waitUntilExit()
        guard bundleProc.terminationStatus == 0 else {
            throw NSError(domain: "TartVMBackend", code: 2, userInfo: [NSLocalizedDescriptionKey: "workspacePath is not a git repo or bundle failed"])
        }
        let bundleData = try Data(contentsOf: tmp)

        _ = try await client.execStdin(name: name, arguments: ["sh", "-c", "cat > /tmp/seed.bundle"], input: bundleData)

        let verify = try await client.exec(name: name, arguments: ["sh", "-c", "rm -rf /tmp/seed-verify && git init -q /tmp/seed-verify && git -C /tmp/seed-verify bundle verify /tmp/seed.bundle"])
        guard verify.exitCode == 0 else {
            throw NSError(domain: "TartVMBackend", code: 3, userInfo: [NSLocalizedDescriptionKey: "bundle verify failed: \(verify.stderr)"])
        }
        let clone = try await client.exec(name: name, arguments: ["sh", "-c", "rm -rf ~/ApexAgent && git clone /tmp/seed.bundle ~/ApexAgent && cd ~/ApexAgent && git checkout -B \(branch)"])
        guard clone.exitCode == 0 else {
            throw NSError(domain: "TartVMBackend", code: 4, userInfo: [NSLocalizedDescriptionKey: "clone failed: \(clone.stderr)"])
        }
        seeded = true
        try? FileManager.default.removeItem(at: tmp)
    }

    public func readFile(relativePath: String) async throws -> String {
        let (out, err, code) = try await runShell(command: "cat \(shellEscape(relativePath))")
        if code != 0 { throw NSError(domain: "TartVMBackend", code: Int(code), userInfo: [NSLocalizedDescriptionKey: err]) }
        return out
    }

    public func writeFile(relativePath: String, content: String) async throws {
        let data = Data(content.utf8)
        try await ensureReady()
        try await seedIfNeeded()
        let dir = (relativePath as NSString).deletingLastPathComponent
        if !dir.isEmpty && dir != "." {
            _ = try await runShell(command: "mkdir -p \(shellEscape(dir))")
        }
        let name = VMWorkspaceManager.vmName(for: spaceID)
        let guestPath = "~/ApexAgent/\(relativePath)"
        _ = try await client.execStdin(name: name, arguments: ["sh", "-c", "cat > \(guestPath)"], input: data)
    }

    public func deleteFile(relativePath: String) async throws {
        _ = try await runShell(command: "rm -f \(shellEscape(relativePath))")
    }

    public func moveFile(from: String, to: String) async throws {
        _ = try await runShell(command: "mv \(shellEscape(from)) \(shellEscape(to))")
    }

    public func listDirectory(relativePath: String) async throws -> String {
        let (out, _, _) = try await runShell(command: "ls -la \(shellEscape(relativePath))")
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
        return try await runShell(command: "git -C \(guestCheckout) \(args)")
    }
}
