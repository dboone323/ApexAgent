import Testing
import Foundation
@testable import ApexAgentCore

@Suite("ProcessRunner tests")
struct ProcessRunnerTests {

    @Test func runProcessSafelyHandlesLargeOutputWithoutDeadlock() async {
        let script = "print('A' * 200000)"
        let res = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script],
            timeoutSeconds: 15
        )
        #expect(res.exitCode == 0)
        #expect(res.stdout.count >= 200000)
        #expect(res.stderr.isEmpty)
    }

    @Test func runProcessSafelyPropagatesExitCodeAndStderrOnFailure() async {
        let res = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", "/nonexistent-path-for-apex-test", "status"],
            timeoutSeconds: 10
        )
        #expect(res.exitCode != 0)
        #expect(res.stdout.isEmpty)
        #expect(!res.stderr.isEmpty)
    }

    @Test func runProcessSafelyKillsSIGTERMIgnoringChild() async {
        let start = Date()
        let res = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap \"\" TERM; sleep 120"],
            timeoutSeconds: 2
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 20)
        #expect(res.exitCode != 0)
    }

    @Test func runProcessSafelyReturnsWhenGrandchildHoldsPipes() async {
        let start = Date()
        let res = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(sleep 120 &) ; echo done"],
            timeoutSeconds: 2
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 20)
        #expect(res.stdout.contains("done"))
    }
}
