import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Resumable Long Runs Tests (Issue #77)")
struct LongRunTests {

    private func createTempDirectory(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // MARK: - 1. Checkpointed State Tests

    @Test("Checkpointed State: durable persistence, sequence numbering, and on-disk snapshotting")
    func testCheckpointedStateDurablePersistence() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-checkpoint-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let step1 = LongRunStepSpec(
            id: "step-1",
            title: "Echo step 1",
            kind: .shellCommand,
            inputPayload: ["command": "echo 'ApexAgent checkpoint test 1'"]
        )
        let step2 = LongRunStepSpec(
            id: "step-2",
            title: "Echo step 2",
            kind: .shellCommand,
            inputPayload: ["command": "echo 'ApexAgent checkpoint test 2'"]
        )

        let runId = UUID()
        let spec = LongRunSpec(
            id: runId,
            name: "Durable Checkpoint Test Run",
            steps: [step1, step2]
        )

        let finalCkpt = try await coordinator.start(spec: spec)

        #expect(finalCkpt.status == .completed)
        #expect(finalCkpt.completedStepIds == ["step-1", "step-2"])
        #expect(finalCkpt.sequenceNumber >= 2)

        // Verify latest checkpoint loaded from disk matches
        let diskCkpt = await store.loadLatestCheckpoint(runId: runId)
        #expect(diskCkpt != nil)
        #expect(diskCkpt?.runId == runId)
        #expect(diskCkpt?.status == .completed)
        #expect(diskCkpt?.completedStepIds.count == 2)

        // Verify sequenced historical snapshots exist on disk
        let seq0 = await store.loadCheckpointSequence(runId: runId, sequence: 0)
        let seq1 = await store.loadCheckpointSequence(runId: runId, sequence: 1)
        #expect(seq0 != nil)
        #expect(seq1 != nil)
        #expect(seq0?.status == .running)
    }

    @Test("Checkpointed State: serialization roundtrip and Markdown receipt generation")
    func testCheckpointedStateSerializationAndMarkdownReceipt() throws {
        let runId = UUID()
        let spec = LongRunSpec(
            id: runId,
            name: "Serialization Test Spec",
            descriptionText: "Validates JSON roundtrip",
            steps: [
                LongRunStepSpec(id: "s1", title: "Step One", kind: .shellCommand, inputPayload: ["command": "echo 'hi'"], estimatedTokens: 10),
                LongRunStepSpec(id: "s2", title: "Step Two", kind: .sleepDelay, inputPayload: ["seconds": "0.1"], estimatedTokens: 5)
            ],
            budgetPolicy: LongRunBudgetPolicy(maxWallClockSeconds: 30.0, maxTokens: 500, maxSteps: 10),
            retryPolicy: LongRunRetryPolicy(maxRetries: 3, initialBackoffSeconds: 0.2, backoffMultiplier: 2.0, maxBackoffSeconds: 5.0)
        )

        var checkpoint = LongRunCheckpoint(
            runId: runId,
            spec: spec,
            sequenceNumber: 3,
            status: .running,
            currentStepIndex: 1,
            completedStepIds: ["s1"],
            sharedState: ["foo": "bar"],
            budgetUsage: LongRunBudgetUsage(elapsedWallClockSeconds: 2.5, tokensConsumed: 120, stepsExecuted: 1)
        )

        checkpoint.stepRecords[0].status = .completed
        checkpoint.stepRecords[0].output = "hi"
        checkpoint.stepRecords[0].tokensUsed = 10

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(checkpoint)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LongRunCheckpoint.self, from: data)

        #expect(decoded.runId == runId)
        #expect(decoded.spec.name == "Serialization Test Spec")
        #expect(decoded.sequenceNumber == 3)
        #expect(decoded.status == .running)
        #expect(decoded.completedStepIds == ["s1"])
        #expect(decoded.sharedState["foo"] == "bar")
        #expect(decoded.budgetUsage.tokensConsumed == 120)
        #expect(decoded.stepRecords[0].output == "hi")

        let receipt = decoded.formatMarkdownReceipt()
        #expect(receipt.contains("Long Run Receipt: `Serialization Test Spec`"))
        #expect(receipt.contains("Step One"))
        #expect(receipt.contains("Step ID"))
    }

    // MARK: - 2. Pause / Resume / Interrupt Tests

    @Test("Pause & Resume: pause mid-task, save checkpoint, resume from checkpoint without duplicate work")
    func testPauseAndResumeMidTask() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-pause-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let runId = UUID()
        let step1 = LongRunStepSpec(id: "p1", title: "Fast step 1", kind: .shellCommand, inputPayload: ["command": "echo 'step1'"])
        let step2 = LongRunStepSpec(id: "p2", title: "Delay step 2", kind: .sleepDelay, inputPayload: ["seconds": "0.5"])
        let step3 = LongRunStepSpec(id: "p3", title: "Final step 3", kind: .shellCommand, inputPayload: ["command": "echo 'step3'"])

        let spec = LongRunSpec(id: runId, name: "Pause-Resume Test Run", steps: [step1, step2, step3])

        // Start execution in background task
        let startTask = Task {
            try await coordinator.start(spec: spec)
        }

        // Allow step 1 to complete and step 2 to begin, then pause
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        _ = try await coordinator.pause(runId: runId)

        let pausedCkpt = try await startTask.value
        #expect(pausedCkpt.status == .paused)
        #expect(pausedCkpt.completedStepIds.contains("p1"))
        #expect(!pausedCkpt.completedStepIds.contains("p3"))

        // Check on-disk persistence of paused state
        let diskPaused = await store.loadLatestCheckpoint(runId: runId)
        #expect(diskPaused?.status == .paused)

        // Resume execution
        let resumedCkpt = try await coordinator.resume(runId: runId)
        #expect(resumedCkpt.status == .completed)
        #expect(resumedCkpt.completedStepIds.count == 3)
        #expect(resumedCkpt.completedStepIds == ["p1", "p2", "p3"])

        // Confirm step 1 was executed only once (attempts == 1)
        let p1Rec = resumedCkpt.stepRecords.first(where: { $0.stepId == "p1" })
        #expect(p1Rec?.attempts == 1)
    }

    @Test("Interrupt: stops cleanly mid-task with surviving checkpoint")
    func testInterruptStopsCleanlyWithSurvivingCheckpoint() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-interrupt-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let runId = UUID()
        let step1 = LongRunStepSpec(id: "int1", title: "Delay step", kind: .sleepDelay, inputPayload: ["seconds": "0.8"])
        let step2 = LongRunStepSpec(id: "int2", title: "Unreachable step", kind: .shellCommand, inputPayload: ["command": "echo 'unreachable'"])
        let spec = LongRunSpec(id: runId, name: "Interrupt Test Run", steps: [step1, step2])

        let startTask = Task {
            try await coordinator.start(spec: spec)
        }

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        let intResult = try await coordinator.interrupt(runId: runId, reason: "Manual interruption test")
        _ = try? await startTask.value

        #expect(intResult.status == .interrupted(reason: "Manual interruption test"))

        // Verify checkpoint survives intact on disk
        let diskCkpt = await store.loadLatestCheckpoint(runId: runId)
        #expect(diskCkpt != nil)
        #expect(diskCkpt?.status == .interrupted(reason: "Manual interruption test"))
        #expect(diskCkpt?.isResumable == true)
    }

    // MARK: - 3. Retry-With-Backoff Tests

    @Test("Retry-With-Backoff: step retries with backoff on failure and succeeds")
    func testRetryWithExponentialBackoff() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-retry-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let runId = UUID()
        let flakyStep = LongRunStepSpec(
            id: "flaky-1",
            title: "Simulated flaky step",
            kind: .deterministicFailThenSucceed,
            inputPayload: [
                "failAttempts": "2",
                "successOutput": "Success after 2 retries"
            ]
        )

        let retryPolicy = LongRunRetryPolicy(
            maxRetries: 3,
            initialBackoffSeconds: 0.05,
            backoffMultiplier: 2.0,
            maxBackoffSeconds: 0.5
        )

        let spec = LongRunSpec(
            id: runId,
            name: "Retry Test Run",
            steps: [flakyStep],
            retryPolicy: retryPolicy
        )

        let result = try await coordinator.start(spec: spec)

        #expect(result.status == .completed)
        let rec = result.stepRecords.first(where: { $0.stepId == "flaky-1" })
        #expect(rec != nil)
        #expect(rec?.attempts == 3)
        #expect(rec?.retryDelays.count == 2)
        #expect(rec?.status == .completed)
        #expect(rec?.output == "Success after 2 retries")
    }

    @Test("Retry-With-Backoff: retries exhausted marks step and run failed cleanly")
    func testRetryExhaustionFailsRunCleanly() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-exhaust-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let runId = UUID()
        let failingStep = LongRunStepSpec(
            id: "fail-forever",
            title: "Fails repeatedly",
            kind: .deterministicFailThenSucceed,
            inputPayload: [
                "failAttempts": "5",
                "successOutput": "Will never be reached"
            ]
        )

        let retryPolicy = LongRunRetryPolicy(
            maxRetries: 2,
            initialBackoffSeconds: 0.02,
            backoffMultiplier: 1.5,
            maxBackoffSeconds: 0.1
        )

        let spec = LongRunSpec(
            id: runId,
            name: "Retry Exhaustion Test Run",
            steps: [failingStep],
            retryPolicy: retryPolicy
        )

        let result = try await coordinator.start(spec: spec)

        #expect(result.status.isTerminal)
        guard case .failed = result.status else {
            Issue.record("Expected status to be .failed")
            return
        }

        let rec = result.stepRecords.first(where: { $0.stepId == "fail-forever" })
        #expect(rec?.status == .failed)
        #expect(rec?.attempts == 3) // 1 initial attempt + 2 retries
        #expect(rec?.error != nil)
    }

    // MARK: - 4. Run Budgets Tests

    @Test("Run Budgets: wall-clock time budget stops run when exceeded")
    func testTimeBudgetHaltsRunImmediately() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-time-budget")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let runId = UUID()
        let step1 = LongRunStepSpec(id: "time1", title: "Sleep 0.4s", kind: .sleepDelay, inputPayload: ["seconds": "0.4"])
        let step2 = LongRunStepSpec(id: "time2", title: "Should not run", kind: .shellCommand, inputPayload: ["command": "echo 'not reached'"])

        let spec = LongRunSpec(
            id: runId,
            name: "Time Budget Limit Run",
            steps: [step1, step2],
            budgetPolicy: LongRunBudgetPolicy(maxWallClockSeconds: 0.25)
        )

        let result = try await coordinator.start(spec: spec)

        guard case .budgetExceeded(let type, _, _) = result.status else {
            Issue.record("Expected .budgetExceeded status, got: \(result.status)")
            return
        }
        #expect(type == .time)
        #expect(!result.completedStepIds.contains("time2"))
    }

    @Test("Run Budgets: elapsed equals real wall-clock and budget above runtime does not fire early")
    func testElapsedMatchesWallClockAndHighBudgetDoesNotFireEarly() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-elapsed-budget")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let runId = UUID()
        let steps = (1...6).map { idx in
            LongRunStepSpec(
                id: "elapsed-\(idx)",
                title: "Elapsed step \(idx)",
                kind: .sleepDelay,
                inputPayload: ["seconds": "0.05"]
            )
        }

        // Budget well above real runtime: must not fire early; all steps complete.
        let spec = LongRunSpec(
            id: runId,
            name: "Elapsed Wall-Clock Regression Run",
            steps: steps,
            budgetPolicy: LongRunBudgetPolicy(maxWallClockSeconds: 60.0)
        )

        let wallStart = Date()
        let result = try await coordinator.start(spec: spec)
        let wallElapsed = Date().timeIntervalSince(wallStart)

        // All steps must complete (budget above real runtime must not fire early).
        #expect(result.status == .completed)
        #expect(result.completedStepIds == steps.map { $0.id })

        // Reported elapsed must match real wall-clock within tolerance and must not be
        // inflated by the pre-step accumulation bug (which reported ~quadratic elapsed
        // vs linear wall-clock and fired the budget early).
        let reported = result.budgetUsage.elapsedWallClockSeconds
        #expect(reported >= 0)
        #expect(abs(reported - wallElapsed) < 1.0,
                "reported \(reported)s vs wall-clock \(wallElapsed)s")
    }

    @Test("Run Budgets: token budget stops run when consumed tokens exceed limit")
    func testTokenBudgetHaltsRunImmediately() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-token-budget")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let runId = UUID()
        let step1 = LongRunStepSpec(
            id: "tok1",
            title: "Consume tokens",
            kind: .tokenProcessing,
            inputPayload: ["text": "ApexAgent resilient checkpointing execution token test payload", "multiplier": "5"]
        )
        let step2 = LongRunStepSpec(
            id: "tok2",
            title: "Should not execute",
            kind: .shellCommand,
            inputPayload: ["command": "echo 'never'"]
        )

        let spec = LongRunSpec(
            id: runId,
            name: "Token Budget Limit Run",
            steps: [step1, step2],
            budgetPolicy: LongRunBudgetPolicy(maxTokens: 15)
        )

        let result = try await coordinator.start(spec: spec)

        guard case .budgetExceeded(let type, _, _) = result.status else {
            Issue.record("Expected .budgetExceeded status, got: \(result.status)")
            return
        }
        #expect(type == .tokens)
        #expect(result.completedStepIds == ["tok1"])
        #expect(!result.completedStepIds.contains("tok2"))
    }

    @Test("Run Budgets: step budget stops run when executed steps reach limit")
    func testStepBudgetHaltsRunImmediately() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-step-budget")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LongRunCheckpointStore(baseDirectory: tempDir)
        let coordinator = LongRunCoordinator(store: store)

        let runId = UUID()
        let steps = (1...5).map { idx in
            LongRunStepSpec(id: "step-\(idx)", title: "Step \(idx)", kind: .shellCommand, inputPayload: ["command": "echo '\(idx)'"])
        }

        let spec = LongRunSpec(
            id: runId,
            name: "Step Budget Limit Run",
            steps: steps,
            budgetPolicy: LongRunBudgetPolicy(maxSteps: 2)
        )

        let result = try await coordinator.start(spec: spec)

        guard case .budgetExceeded(let type, let limit, let actual) = result.status else {
            Issue.record("Expected .budgetExceeded status, got: \(result.status)")
            return
        }
        #expect(type == .steps)
        #expect(limit == 2.0)
        #expect(actual >= 2.0)
        #expect(result.completedStepIds.count <= 2)
    }

    // MARK: - 5. Continue After Crash / Sleep Tests

    @Test("Continue After Crash/Sleep: unclosed running checkpoint recovered and resumed from last step")
    func testCrashRecoveryAndContinueWhereItLeftOff() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-crash-recovery")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = LongRunCheckpointStore(baseDirectory: tempDir)

        let runId = UUID()
        let step1 = LongRunStepSpec(id: "c1", title: "Finished before crash", kind: .shellCommand, inputPayload: ["command": "echo 'step1'"])
        let step2 = LongRunStepSpec(id: "c2", title: "Interrupted by crash", kind: .shellCommand, inputPayload: ["command": "echo 'step2'"])
        let step3 = LongRunStepSpec(id: "c3", title: "Remaining step 3", kind: .shellCommand, inputPayload: ["command": "echo 'step3'"])

        let spec = LongRunSpec(id: runId, name: "Crash Simulation Run", steps: [step1, step2, step3])

        // Save a checkpoint simulating a killed process (PID 99999999 does not exist)
        let simulatedCheckpoint = LongRunCheckpoint(
            runId: runId,
            spec: spec,
            sequenceNumber: 2,
            status: .running,
            currentStepIndex: 1,
            completedStepIds: ["c1"],
            stepRecords: [
                LongRunStepRecord(stepId: "c1", title: "Finished before crash", status: .completed, attempts: 1, output: "step1", tokensUsed: 10, startedAt: Date(), finishedAt: Date()),
                LongRunStepRecord(stepId: "c2", title: "Interrupted by crash", status: .pending),
                LongRunStepRecord(stepId: "c3", title: "Remaining step 3", status: .pending)
            ],
            sharedState: ["pre_crash_artifact": "persisted_value"],
            budgetUsage: LongRunBudgetUsage(elapsedWallClockSeconds: 1.0, tokensConsumed: 10, stepsExecuted: 1),
            savedAt: Date().addingTimeInterval(-300),
            processId: 99999999, // Dead PID
            logs: [LongRunLogEntry(message: "Simulated pre-crash run progress", level: "INFO")]
        )

        try await store.save(checkpoint: simulatedCheckpoint)

        let coordinator = LongRunCoordinator(store: store)

        // 1. Recover unclosed runs
        let recoveredRuns = await coordinator.recoverInterruptedRuns()
        #expect(recoveredRuns.contains(where: { $0.runId == runId }))

        let recoveredCkpt = await store.loadLatestCheckpoint(runId: runId)
        #expect(recoveredCkpt?.isResumable == true)
        guard case .interrupted = recoveredCkpt?.status else {
            Issue.record("Expected recovered run status to be .interrupted")
            return
        }

        // 2. Resume where it left off
        let resumedResult = try await coordinator.resume(runId: runId)
        #expect(resumedResult.status == .completed)
        #expect(resumedResult.completedStepIds == ["c1", "c2", "c3"])
        #expect(resumedResult.sharedState["pre_crash_artifact"] == "persisted_value")

        // Step 1 must NOT have been re-executed
        let c1Record = resumedResult.stepRecords.first(where: { $0.stepId == "c1" })
        #expect(c1Record?.attempts == 1)

        // Steps 2 and 3 must have executed and succeeded
        let c2Record = resumedResult.stepRecords.first(where: { $0.stepId == "c2" })
        let c3Record = resumedResult.stepRecords.first(where: { $0.stepId == "c3" })
        #expect(c2Record?.status == .completed)
        #expect(c3Record?.status == .completed)
    }
}
