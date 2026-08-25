import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O1: RepeatDetector (port of OpenMausBot repeat-detector.ts)

@Suite("RepeatDetectorTests")
struct RepeatDetectorTests {

    @Test func callKeyNormalizesWhitespace() {
        #expect(RepeatCallKey.make(tool: "run_shell_command", arguments: "  echo   hi  ")
            == "run_shell_command:echo hi")
    }

    @Test func callKeyNilForMissingOrBareArgs() {
        #expect(RepeatCallKey.make(tool: "run_shell_command", arguments: nil) == nil)
        #expect(RepeatCallKey.make(tool: "run_shell_command", arguments: "") == nil)
        #expect(RepeatCallKey.make(tool: "run_shell_command", arguments: "run_shell_command") == nil)
    }

    @Test func recordHitsConfiguredThreshold() {
        let detector = RepeatDetector(thresholds: [3, 5])
        let key = RepeatCallKey.make(tool: "web_search", arguments: "query: apex")!
        for n in 1...5 {
            let result = detector.record(thread: "t1", key: key)
            if n == 3 { #expect(result.threshold == 3) }
            if n == 5 { #expect(result.threshold == 5) }
        }
        #expect(detector.activeKeys(thread: "t1") == 1)
    }

    @Test func threadsAreIndependent() {
        let detector = RepeatDetector(thresholds: [3])
        let key = RepeatCallKey.make(tool: "read_file", arguments: "/a")!
        for _ in 1...3 { _ = detector.record(thread: "t1", key: key) }
        _ = detector.record(thread: "t2", key: key)
        #expect(detector.activeKeys(thread: "t1") == 1)
        #expect(detector.activeKeys(thread: "t2") == 1)
    }

    @Test func settleResetsTurnCount() {
        let detector = RepeatDetector(thresholds: [3])
        let key = RepeatCallKey.make(tool: "run_shell_command", arguments: "git status")!
        _ = detector.record(thread: "t", key: key)
        let result = detector.record(thread: "t", key: key)
        #expect(result.threshold == nil)
        detector.settle(thread: "t")
        _ = detector.record(thread: "t", key: key)
        let after = detector.record(thread: "t", key: key)
        #expect(after.threshold == nil) // count restarted at 1,2
    }

    @Test func lruBoundsKeysPerThread() {
        let detector = RepeatDetector(thresholds: [10], maxKeysPerThread: 3)
        for i in 0..<5 {
            _ = detector.record(thread: "t", key: "k\(i)")
        }
        // "k0" was evicted; it now counts from 1 again
        let k0 = detector.record(thread: "t", key: "k0")
        #expect(k0.count == 1)
    }
}

// MARK: - O2: SecretRedactor (port of OpenMausBot redact.ts)

@Suite("SecretRedactorTests")
struct SecretRedactorTests {

    @Test func redactsOpenAIAndGithubKeys() {
        let out = SecretRedactor.redact(text: "key=sk-ant-api03-abcdefghijklmnopqrstuvwxyz and ghp_1234567890ABCDEFGHIJ")
        #expect(!out.contains("sk-ant-api03"))
        #expect(!out.contains("ghp_1234567890"))
        #expect(out.contains("«redacted"))
    }

    @Test func redactsBearerTokens() {
        let out = SecretRedactor.redact(text: "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345")
        #expect(!out.contains("abcdefghijklmnopqrstuvwxyz012345"))
        #expect(out.contains("Bearer"))
    }

    @Test func redactsKeyValueLines() {
        let out = SecretRedactor.redact(text: "export MY_API_KEY=supersecretvalue123")
        #expect(!out.contains("supersecretvalue123"))
        #expect(out.contains("MY_API_KEY=«redacted"))
    }

    @Test func redactsPEMBlocks() {
        let key = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFA\n-----END PRIVATE KEY-----"
        let out = SecretRedactor.redact(text: key)
        #expect(!out.contains("MIIEvQIBADANBgkqhkiG9w0BAQEFA"))
        #expect(out.contains("BEGIN PRIVATE KEY"))
    }

    @Test func redactEnvironmentMasksSecretKeysOnly() {
        let env = [
            "ANTHROPIC_API_KEY": "sk-ant-abcdefghijklmnopqrstuvwxyz",
            "HOME": "/Users/me",
        ]
        let out = SecretRedactor.redactEnvironment(env)
        #expect(out["ANTHROPIC_API_KEY"]?.contains("sk-ant") == false)
        #expect(out["HOME"] == "/Users/me")
    }

    @Test func isSecretNameMatchesSuffixKeys() {
        #expect(SecretRedactor.isSecretName("api_key"))
        #expect(SecretRedactor.isSecretName("consumer-key"))
        #expect(SecretRedactor.isSecretName("xai_key"))
        #expect(!SecretRedactor.isSecretName("keyboard"))
        #expect(!SecretRedactor.isSecretName("hotkeys"))
    }
}

// MARK: - O3: ApprovalPolicy (port of OpenMausBot auto-approve.ts)

@Suite("ApprovalPolicyTests")
struct ApprovalPolicyTests {

    @Test func destructiveGuardAlwaysBlocks() {
        let v = ApprovalPolicy.verdict(tool: "run_shell_command", summary: "rm -rf /tmp/x", autoApprove: true)
        #expect(v.approve == nil)
        #expect(v.source == .destructiveGuard)
    }

    @Test func sensitiveGuardBlocksEnvRead() {
        let v = ApprovalPolicy.verdict(tool: "run_shell_command", summary: "cat ~/project/.env", alwaysAllow: ["run_shell_command:cat"])
        #expect(v.approve == nil)
        #expect(v.source == .sensitiveGuard)
    }

    @Test func alwaysAllowApprovesForSpecificProgram() {
        let key = ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "git status")
        #expect(key == "run_shell_command:git")
        let v = ApprovalPolicy.verdict(tool: "run_shell_command", summary: "git status", alwaysAllow: [key])
        #expect(v.source == .alwaysAllow)
        #expect(v.approve != nil)
    }

    @Test func alwaysAllowNeverCoversDifferentProgram() {
        let v = ApprovalPolicy.verdict(tool: "run_shell_command", summary: "rm file.txt", alwaysAllow: ["run_shell_command:git"])
        #expect(v.approve == nil)
    }

    @Test func approvalKeySkipsEnvAndSudo() {
        #expect(ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "ENV=1 sudo /usr/bin/git push")
            == "run_shell_command:git")
        #expect(ApprovalPolicy.approvalKey(tool: "read_file", summary: "whatever") == "read_file")
        #expect(ApprovalPolicy.approvalKey(tool: "mcp__filesystem__read_file", summary: "x") == "mcp__filesystem__read_file")
    }

    @Test func autoModeApprovesSafeTools() {
        let v = ApprovalPolicy.verdict(tool: "read_file", summary: "read /a/b.txt", autoApprove: true)
        #expect(v.source == .autoMode)
        #expect(v.approve != nil)
    }

    @Test func noGrantAsks() {
        let v = ApprovalPolicy.verdict(tool: "read_file", summary: "read /a/b.txt")
        #expect(v.approve == nil)
        #expect(v.source == .noGrant)
    }

    @Test func unattendedBlocksEvenAnAlwaysAllowGrant() {
        let key = ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "git status")
        let v = ApprovalPolicy.verdict(
            tool: "run_shell_command", summary: "git status",
            alwaysAllow: [key], unattended: true)
        #expect(v.approve == nil)
        #expect(v.source == .unattendedBlock)
        #expect(v.rule == key)
    }

    @Test func localScopeBlocksGrantUnlessAutoMode() {
        let key = ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "git status")
        let v = ApprovalPolicy.verdict(tool: "run_shell_command", summary: "git status", alwaysAllow: [key], localScope: true)
        #expect(v.approve == nil)
        #expect(v.source == .localComputerBlock)
    }
}

