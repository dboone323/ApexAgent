import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Seatbelt confinement escape tests", .serialized)
struct SeatbeltEscapeTests {

    private func runSandbox(profile: String, command: String, cwd: String? = nil, env: [String: String]? = nil) -> (stdout: String, stderr: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        proc.arguments = ["-p", profile, "/bin/sh", "-c", command]
        if let cwd = cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = ProcessInfo.processInfo.environment
        if let extraEnv = env {
            for (k, v) in extraEnv { environment[k] = v }
        }
        proc.environment = environment

        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (out, err, proc.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }

    @Test func escapeTestA_writeInsideWorkspaceSucceeds() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sb-test-inside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let profile = SeatbeltProfile(workspacePath: tmp.path, allowNetwork: true).generate()
        let insideTarget = tmp.appendingPathComponent("inside.txt").path
        let res = runSandbox(profile: profile, command: "echo 'allowed payload' > '\(insideTarget)'")

        #expect(res.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: insideTarget))
        let content = try? String(contentsOfFile: insideTarget, encoding: .utf8)
        #expect(content?.contains("allowed payload") == true)
    }

    @Test func escapeTestB_writeToHomeDirectoryDenied() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sb-test-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let profile = SeatbeltProfile(workspacePath: tmp.path, allowNetwork: true).generate()
        let probeName = ".apex_seatbelt_escape_probe_\(UUID().uuidString).txt"
        let homeTarget = (NSHomeDirectory() as NSString).appendingPathComponent(probeName)
        defer { try? FileManager.default.removeItem(atPath: homeTarget) }

        let res = runSandbox(profile: profile, command: "echo 'forbidden' > '\(homeTarget)'")

        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("Operation not permitted") || res.stderr.contains("Permission denied"))
        #expect(!FileManager.default.fileExists(atPath: homeTarget))
    }

    @Test func escapeTestC_writeToOriginRepoGitDenied() throws {
        let origin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("sb-origin-\(UUID().uuidString)")
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sb-clone-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: origin)
            try? FileManager.default.removeItem(at: ws)
        }

        func runGit(_ args: [String], cwd: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = cwd
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: nil)
            }
        }

        try runGit(["init", "-b", "main"], cwd: origin)
        try runGit(["config", "user.name", "test"], cwd: origin)
        try runGit(["config", "user.email", "test@test.com"], cwd: origin)
        let initFile = origin.appendingPathComponent("base.txt")
        try "base\n".write(to: initFile, atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: origin)
        try runGit(["commit", "-m", "init"], cwd: origin)

        // Clone --shared into ws
        let cloneProc = Process()
        cloneProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        cloneProc.arguments = ["clone", "--shared", origin.path, ws.path]
        try cloneProc.run(); cloneProc.waitUntilExit()
        guard cloneProc.terminationStatus == 0 else {
            Issue.record("Failed to clone --shared")
            return
        }

        let profile = SeatbeltProfile(workspacePath: ws.path, allowNetwork: true).generate()
        let originGitProbe = origin.appendingPathComponent(".git").appendingPathComponent("hacked_probe.txt").path

        let res = runSandbox(profile: profile, command: "echo 'hack' > '\(originGitProbe)'")
        #expect(res.exitCode != 0)
        #expect(res.stderr.contains("Operation not permitted") || res.stderr.contains("Permission denied"))
        #expect(!FileManager.default.fileExists(atPath: originGitProbe))
    }

    @Test func escapeTestD_networkDeniedOutboundFails() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sb-test-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let profile = SeatbeltProfile(workspacePath: tmp.path, allowNetwork: false).generate()
        let res = runSandbox(profile: profile, command: "nc -z -w 1 1.1.1.1 80")

        #expect(res.exitCode != 0)
    }

    @Test func escapeTestE_trivialCommandRunsUnderProfile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sb-test-echo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let profile = SeatbeltProfile(workspacePath: tmp.path, allowNetwork: true).generate()
        let res = runSandbox(profile: profile, command: "/bin/echo 'seatbelt confinement confirmed'")

        #expect(res.exitCode == 0)
        #expect(res.stdout.contains("seatbelt confinement confirmed"))
    }
}
