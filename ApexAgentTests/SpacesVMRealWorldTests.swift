import Testing
import Foundation
@testable import ApexAgentCore

@Suite("SpacesVMRealWorldTests", .serialized)
struct SpacesVMRealWorldTests {

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

    private func tartListNames() throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/tart")
        p.arguments = ["list", "--format", "json"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr.compactMap { $0["Name"] as? String }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map { String($0) }
    }

    @Test("RW1 provision lifecycle + guest parity", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"), .timeLimit(.minutes(10)))
    func rw1() async throws {
        let manager = VMWorkspaceManager(readyTimeoutSeconds: 600)
        defer { Task { try? await manager.destroy(spaceID: "rwtest") } }
        let t0 = Date()
        try await manager.ensureProvisioned(spaceID: "rwtest")
        try await manager.startIfNeeded(spaceID: "rwtest")
        let provisionReady = Date().timeIntervalSince(t0)
        print("TIMING RW1 provision->ready: \(provisionReady)s")

        let names = try tartListNames()
        #expect(names.contains("apex-space-rwtest"))

        let tart = TartCLIClient()
        let (xo, _, xcode) = try await tart.exec(name: "apex-space-rwtest", arguments: ["sh", "-c", "xcodebuild -version"])
        #expect(xcode == 0)
        #expect(xo.contains("Xcode 27.2"))
        #expect(xo.contains("27B48"))
        let (uno, _, uc) = try await tart.exec(name: "apex-space-rwtest", arguments: ["sh", "-c", "uname -m"])
        #expect(uc == 0)
        #expect(uno.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64")

        try await manager.destroy(spaceID: "rwtest")
        let after = try tartListNames()
        #expect(!after.contains("apex-space-rwtest"))
    }

    @Test("RW2 tool-path round trip + real guest compile", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"), .timeLimit(.minutes(10)))
    func rw2() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try runGit(["init", "-b", "main"], cwd: tmp)
        try "hello\n".write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tmp)
        try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "c1"], cwd: tmp)
        try "world\n".write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tmp)
        try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "c2"], cwd: tmp)

        let spaceID = "rw2"
        let backend = await TartVMBackendRegistry.shared.backend(for: spaceID)
        defer { Task { try? await backend.manager.destroy(spaceID: spaceID) } }
        try await backend.manager.ensureProvisioned(spaceID: spaceID)
        try await backend.manager.startIfNeeded(spaceID: spaceID)
        try await backend.seed(workspacePath: tmp.path)

        let env = ExecutionEnvironmentResolver.resolve(spaceTargetRaw: "tartVM", spaceID: UUID(), containerEnabled: false)
        #expect(ExecutionEnvironmentResolver.isTart(env))

        let t0 = Date()
        try await backend.writeFile(relativePath: "main.swift", content: "print(\"HELLO_RW2\")\n")
        let (out, _, code) = try await backend.runShell(command: "swiftc main.swift -o /tmp/rw2 && /tmp/rw2")
        let compileTime = Date().timeIntervalSince(t0)
        print("TIMING RW2 guest compile: \(compileTime)s")
        #expect(code == 0)
        #expect(out.contains("HELLO_RW2"))

        try await backend.writeFile(relativePath: "main.swift", content: "print(\"GOODBYE_RW2\")\n")
        let (out2, _, code2) = try await backend.runShell(command: "swiftc main.swift -o /tmp/rw2 && /tmp/rw2")
        #expect(code2 == 0)
        #expect(out2.contains("GOODBYE_RW2"))

        let (gout, _, gcode) = try await backend.git(arguments: ["log", "--oneline"])
        #expect(gcode == 0)
        #expect(gout.contains("c1") || gout.contains("c2"))

        try await backend.manager.destroy(spaceID: spaceID)
    }

    @Test("RW3 host isolation", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"), .timeLimit(.minutes(10)))
    func rw3() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try runGit(["init", "-b", "main"], cwd: tmp)
        try "hello\n".write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tmp)
        try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "c1"], cwd: tmp)
        try "world\n".write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tmp)
        try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "c2"], cwd: tmp)

        let beforeStatus = try hostGitStatus(tmp)
        let beforeHash = try sha256Tree(tmp)

        let spaceID = "rw3"
        let backend = await TartVMBackendRegistry.shared.backend(for: spaceID)
        defer { Task { try? await backend.manager.destroy(spaceID: spaceID) } }
        try await backend.manager.ensureProvisioned(spaceID: spaceID)
        try await backend.manager.startIfNeeded(spaceID: spaceID)
        try await backend.seed(workspacePath: tmp.path)

        try await backend.writeFile(relativePath: "guest-only.txt", content: "x")
        let read = try await backend.readFile(relativePath: "guest-only.txt")
        #expect(read.contains("x"))

        let afterStatus = try hostGitStatus(tmp)
        let afterHash = try sha256Tree(tmp)
        #expect(afterStatus == beforeStatus)
        #expect(afterHash == beforeHash)
        #expect(afterStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        try await backend.manager.destroy(spaceID: spaceID)
    }

    private func hostGitStatus(_ url: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", url.path, "status", "--porcelain"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func sha256Tree(_ url: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "cd '\(url.path)' && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @Test("RW4 two spaces at once", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"), .timeLimit(.minutes(15)))
    func rw4() async throws {
        let manager = VMWorkspaceManager(readyTimeoutSeconds: 600)
        let a = "rwtest-a"; let b = "rwtest-b"
        defer {
            Task { try? await manager.destroy(spaceID: a) }
            Task { try? await manager.destroy(spaceID: b) }
        }
        try await manager.ensureProvisioned(spaceID: a)
        try await manager.ensureProvisioned(spaceID: b)
        try await manager.startIfNeeded(spaceID: a)
        try await manager.startIfNeeded(spaceID: b)

        let names = try tartListNames()
        #expect(names.contains("apex-space-\(a)"))
        #expect(names.contains("apex-space-\(b)"))
        #expect(await manager.runningCount == 2)

        do {
            try await manager.ensureProvisioned(spaceID: "rwtest-c")
            try await manager.startIfNeeded(spaceID: "rwtest-c")
            #expect(Bool(false), "third VM should not start")
        } catch { }

        for (sid, marker) in [(a, "MARKER_A"), (b, "MARKER_B")] {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(sid)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try runGit(["init", "-b", "main"], cwd: tmp)
            try "x\n".write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runGit(["add", "."], cwd: tmp)
            try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "base"], cwd: tmp)
            let backend = await TartVMBackendRegistry.shared.backend(for: sid)
            try await backend.seed(workspacePath: tmp.path)
            try await backend.writeFile(relativePath: "\(marker).txt", content: marker)
        }

        let ra = try await TartVMBackendRegistry.shared.backend(for: a).readFile(relativePath: "MARKER_A.txt")
        #expect(ra.contains("MARKER_A"))
        do {
            _ = try await TartVMBackendRegistry.shared.backend(for: a).readFile(relativePath: "MARKER_B.txt")
            #expect(Bool(false))
        } catch { }
        let rb = try await TartVMBackendRegistry.shared.backend(for: b).readFile(relativePath: "MARKER_B.txt")
        #expect(rb.contains("MARKER_B"))
        do {
            _ = try await TartVMBackendRegistry.shared.backend(for: b).readFile(relativePath: "MARKER_A.txt")
            #expect(Bool(false))
        } catch { }

        try await manager.destroy(spaceID: a)
        try await manager.destroy(spaceID: b)
        try? await manager.destroy(spaceID: "rwtest-c")
        let after = try tartListNames()
        #expect(!after.contains(where: { $0.hasPrefix("apex-space-") }))
    }

    @Test("RW5 fail-closed negatives", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"), .timeLimit(.minutes(10)))
    func rw5() async throws {
        let nonGit = FileManager.default.temporaryDirectory.appendingPathComponent("nongit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: nonGit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonGit) }
        let spaceID = "rw5"
        let backend = await TartVMBackendRegistry.shared.backend(for: spaceID)
        defer { Task { try? await backend.manager.destroy(spaceID: spaceID) } }
        try await backend.manager.ensureProvisioned(spaceID: spaceID)
        try await backend.manager.startIfNeeded(spaceID: spaceID)
        do {
            try await backend.seed(workspacePath: nonGit.path)
            #expect(Bool(false), "expected throw")
        } catch {
            #expect(String(describing: error).localizedLowercase.contains("bundle") || String(describing: error).localizedLowercase.contains("git repo"))
        }

        do {
            _ = try ExecutionEnvironmentResolver.mapPath("/etc/passwd", workspacePath: "/tmp/ws")
            #expect(Bool(false))
        } catch {
            #expect(String(describing: error).contains("ERROR: path outside workspace:"))
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try runGit(["init", "-b", "main"], cwd: tmp)
        try "x\n".write(to: tmp.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tmp)
        try runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "base"], cwd: tmp)
        try await backend.seed(workspacePath: tmp.path)
        let (_, _, code) = try await backend.runShell(command: "exit 3")
        #expect(code == 3)

        try await backend.manager.destroy(spaceID: spaceID)
    }

    @Test("RW6 full production landing", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_VM"] == "1"), .timeLimit(.minutes(60)))
    func rw6() async throws {
        let workspace = URL(fileURLWithPath: "/Users/danielstevens/Developer/ApexAgent")
        let reviewClone = (NSHomeDirectory() as NSString).appendingPathComponent("ApexSandbox/review-clone")
        let spaceID = "realworld"
        let spaceName = "realworld"

        let headBefore = try gitOutput(["-C", workspace.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let branchBefore = try gitOutput(["-C", workspace.path, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let statusBefore = try gitOutput(["-C", workspace.path, "status", "--porcelain"])

        let manager = VMWorkspaceManager(readyTimeoutSeconds: 600)
        let backend = TartVMBackend(spaceID: spaceID, manager: manager, client: TartCLIClient())
        defer { Task { try? await manager.destroy(spaceID: spaceID) } }
        try await manager.ensureProvisioned(spaceID: spaceID)
        try await manager.startIfNeeded(spaceID: spaceID)
        try await backend.seed(workspacePath: workspace.path)

        try await backend.writeFile(relativePath: "RW_LIVE_MARKER.md", content: "battery date 2026-10-23\n")
        let (_, _, addc) = try await backend.git(arguments: ["add", "RW_LIVE_MARKER.md"])
        #expect(addc == 0)
        let (_, _, cc) = try await backend.git(arguments: ["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "-m", "rw live marker"])
        #expect(cc == 0)

        let svc = SpaceLandingService(client: TartCLIClient(), manager: manager, reviewClonePath: reviewClone, isApexAgent: true)
        let t0 = Date()
        let report = await svc.land(input: .init(spaceID: spaceID, spaceName: spaceName, workspacePath: workspace.path))
        let total = Date().timeIntervalSince(t0)
        print("TIMING RW6 landing total: \(total)s")
        print(report.summary)

        #expect(report.succeeded, "report: \(report.summary)")
        #expect(report.failedStage == nil)
        #expect(!report.stages.isEmpty)
        #expect(report.stages.allSatisfy { $0.status != .failed })
        let inVM = report.stages.first(where: { $0.name == "In-VM gate" })
        #expect(inVM != nil)
        #expect(report.stages.contains(where: { $0.name.lowercased().contains("bundle") }))
        let show = Process()
        show.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        show.arguments = ["-C", reviewClone, "show", "space/realworld-review:RW_LIVE_MARKER.md"]
        let sp = Pipe(); show.standardOutput = sp; show.standardError = Pipe()
        try show.run(); show.waitUntilExit()
        #expect(show.terminationStatus == 0)
        let content = String(data: sp.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(content.contains("2026-10-23"))
        let hostStage = report.stages.first(where: { $0.name == "Host pristine re-run" })
        #expect(hostStage != nil)
        #expect(hostStage?.status == .passed)
        #expect((hostStage?.failed ?? 0) == 0)

        let headAfter = try gitOutput(["-C", workspace.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let branchAfter = try gitOutput(["-C", workspace.path, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let statusAfter = try gitOutput(["-C", workspace.path, "status", "--porcelain"])
        #expect(headAfter == headBefore)
        #expect(branchAfter == branchBefore)
        #expect(branchAfter == "feat/spaces-vm")
        #expect(statusAfter == statusBefore)

        try await manager.destroy(spaceID: spaceID)
        let after = try tartListNames()
        #expect(!after.contains(where: { $0.hasPrefix("apex-space-") }))
    }

    private func gitOutput(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