// MARK: - O4: TurnWatchdog (port of OpenMausBot turn-watchdog.ts)

@Suite("TurnWatchdogTests")
struct TurnWatchdogTests {

    @Test func stallFiresOnStallExactlyOnce() {
        var time = 0.0
        var stalled: [WatchedTurn] = []
        let watchdog = TurnWatchdog(options: .init(
            stallMs: 1_000, checkMs: 500,
            onStall: { stalled.append($0) },
            now: { time }
        ))
        watchdog.watch(threadId: "t", botId: "b")
        watchdog.touch(threadId: "t")
        watchdog.sweep()
        #expect(stalled.isEmpty) // fresh

        time = 2_000
        watchdog.sweep()
        #expect(stalled.count == 1)
        #expect(stalled[0].threadId == "t")

        watchdog.sweep() // removed → no double fire
        #expect(stalled.count == 1)
        #expect(!watchdog.isWatching(threadId: "t"))
    }

    @Test func touchResetsTheClock() {
        var time = 0.0
        var stalled: [WatchedTurn] = []
        let watchdog = TurnWatchdog(options: .init(
            stallMs: 1_000, checkMs: 500,
            onStall: { stalled.append($0) },
            now: { time }
        ))
        watchdog.watch(threadId: "t", botId: "b")
        time = 900
        watchdog.touch(threadId: "t")
        time = 1_000
        watchdog.sweep()
        #expect(stalled.isEmpty) // activity restarted the clock
    }

