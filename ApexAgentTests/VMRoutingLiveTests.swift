import Testing
import Foundation
@testable import ApexAgentCore

@Suite("VMRoutingLiveTests", .serialized)
struct VMRoutingLiveTests {
    @Test("vm routing smoke", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"), .timeLimit(.minutes(10)))
    func smoke() async throws {
        TestLog.beginRun(test: "VMRoutingLiveTests-smoke", runID: UUID().uuidString)
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
        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "provision", message: "start")
        let provisionStart = Date()
        try await manager.ensureProvisioned(spaceID: "smoke")
        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "ready", message: "launch-to-ready \(String(format: "%.3f", Date().timeIntervalSince(provisionStart)))s")
        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "provision", message: "end")
        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "seed", message: "start")
        let seedStart = Date()
        try await backend.seed(workspacePath: tmp.path)
        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "seed", message: "end \(String(format: "%.3f", Date().timeIntervalSince(seedStart)))s")

        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "shell", message: "start")
        let (out, _, code) = try await backend.runShell(command: "echo hi && pwd")
        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "shell", message: "end code=\(code) out=\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(code == 0)
        #expect(out.contains("hi"))

        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "file", message: "start")
        try await backend.writeFile(relativePath: "foo.txt", content: "bar")
        let read = try await backend.readFile(relativePath: "foo.txt")
        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "file", message: "end read=\(read.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(read.contains("bar"))

        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "git", message: "start")
        let (gout, _, gcode) = try await backend.git(arguments: ["log", "--oneline"])
        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "git", message: "end code=\(gcode)")
        #expect(gcode == 0)
        #expect(gout.contains("c1") || gout.contains("c2"))

        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "destroy", message: "start")
        try await manager.destroy(spaceID: "smoke")
        TestLog.append(test: "VMRoutingLiveTests-smoke", phase: "destroy", message: "end")
    }

    @Test("tool-level routing smoke", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"), .timeLimit(.minutes(10)))
    func toolLevelRouting() async throws {
        TestLog.beginRun(test: "VMRoutingLiveTests-toolLevelRouting", runID: UUID().uuidString)
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
        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "resolve", message: "start")
        let space = SpaceModel(name: "smoke", workspacePath: tmp.path, executionTargetRaw: "tartVM")
        let env = ExecutionEnvironmentResolver.resolve(space: space, containerEnabled: false)
        guard case .tartVM(let spaceID) = env else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected .tartVM"])
        }
        #expect(spaceID == space.id.uuidString)
        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "resolve", message: "end spaceID=\(spaceID)")

        // Exercise the shared routing layer the tools use: backend registry + seed + shell + file.
        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "registry", message: "start")
        let backend = await TartVMBackendRegistry.shared.backend(for: spaceID)
        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "registry", message: "end")
        defer { Task { try? await backend.manager.destroy(spaceID: spaceID) } }
        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "seed", message: "start")
        let seedStart = Date()
        try await backend.seed(workspacePath: tmp.path)
        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "seed", message: "end \(String(format: "%.3f", Date().timeIntervalSince(seedStart)))s")

        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "shell", message: "start")
        let (out, _, code) = try await backend.runShell(command: "echo tool-level && pwd")
        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "shell", message: "end code=\(code)")
        #expect(code == 0)
        #expect(out.contains("tool-level"))

        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "file", message: "start")
        try await backend.writeFile(relativePath: "tool.txt", content: "routed")
        let read = try await backend.readFile(relativePath: "tool.txt")
        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "file", message: "end read=\(read.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(read.contains("routed"))

        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "destroy", message: "start")
        try await backend.manager.destroy(spaceID: spaceID)
        TestLog.append(test: "VMRoutingLiveTests-toolLevelRouting", phase: "destroy", message: "end")
    }
}

@Suite("SpaceLandingLiveTests", .serialized)
struct SpaceLandingLiveTests {
    private func runGit(_ args: [String], cwd: URL) throws {
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

    @Test("landing smoke — legitimate guest change lands", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"))
    func landingLegitimate() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try runGit(["init", "-b", "main"], cwd: tmp)
        try "base\n".write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tmp)
        try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "base"], cwd: tmp)

        let manager = VMWorkspaceManager()
        let backend = TartVMBackend(spaceID: "smoke", manager: manager)
        defer { Task { try? await manager.destroy(spaceID: "smoke") } }
        try await manager.ensureProvisioned(spaceID: "smoke")
        try await backend.seed(workspacePath: tmp.path)

        try await backend.writeFile(relativePath: "feature.txt", content: "new\n")
        let (_, _, ac) = try await backend.git(arguments: ["add", "."])
        #expect(ac == 0)
        let (_, _, cc) = try await backend.git(arguments: ["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "guest change"])
        #expect(cc == 0)

        let rc = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: rc) }
        let svc = SpaceLandingService(client: TartCLIClient(), manager: manager, reviewClonePath: rc, isApexAgent: false)
        let report = await svc.land(input: .init(spaceID: "smoke", spaceName: "smoke", workspacePath: tmp.path))
        #expect(report.succeeded, "report: \(report.summary)")
        #expect(report.quarantineBranch == "space/smoke-review")

        let branchProc = Process()
        branchProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        branchProc.arguments = ["-C", rc, "rev-parse", "--verify", "space/smoke-review"]
        try branchProc.run(); branchProc.waitUntilExit()
        #expect(branchProc.terminationStatus == 0)

        let showProc = Process()
        showProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        showProc.arguments = ["-C", rc, "show", "space/smoke-review:feature.txt"]
        let sp = Pipe(); showProc.standardOutput = sp; showProc.standardError = Pipe()
        try showProc.run(); showProc.waitUntilExit()
        let out = String(data: sp.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(out.contains("new"))

        try await manager.destroy(spaceID: "smoke")
    }

    @Test("landing smoke — tampered guest change refused", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"))
    func landingTampered() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("ApexAgentTests"), withIntermediateDirectories: true)
        try "test\n".write(to: tmp.appendingPathComponent("ApexAgentTests/FooTests.swift"), atomically: true, encoding: .utf8)
        try runGit(["init", "-b", "main"], cwd: tmp)
        try runGit(["add", "."], cwd: tmp)
        try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "base"], cwd: tmp)

        let manager = VMWorkspaceManager()
        let backend = TartVMBackend(spaceID: "smoke", manager: manager)
        defer { Task { try? await manager.destroy(spaceID: "smoke") } }
        try await manager.ensureProvisioned(spaceID: "smoke")
        try await backend.seed(workspacePath: tmp.path)

        try await backend.deleteFile(relativePath: "ApexAgentTests/FooTests.swift")
        let (_, _, ac) = try await backend.git(arguments: ["add", "-A"])
        #expect(ac == 0)
        let (_, _, cc) = try await backend.git(arguments: ["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "tamper"])
        #expect(cc == 0)

        let rc = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: rc) }
        let svc = SpaceLandingService(client: TartCLIClient(), manager: manager, reviewClonePath: rc, isApexAgent: false)
        let report = await svc.land(input: .init(spaceID: "smoke", spaceName: "smoke", workspacePath: tmp.path))
        #expect(!report.succeeded)
        #expect(report.failedStage == "Test-integrity check")
        #expect(report.quarantineBranch == nil)
        #expect(!FileManager.default.fileExists(atPath: rc))

        try await manager.destroy(spaceID: "smoke")
    }
}
