import Testing
import Foundation
@testable import ApexAgentCore

struct SpaceLandingServiceTests {

    @Test func integrityAdditionsOnlyPasses() {
        let diff = "A\tApexAgentTests/NewTests.swift\nA\tFooTests/Bar.swift\nM\tSources/App.swift\n"
        #expect(SpaceLandingService.integrityViolations(diffOutput: diff).isEmpty)
    }

    @Test func integrityDeletedTestFileFails() {
        let diff = "D\tApexAgentTests/OldTests.swift\n"
        let v = SpaceLandingService.integrityViolations(diffOutput: diff)
        #expect(!v.isEmpty)
    }

    @Test func integrityModifiedExistingTestFails() {
        let diff = "M\tApexAgentTests/ExistingTests.swift\n"
        let v = SpaceLandingService.integrityViolations(diffOutput: diff)
        #expect(!v.isEmpty)
    }

    @Test func integrityDeletedIndividualTestFails() {
        // git diff --name-status won't show individual test deletion; simulate renamed? Use M as modified.
        let diff = "M\tApexAgentTests/ExistingTests.swift\n"
        let v = SpaceLandingService.integrityViolations(diffOutput: diff)
        #expect(!v.isEmpty)
    }

    @Test func orchestrationFailureAtStage1NoLater() async throws {
        let fake = FakeTartClient()
        // make VM start fail by not provisioning? Fake list empty, clone works, exec returns failure for echo ok? startIfNeeded polls exec; Fake execResult default ok, so ready. To fail stage1 seed, set execResult? seed bundle: fake exec returns ok always, so seed passes. Instead make base commit process? We'll make client exec return non-zero for build by setting execResult failure.
        await fake.setExecResult((stdout: "", stderr: "boom", exitCode: 1))
        let mgr = VMWorkspaceManager(client: fake, readyTimeoutSeconds: 1)
        let svc = SpaceLandingService(client: fake, manager: mgr, reviewClonePath: NSTemporaryDirectory() + "rc-\(UUID().uuidString)", isApexAgent: true, hostTestRunner: nil)
        // need a git repo workspace
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try? runGit(["init"], cwd: tmp)
        _ = try? runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "--allow-empty", "-m", "base"], cwd: tmp)
        let report = await svc.land(input: .init(spaceID: "smoke", spaceName: "smoke", workspacePath: tmp.path))
        #expect(!report.succeeded)
        #expect(report.failedStage == "In-VM gate")
        // no quarantine branch created
        #expect(report.quarantineBranch == nil)
        // cleanup
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test func orchestrationTamperRefusedAtIntegrity() async throws {
        let fake = FakeTartClient()
        await fake.setExecResult((stdout: "ok\nD\tApexAgentTests/X.swift\nANCESTOR_OK\n", stderr: "", exitCode: 0))
        let mgr = VMWorkspaceManager(client: fake, readyTimeoutSeconds: 1)
        let tmpRC = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)").path
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try? runGit(["init"], cwd: tmp)
        _ = try? runGit(["-c", "user.email=t@t.com", "-c", "user.name=t", "commit", "--allow-empty", "-m", "base"], cwd: tmp)
        let svc = SpaceLandingService(client: fake, manager: mgr, reviewClonePath: tmpRC, isApexAgent: true, hostTestRunner: { (true,0,0,0,0,"ok") })
        let report = await svc.land(input: .init(spaceID: "smoke", spaceName: "smoke", workspacePath: tmp.path))
        #expect(!report.succeeded)
        #expect(report.failedStage == "Test-integrity check")
        try? FileManager.default.removeItem(at: tmp)
    }
}

// helper
func runGit(_ args: [String], cwd: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = cwd
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { throw NSError(domain: "git", code: Int(p.terminationStatus)) }
}
