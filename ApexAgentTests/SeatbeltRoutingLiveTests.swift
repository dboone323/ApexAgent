import Testing
import Foundation
@testable import ApexAgentCore

@Suite("SeatbeltRoutingLiveTests", .serialized)
struct SeatbeltRoutingLiveTests {

    @Test("seatbelt routing live smoke", .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_SEATBELT"] == "1"), .timeLimit(.minutes(5)))
    func smoke() async throws {
        // Scratch origin git repo
        let origin = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-origin-\(UUID().uuidString)")
        let spaceWs = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-space-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spaceWs, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: origin)
            try? FileManager.default.removeItem(at: spaceWs)
        }

        func runGit(_ args: [String], cwd: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = cwd
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
            }
        }

        try runGit(["init", "-b", "main"], cwd: origin)
        try runGit(["config", "user.name", "SeatbeltTester"], cwd: origin)
        try runGit(["config", "user.email", "seatbelt@test.local"], cwd: origin)
        try "initial\n".write(to: origin.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: origin)
        try runGit(["commit", "-m", "init"], cwd: origin)

        let space = SpaceModel(
            name: "seatbelt-live-space",
            workspacePath: spaceWs.path,
            executionTargetRaw: "seatbelt"
        )
        #expect(space.isSeatbelt == true)

        let backend = SeatbeltBackend(spaceID: space.id.uuidString, workspacePath: spaceWs.path, allowNetwork: true)
        try await backend.seed(workspacePath: origin.path)

        // 1. Real shell execution under profile
        let (out, err, code) = try await backend.runShell(command: "echo 'SEATBELT_LIVE_OK' && pwd")
        #expect(code == 0)
        #expect(out.contains("SEATBELT_LIVE_OK"))
        #expect(err.isEmpty)

        // 2. Real file write + read under profile
        try await backend.writeFile(relativePath: "live_test.txt", content: "live file contents")
        let readBack = try await backend.readFile(relativePath: "live_test.txt")
        #expect(readBack.contains("live file contents"))

        // 3. Real git operations under profile
        let (_, _, addCode) = try await backend.git(arguments: ["add", "."])
        #expect(addCode == 0)
        let (_, _, commitCode) = try await backend.git(arguments: ["-c", "user.name=SeatbeltTester", "-c", "user.email=seatbelt@test.local", "commit", "-m", "seatbelt commit"])
        #expect(commitCode == 0)

        let (logOut, _, logCode) = try await backend.git(arguments: ["log", "--oneline", "-n", "1"])
        #expect(logCode == 0)
        #expect(logOut.contains("seatbelt commit"))

        // 4. Real toolchain compile: xcodebuild -version
        let (xcOut, _, xcCode) = try await backend.runShell(command: "xcodebuild -version")
        #expect(xcCode == 0)
        #expect(xcOut.contains("Xcode"))

        // 5. Real toolchain compile: swift package init + swift build
        let pkgDir = "ScratchPackage"
        let pkgPath = (spaceWs.path as NSString).appendingPathComponent(pkgDir)
        try FileManager.default.createDirectory(atPath: pkgPath, withIntermediateDirectories: true)

        let (_, initErr, initCode) = try await backend.runShell(command: "cd ScratchPackage && swift package init --type executable")
        #expect(initCode == 0, "swift package init failed: \(initErr)")

        let (buildOut, buildErr, buildCode) = try await backend.runShell(command: "cd ScratchPackage && swift build --disable-sandbox")
        #expect(buildCode == 0, "swift build failed (code \(buildCode)): stdout=\(buildOut), stderr=\(buildErr)")
    }
}