    @Test func waitingOnHumanIsExempt() {
        var time = 0.0
        var stalled: [WatchedTurn] = []
        let watchdog = TurnWatchdog(options: .init(
            stallMs: 1_000, checkMs: 500,
            onStall: { stalled.append($0) },
            now: { time }
        ))
        watchdog.watch(threadId: "t", botId: "b")
        watchdog.setWaitingOnHuman(threadId: "t", waiting: true)
        time = 10_000
        watchdog.sweep()
        #expect(stalled.isEmpty)
        #expect(watchdog.isWatching(threadId: "t"))
    }

    @Test func settleStopsWatching() {
        var time = 0.0
        let watchdog = TurnWatchdog(options: .init(
            stallMs: 1_000, checkMs: 500,
            onStall: { _ in },
            now: { time }
        ))
        watchdog.watch(threadId: "t", botId: "b")
        watchdog.settle(threadId: "t")
        time = 2_000
        watchdog.sweep()
        #expect(!watchdog.isWatching(threadId: "t"))
    }
}

// MARK: - O5: Routine webhook trigger + run receipts

@Suite("RoutineWebhookAndRunTests")
struct RoutineWebhookAndRunTests {

    @Test func routineTriggerGainsWebhook() {
        #expect(RoutineTrigger.webhook.rawValue == "Webhook")
        #expect(RoutineTrigger.allCases.contains(.webhook))
    }

    @Test func routineRunStatusLifecycle() {
        var run = RoutineRun(routineId: UUID(), routineName: "nightly", prompt: "p")
        #expect(run.status.isActive)
        run.status = .running
        #expect(run.status.isActive)
        run.status = .completed
        #expect(!run.status.isActive)
        run.finishedAt = Date()
        #expect(run.finishedAt != nil)
    }

    @Test func routineRunCodableRoundTrip() throws {
        let run = RoutineRun(
            routineId: UUID(), routineName: "webhook-job", prompt: "p",
            trigger: .webhook, status: .queued
        )
        let data = try JSONEncoder().encode(run)
        let back = try JSONDecoder().decode(RoutineRun.self, from: data)
        #expect(back.routineName == "webhook-job")
        #expect(back.trigger == .webhook)
        #expect(back.status == .queued)
    }

    @Test func routineRunSnapshotsPrompt() {
        let run = RoutineRun(routineId: UUID(), routineName: "r", prompt: "original")
        #expect(run.prompt == "original")
        #expect(run.routineId != run.id)
    }
}