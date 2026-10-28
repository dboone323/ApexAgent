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
        let spaceID = "smoke-stage1-\(UUID().uuidString.prefix(8))"
        let report = await svc.land(input: .init(spaceID: spaceID, spaceName: "smoke", workspacePath: tmp.path))
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
        let spaceID = "smoke-tamper-\(UUID().uuidString.prefix(8))"
        let report = await svc.land(input: .init(spaceID: spaceID, spaceName: "smoke", workspacePath: tmp.path))
        #expect(!report.succeeded)
        #expect(report.failedStage == "Test-integrity check")
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test func runProcessSafelyHandlesLargeOutputWithoutDeadlock() async {
        let script = "print('A' * 200000)"
        let res = await SpaceLandingService.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script],
            timeoutSeconds: 15
        )
        #expect(res.exitCode == 0)
        #expect(res.stdout.count >= 200000)
        #expect(res.stderr.isEmpty)
    }

    @Test func runProcessSafelyPropagatesExitCodeAndStderrOnFailure() async {
        let res = await SpaceLandingService.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", "/nonexistent-path-for-apex-test", "status"],
            timeoutSeconds: 10
        )
        #expect(res.exitCode != 0)
        #expect(res.stdout.isEmpty)
        #expect(!res.stderr.isEmpty)
    }

    @Test func toolEventLoggerImplEmitsStructuredDiagnosticsToAppLog() async {
        let logger = await MainActor.run { ToolEventLoggerImpl() }
        let toolName = "test_pipe_diagnostic_tool_\(UUID().uuidString.prefix(8))"
        let args = "{\"query\": \"safe-pipe-test\"}"

        await MainActor.run {
            logger.logToolStart(name: toolName, arguments: args)
            logger.updateToolStatus(name: toolName, status: .running)
            logger.logToolEnd(name: toolName, result: "pipe drain ok", status: .success)
            logger.resolveConfirmation(approved: true)
        }

        let entries = AppLog.recentEntries(limit: 50)
        let relevant = entries.filter { $0.category == .toolbox && $0.message.contains(toolName) }
        #expect(!relevant.isEmpty)
        #expect(relevant.contains { $0.message.contains("started with arguments") })
        #expect(relevant.contains { $0.message.contains("status updated to: running") })
        #expect(relevant.contains { $0.message.contains("ended with status: success") })
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
