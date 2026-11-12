import Foundation
import Darwin

// MARK: - Long Run CLI (Issue #77)

/// CLI handler for `ApexAgent longrun` subcommands and live verifications.
public enum LongRunCLI {
    private static func printOut(_ message: String) {
        fputs("\(message)\n", Darwin.stdout)
    }

    private static func printErr(_ message: String) {
        fputs("\(message)\n", Darwin.stderr)
    }

    public static func run(arguments: [String]) async -> Int32 {
        guard let action = arguments.first else {
            printUsage()
            return 0
        }

        let subArgs = Array(arguments.dropFirst())

        switch action {
        case "start":
            return await handleStart(arguments: subArgs)
        case "pause":
            return await handlePause(arguments: subArgs)
        case "resume":
            return await handleResume(arguments: subArgs)
        case "interrupt":
            return await handleInterrupt(arguments: subArgs)
        case "status":
            return await handleStatus(arguments: subArgs)
        case "list":
            return await handleList(arguments: subArgs)
        case "recover":
            return await handleRecover(arguments: subArgs)
        case "verify":
            return await handleVerify(arguments: subArgs)
        case "--help", "-h", "help":
            printUsage()
            return 0
        default:
            printErr("Unknown longrun action '\(action)'. Run 'ApexAgent longrun --help' for usage.")
            return 64
        }
    }

    private static func printUsage() {
        printOut("""
        Usage: ApexAgent longrun <action> [options]

        Actions:
          start       Start a new long run from inline steps or spec
          pause       Pause an active long run cleanly
          resume      Resume a paused or interrupted long run from checkpoint
          interrupt   Cleanly interrupt a long run mid-task
          status      Show status and checkpoint details of a run
          list        List all long runs in the durable store
          recover     Discover and recover crashed or unclosed runs
          verify      Execute live verification test matrix (Issue #77)

        Options for start:
          --name <string>        Name for the run (default: 'CLI Run')
          --steps <count>        Number of shell echo steps to generate
          --time-budget <sec>    Max wall-clock seconds budget
          --token-budget <int>   Max tokens budget
          --step-budget <int>    Max steps budget
          --retries <int>        Max retries per step (default: 3)

        Options for status/resume/pause/interrupt:
          <run-uuid>             UUID of the target long run

        Options for verify:
          --scenario <name>      checkpoint | pause-resume | retry-backoff | budgets | crash-recovery | all
        """)
    }

