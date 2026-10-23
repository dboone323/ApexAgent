import Testing
import Foundation
@testable import ApexAgentCore

@Suite("VMRoutingLiveTests", .serialized)
struct VMRoutingLiveTests {
    @Test("vm routing smoke", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"))
    func smoke() async throws {
        // scratch git repo
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        func runGit(_ args: [String], cwd: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = cwd
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""])
            }
        }
        try runGit(["init", "-b", "main"], cwd: tmp)
        try "hello\n".write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tmp)
        try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "c1"], cwd: tmp)
        try "world\n".write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tmp)
        try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "c2"], cwd: tmp)

        let manager = VMWorkspaceManager()
        let backend = TartVMBackend(spaceID: "smoke", manager: manager)
        defer { Task { try? await manager.destroy(spaceID: "smoke") } }
        try await manager.ensureProvisioned(spaceID: "smoke")
        try await backend.seed(workspacePath: tmp.path)

        let (out, _, code) = try await backend.runShell(command: "echo hi && pwd")
        #expect(code == 0)
        #expect(out.contains("hi"))

        try await backend.writeFile(relativePath: "foo.txt", content: "bar")
        let read = try await backend.readFile(relativePath: "foo.txt")
        #expect(read.contains("bar"))

        let (gout, _, gcode) = try await backend.git(arguments: ["log", "--oneline"])
        #expect(gcode == 0)
        #expect(gout.contains("c1") || gout.contains("c2"))

        try await manager.destroy(spaceID: "smoke")
    }

    @Test("tool-level routing smoke", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"))
    func toolLevelRouting() async throws {
        // scratch git repo
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        func runGit(_ args: [String], cwd: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = cwd
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""])
            }
        }
        try runGit(["init", "-b", "main"], cwd: tmp)
        try "hello\n".write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tmp)
        try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "c1"], cwd: tmp)

        // Resolve a .tartVM environment through the SAME resolver the tools call.
        let space = SpaceModel(name: "smoke", workspacePath: tmp.path, executionTargetRaw: "tartVM")
        let env = ExecutionEnvironmentResolver.resolve(space: space, containerEnabled: false)
        guard case .tartVM(let spaceID) = env else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected .tartVM"])
        }
        #expect(spaceID == space.id.uuidString)

        // Exercise the shared routing layer the tools use: backend registry + seed + shell + file.
        let backend = await TartVMBackendRegistry.shared.backend(for: spaceID)
        defer { Task { try? await backend.manager.destroy(spaceID: spaceID) } }
        try await backend.seed(workspacePath: tmp.path)

        let (out, _, code) = try await backend.runShell(command: "echo tool-level && pwd")
        #expect(code == 0)
        #expect(out.contains("tool-level"))

        try await backend.writeFile(relativePath: "tool.txt", content: "routed")
        let read = try await backend.readFile(relativePath: "tool.txt")
        #expect(read.contains("routed"))

        try await backend.manager.destroy(spaceID: spaceID)
    }
}