    private static func handleStart(arguments: [String]) async -> Int32 {
        var name = "CLI Run"
        var stepCount = 3
        var timeBudget: TimeInterval?
        var tokenBudget: Int?
        var stepBudget: Int?
        var retries = 3

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--name":
                if i + 1 < arguments.count { name = arguments[i + 1]; i += 1 }
            case "--steps":
                if i + 1 < arguments.count, let c = Int(arguments[i + 1]) { stepCount = c; i += 1 }
            case "--time-budget":
                if i + 1 < arguments.count, let t = Double(arguments[i + 1]) { timeBudget = t; i += 1 }
            case "--token-budget":
                if i + 1 < arguments.count, let b = Int(arguments[i + 1]) { tokenBudget = b; i += 1 }
            case "--step-budget":
                if i + 1 < arguments.count, let s = Int(arguments[i + 1]) { stepBudget = s; i += 1 }
            case "--retries":
                if i + 1 < arguments.count, let r = Int(arguments[i + 1]) { retries = r; i += 1 }
            default:
                break
            }
            i += 1
        }

        var steps: [LongRunStepSpec] = []
        for idx in 1...stepCount {
            steps.append(LongRunStepSpec(
                id: "step-\(idx)",
                title: "Execution step \(idx)",
                kind: .shellCommand,
                inputPayload: ["command": "echo 'ApexAgent longrun step \(idx) output'"],
                estimatedTokens: 25
            ))
        }

        let spec = LongRunSpec(
            name: name,
            steps: steps,
            budgetPolicy: LongRunBudgetPolicy(
                maxWallClockSeconds: timeBudget,
                maxTokens: tokenBudget,
                maxSteps: stepBudget
            ),
            retryPolicy: LongRunRetryPolicy(maxRetries: retries)
        )

        printOut("Starting long run '\(spec.name)' (ID: \(spec.id.uuidString)) with \(steps.count) steps...")
        do {
            let coordinator = LongRunCoordinator.shared
            let ckpt = try await coordinator.start(spec: spec)
            printOut(ckpt.formatMarkdownReceipt())
            return ckpt.status == .completed ? 0 : 1
        } catch {
            printErr("Failed to start long run: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handlePause(arguments: [String]) async -> Int32 {
        guard let idStr = arguments.first, let runId = UUID(uuidString: idStr) else {
            printErr("Error: Missing or invalid run UUID.")
            return 64
        }
        do {
            let ckpt = try await LongRunCoordinator.shared.pause(runId: runId)
            printOut("Paused long run '\(runId.uuidString)'. Status: \(ckpt.status.badge), Checkpoint seq: \(ckpt.sequenceNumber)")
            return 0
        } catch {
            printErr("Failed to pause long run: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleResume(arguments: [String]) async -> Int32 {
        guard let idStr = arguments.first, let runId = UUID(uuidString: idStr) else {
            printErr("Error: Missing or invalid run UUID.")
            return 64
        }
        do {
            printOut("Resuming long run '\(runId.uuidString)'...")
            let ckpt = try await LongRunCoordinator.shared.resume(runId: runId)
            printOut(ckpt.formatMarkdownReceipt())
            return ckpt.status == .completed ? 0 : 1
        } catch {
            printErr("Failed to resume long run: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleInterrupt(arguments: [String]) async -> Int32 {
        guard let idStr = arguments.first, let runId = UUID(uuidString: idStr) else {
            printErr("Error: Missing or invalid run UUID.")
            return 64
        }
        let reason = arguments.count > 1 ? arguments.dropFirst().joined(separator: " ") : "CLI user interrupt"
        do {
            let ckpt = try await LongRunCoordinator.shared.interrupt(runId: runId, reason: reason)
            printOut("Interrupted long run '\(runId.uuidString)'. Status: \(ckpt.status.badge), Checkpoint seq: \(ckpt.sequenceNumber)")
            return 0
        } catch {
            printErr("Failed to interrupt long run: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleStatus(arguments: [String]) async -> Int32 {
        guard let idStr = arguments.first, let runId = UUID(uuidString: idStr) else {
            printErr("Error: Missing or invalid run UUID.")
            return 64
        }
        if let ckpt = await LongRunCheckpointStore.shared.loadLatestCheckpoint(runId: runId) {
            printOut(ckpt.formatMarkdownReceipt())
            return 0
        } else {
            printErr("Run '\(idStr)' not found.")
            return 1
        }
    }

    private static func handleList(arguments: [String]) async -> Int32 {
        let runs = await LongRunCheckpointStore.shared.listAllRuns()
        guard !runs.isEmpty else {
            printOut("No long runs found in checkpoint store.")
            return 0
        }
        printOut("# 🗄️ Durable Long Runs (\(runs.count) entries)\n")
        printOut("| Run ID | Name | Status | Steps | Seq | Saved At |")
        printOut("|---|---|---|---|---|---|")
        for r in runs {
            printOut("| `\(r.runId.uuidString.prefix(8))...` | \(r.spec.name) | \(r.status.badge) | \(r.completedStepIds.count)/\(r.spec.steps.count) | `\(r.sequenceNumber)` | `\(r.savedAt)` |")
        }
        return 0
    }

    private static func handleRecover(arguments: [String]) async -> Int32 {
        let recovered = await LongRunCoordinator.shared.recoverInterruptedRuns()
        printOut("Discovered and recovered \(recovered.count) crashed/unclosed run(s).")
        for r in recovered {
            printOut("- Recovered run: \(r.runId.uuidString) (\(r.spec.name)) -> \(r.status.badge)")
        }
        return 0
    }

    // MARK: - Live Verification Scenarios (Issue #77)

    private static func handleVerify(arguments: [String]) async -> Int32 {
        var scenario = "all"
        if let idx = arguments.firstIndex(of: "--scenario"), idx + 1 < arguments.count {
            scenario = arguments[idx + 1]
        }

        printOut("=== 🚀 ApexAgent Long Run Live Verification Suite ===")
        printOut("Timestamp: \(Date())")
        printOut("Target Scenario: \(scenario)\n")

        var overallSuccess = true

        if scenario == "all" || scenario == "checkpoint" {
            let ok = await verifyCheckpointedState()
            overallSuccess = overallSuccess && ok
        }
        if scenario == "all" || scenario == "pause-resume" {
            let ok = await verifyPauseResumeInterrupt()
            overallSuccess = overallSuccess && ok
        }
        if scenario == "all" || scenario == "retry-backoff" {
            let ok = await verifyRetryWithBackoff()
            overallSuccess = overallSuccess && ok
        }
        if scenario == "all" || scenario == "budgets" {
            let ok = await verifyRunBudgets()
            overallSuccess = overallSuccess && ok
        }
        if scenario == "all" || scenario == "crash-recovery" {
            let ok = await verifyCrashRecovery()
            overallSuccess = overallSuccess && ok
        }

        printOut("\n=== 🏁 Live Verification Summary ===")
        printOut("Verdict: \(overallSuccess ? "ALL 5 PIECES VERIFIED LIVE PASS" : "FAILURES DETECTED")")
        return overallSuccess ? 0 : 1
    }

    /// Verification Piece 1: Checkpointed state durably saved as it progresses
    private static func verifyCheckpointedState() async -> Bool {
        printOut("--- [1/5] Verifying Checkpointed State ---")
        let runId = UUID()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apex_lr_test_\(runId.uuidString)")
        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let step1 = LongRunStepSpec(id: "s1", title: "Step 1", kind: .shellCommand, inputPayload: ["command": "echo 'step1'"])
        let step2 = LongRunStepSpec(id: "s2", title: "Step 2", kind: .shellCommand, inputPayload: ["command": "echo 'step2'"])
        let spec = LongRunSpec(id: runId, name: "Checkpoint Verification Run", steps: [step1, step2])

        do {
            let finalCkpt = try await coordinator.start(spec: spec)
            let latestOnDisk = await store.loadLatestCheckpoint(runId: runId)
            guard let disk = latestOnDisk else {
                printErr("❌ Checkpoint file missing on disk!")
                return false
            }
            guard disk.status == .completed else {
                printErr("❌ Expected completed status on disk, got: \(disk.status)")
                return false
            }
            guard disk.sequenceNumber >= 2 else {
                printErr("❌ Expected sequence number >= 2, got: \(disk.sequenceNumber)")
                return false
            }
            // Check historical sequence files
            let seq0 = await store.loadCheckpointSequence(runId: runId, sequence: 0)
            let seq1 = await store.loadCheckpointSequence(runId: runId, sequence: 1)
            guard seq0 != nil && seq1 != nil else {
                printErr("❌ Historical sequence snapshots missing on disk!")
                return false
            }
            try? FileManager.default.removeItem(at: tempDir)
            printOut("✅ Checkpointed state: durable checkpoints verified on disk (seq \(finalCkpt.sequenceNumber), status: \(disk.status.badge)).")
            return true
        } catch {
            printErr("❌ Checkpointed state failed: \(error)")
            return false
        }
    }

    /// Verification Piece 2: Pause, resume, and interrupt
    private static func verifyPauseResumeInterrupt() async -> Bool {
        printOut("--- [2/5] Verifying Pause / Resume / Interrupt ---")
        let runId = UUID()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apex_lr_pause_\(runId.uuidString)")
        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let step1 = LongRunStepSpec(id: "step-fast", title: "Fast step", kind: .shellCommand, inputPayload: ["command": "echo 'done 1'"])
        let step2 = LongRunStepSpec(id: "step-delay", title: "Delay step", kind: .sleepDelay, inputPayload: ["seconds": "0.6"])
        let step3 = LongRunStepSpec(id: "step-final", title: "Final step", kind: .shellCommand, inputPayload: ["command": "echo 'done 3'"])
        let spec = LongRunSpec(id: runId, name: "Pause-Resume Run", steps: [step1, step2, step3])

        do {
            // Start in background task
            let startTask = Task {
                try await coordinator.start(spec: spec)
            }

            // Request pause shortly after start
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            _ = try await coordinator.pause(runId: runId)
            let pausedCkpt = try await startTask.value

            guard pausedCkpt.status == .paused else {
                printErr("❌ Run did not enter .paused state, got: \(pausedCkpt.status)")
                return false
            }
            printOut("   -> Run paused cleanly at step \(pausedCkpt.currentStepIndex) (checkpoint seq: \(pausedCkpt.sequenceNumber))")

            // Verify checkpoint on disk is .paused
            let onDisk = await store.loadLatestCheckpoint(runId: runId)
            guard onDisk?.status == .paused else {
                printErr("❌ Durable checkpoint on disk does not reflect paused status!")
                return false
            }

            // Resume run
            let resumedCkpt = try await coordinator.resume(runId: runId)
            guard resumedCkpt.status == .completed else {
                printErr("❌ Resumed run did not complete, got: \(resumedCkpt.status)")
                return false
            }
            guard resumedCkpt.completedStepIds.count == 3 else {
                printErr("❌ Expected 3 completed steps, got: \(resumedCkpt.completedStepIds.count)")
                return false
            }
            printOut("   -> Run resumed from checkpoint and completed all 3 steps.")

            // Verify Interrupt on separate run
            let intRunId = UUID()
            let intSpec = LongRunSpec(id: intRunId, name: "Interrupt Run", steps: [
                LongRunStepSpec(id: "i1", title: "Delay", kind: .sleepDelay, inputPayload: ["seconds": "1.0"]),
                LongRunStepSpec(id: "i2", title: "Echo", kind: .shellCommand, inputPayload: ["command": "echo 'never'"])
            ])
            let intTask = Task {
                try await coordinator.start(spec: intSpec)
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            let intResult = try await coordinator.interrupt(runId: intRunId, reason: "Live verification test interrupt")
            _ = try? await intTask.value

            guard case .interrupted = intResult.status else {
                printErr("❌ Expected interrupted status, got: \(intResult.status)")
                return false
            }
            let intDisk = await store.loadLatestCheckpoint(runId: intRunId)
            guard case .interrupted = intDisk?.status else {
                printErr("❌ Interrupted checkpoint missing on disk!")
                return false
            }
            printOut("   -> Run interrupted cleanly mid-task, checkpoint survived with status: \(intDisk?.status.badge ?? "")")

            try? FileManager.default.removeItem(at: tempDir)
            printOut("✅ Pause/resume/interrupt verified live.")
            return true
        } catch {
            printErr("❌ Pause/resume/interrupt failed: \(error)")
            return false
        }
    }

    /// Verification Piece 3: Retry with backoff
    private static func verifyRetryWithBackoff() async -> Bool {
        printOut("--- [3/5] Verifying Retry-with-Backoff ---")
        let runId = UUID()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apex_lr_retry_\(runId.uuidString)")
        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        // Step that fails on attempts 1 and 2, then succeeds on attempt 3
        let retryStep = LongRunStepSpec(
            id: "retry-step-1",
            title: "Flaky network simulation step",
            kind: .deterministicFailThenSucceed,
            inputPayload: [
                "failAttempts": "2",
                "successOutput": "Payload acquired after 2 retries"
            ]
        )

        let retryPolicy = LongRunRetryPolicy(
            maxRetries: 3,
            initialBackoffSeconds: 0.1,
            backoffMultiplier: 2.0,
            maxBackoffSeconds: 1.0
        )

        let spec = LongRunSpec(
            id: runId,
            name: "Retry-Backoff Run",
            steps: [retryStep],
            retryPolicy: retryPolicy
        )

        do {
            let start = Date()
            let finalCkpt = try await coordinator.start(spec: spec)
            let elapsed = Date().timeIntervalSince(start)

            guard finalCkpt.status == .completed else {
                printErr("❌ Expected completed status, got: \(finalCkpt.status)")
                return false
            }
            guard let rec = finalCkpt.stepRecords.first(where: { $0.stepId == "retry-step-1" }) else {
                printErr("❌ Missing step record for retry-step-1")
                return false
            }
            guard rec.attempts == 3 else {
                printErr("❌ Expected exactly 3 attempts, got: \(rec.attempts)")
                return false
            }
            guard rec.retryDelays.count == 2 else {
                printErr("❌ Expected 2 backoff delays recorded, got: \(rec.retryDelays.count)")
                return false
            }
            printOut("   -> Attempts executed: \(rec.attempts), Backoff delays recorded: \(rec.retryDelays.map { String(format: "%.2fs", $0) }.joined(separator: ", "))")
            printOut("   -> Total elapsed time: \(String(format: "%.2f", elapsed))s, Output: '\(rec.output ?? "")'")

            try? FileManager.default.removeItem(at: tempDir)
            printOut("✅ Retry-with-backoff verified live (flaky step retried twice with backoff and completed).")
            return true
        } catch {
            printErr("❌ Retry-with-backoff failed: \(error)")
            return false
        }
    }

    /// Verification Piece 4: Run budgets (time, tokens, steps)
    private static func verifyRunBudgets() async -> Bool {
        printOut("--- [4/5] Verifying Run Budgets (Time, Tokens, Steps) ---")

        // 4.1 Time budget
        let timeRunId = UUID()
        let timeStore = LongRunCheckpointStore(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("time_budget_\(timeRunId.uuidString)"))
        let timeCoord = LongRunCoordinator(store: timeStore)
        let timeSpec = LongRunSpec(
            id: timeRunId,
            name: "Time Budget Run",
            steps: [
                LongRunStepSpec(id: "t1", title: "Sleep", kind: .sleepDelay, inputPayload: ["seconds": "0.8"]),
                LongRunStepSpec(id: "t2", title: "Unreachable", kind: .shellCommand, inputPayload: ["command": "echo 'not reached'"])
            ],
            budgetPolicy: LongRunBudgetPolicy(maxWallClockSeconds: 0.5)
        )
        do {
            let res = try await timeCoord.start(spec: timeSpec)
            guard case .budgetExceeded(let type, _, _) = res.status, type == .time else {
                printErr("❌ Expected time budgetExceeded, got: \(res.status)")
                return false
            }
            printOut("   -> [4.1] Time budget enforced: stopped run when elapsed time >= 0.5s (\(res.status.badge))")
        } catch {
            printErr("❌ Time budget check threw: \(error)")
            return false
        }

        // 4.2 Token budget
        let tokenRunId = UUID()
        let tokenStore = LongRunCheckpointStore(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("token_budget_\(tokenRunId.uuidString)"))
        let tokenCoord = LongRunCoordinator(store: tokenStore)
        let tokenSpec = LongRunSpec(
            id: tokenRunId,
            name: "Token Budget Run",
            steps: [
                LongRunStepSpec(id: "tok1", title: "Token Generation", kind: .tokenProcessing, inputPayload: ["text": "ApexAgent resilient long run multi-token prompt string verification payload", "multiplier": "5"]),
                LongRunStepSpec(id: "tok2", title: "Token Unreachable", kind: .shellCommand, inputPayload: ["command": "echo 'unreached'"])
            ],
            budgetPolicy: LongRunBudgetPolicy(maxTokens: 20)
        )
        do {
            let res = try await tokenCoord.start(spec: tokenSpec)
            guard case .budgetExceeded(let type, _, _) = res.status, type == .tokens else {
                printErr("❌ Expected token budgetExceeded, got: \(res.status)")
                return false
            }
            printOut("   -> [4.2] Token budget enforced: stopped run when tokens >= 20 (\(res.status.badge))")
        } catch {
            printErr("❌ Token budget check threw: \(error)")
            return false
        }

        // 4.3 Step budget
        let stepRunId = UUID()
        let stepStore = LongRunCheckpointStore(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("step_budget_\(stepRunId.uuidString)"))
        let stepCoord = LongRunCoordinator(store: stepStore)
        let stepSpec = LongRunSpec(
            id: stepRunId,
            name: "Step Budget Run",
            steps: [
                LongRunStepSpec(id: "step1", title: "Step 1", kind: .shellCommand, inputPayload: ["command": "echo 'step1'"]),
                LongRunStepSpec(id: "step2", title: "Step 2", kind: .shellCommand, inputPayload: ["command": "echo 'step2'"]),
                LongRunStepSpec(id: "step3", title: "Step 3", kind: .shellCommand, inputPayload: ["command": "echo 'step3'"])
            ],
            budgetPolicy: LongRunBudgetPolicy(maxSteps: 2)
        )
        do {
            let res = try await stepCoord.start(spec: stepSpec)
            guard case .budgetExceeded(let type, _, _) = res.status, type == .steps else {
                printErr("❌ Expected step budgetExceeded, got: \(res.status)")
                return false
            }
            printOut("   -> [4.3] Step budget enforced: stopped run when steps executed >= 2 (\(res.status.badge))")
        } catch {
            printErr("❌ Step budget check threw: \(error)")
            return false
        }

        printOut("✅ Run budgets verified live: all 3 budget dimensions (time, tokens, steps) actively halt execution.")
        return true
    }

    /// Verification Piece 5: Continue after crash or machine sleep
    private static func verifyCrashRecovery() async -> Bool {
        printOut("--- [5/5] Verifying Continue-Where-It-Left-Off After Crash/Sleep ---")
        let runId = UUID()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apex_lr_crash_\(runId.uuidString)")
        let store = LongRunCheckpointStore(baseDirectory: tempDir)

        let step1 = LongRunStepSpec(id: "c1", title: "Already finished step", kind: .shellCommand, inputPayload: ["command": "echo 'c1'"])
        let step2 = LongRunStepSpec(id: "c2", title: "Pending step 2", kind: .shellCommand, inputPayload: ["command": "echo 'c2'"])
        let step3 = LongRunStepSpec(id: "c3", title: "Pending step 3", kind: .shellCommand, inputPayload: ["command": "echo 'c3'"])
        let spec = LongRunSpec(id: runId, name: "Crash Recovery Simulation Run", steps: [step1, step2, step3])

        // 1. Durably write checkpoint simulating a previous process that died while running
        let deadPid: Int32 = 99999999 // Non-existent process ID
        let simulatedCrashedCheckpoint = LongRunCheckpoint(
            runId: runId,
            spec: spec,
            sequenceNumber: 2,
            status: .running,
            currentStepIndex: 1,
            completedStepIds: ["c1"],
            stepRecords: [
                LongRunStepRecord(stepId: "c1", title: "Already finished step", status: .completed, attempts: 1, output: "c1", tokensUsed: 10, startedAt: Date(), finishedAt: Date()),
                LongRunStepRecord(stepId: "c2", title: "Pending step 2", status: .pending),
                LongRunStepRecord(stepId: "c3", title: "Pending step 3", status: .pending)
            ],
            sharedState: ["pre_crash_key": "survived_intact"],
            budgetUsage: LongRunBudgetUsage(elapsedWallClockSeconds: 1.2, tokensConsumed: 10, stepsExecuted: 1),
            savedAt: Date().addingTimeInterval(-60),
            processId: deadPid,
            logs: [LongRunLogEntry(message: "Simulated pre-crash log entry", level: "INFO")]
        )

        do {
            try await store.save(checkpoint: simulatedCrashedCheckpoint)
            printOut("   -> Persisted in-progress checkpoint written by dead process PID \(deadPid)")

            // 2. Run recovery sweep (simulating new application launch)
            let coordinator = LongRunCoordinator(store: store)
            let recoveredList = await coordinator.recoverInterruptedRuns()
            guard let recovered = recoveredList.first(where: { $0.runId == runId }) else {
                printErr("❌ Recovery sweep failed to detect crashed run with dead PID!")
                return false
            }
            guard case .interrupted = recovered.status else {
                printErr("❌ Expected recovered run to be in .interrupted state, got: \(recovered.status)")
                return false
            }
            printOut("   -> Recovery sweep detected dead process and converted run to: \(recovered.status.badge)")

            // 3. Resume where it left off
            let resumed = try await coordinator.resume(runId: runId)
            guard resumed.status == .completed else {
                printErr("❌ Resumed run failed to complete, got: \(resumed.status)")
                return false
            }
            guard resumed.completedStepIds.sorted() == ["c1", "c2", "c3"] else {
                printErr("❌ Expected steps [c1, c2, c3] completed, got: \(resumed.completedStepIds)")
                return false
            }
            guard resumed.sharedState["pre_crash_key"] == "survived_intact" else {
                printErr("❌ Shared state before crash was lost!")
                return false
            }
            // Verify step 1 was not re-executed
            let c1Record = resumed.stepRecords.first(where: { $0.stepId == "c1" })
            guard c1Record?.attempts == 1 else {
                printErr("❌ Step c1 was re-executed during resume (attempts: \(c1Record?.attempts ?? 0))")
                return false
            }

            try? FileManager.default.removeItem(at: tempDir)
            printOut("✅ Continue after crash/sleep verified live: unclosed run recovered and continued exactly from step 2 to full completion.")
            return true
        } catch {
            printErr("❌ Crash recovery verification failed: \(error)")
            return false
        }
    }
}
