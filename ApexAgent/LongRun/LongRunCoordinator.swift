import Foundation
import Darwin

// MARK: - Long Run Coordinator (Issue #77)

public enum LongRunCoordinatorError: Error, LocalizedError, Sendable, Equatable {
    case runNotFound(UUID)
    case runNotResumable(UUID, currentStatusBadge: String)
    case runAlreadyActive(UUID)
    case checkpointSaveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runNotFound(let id):
            return "Long run '\(id.uuidString)' not found in checkpoint store."
        case .runNotResumable(let id, let badge):
            return "Long run '\(id.uuidString)' is not in a resumable state (\(badge))."
        case .runAlreadyActive(let id):
            return "Long run '\(id.uuidString)' is already actively executing."
        case .checkpointSaveFailed(let msg):
            return "Failed to save checkpoint: \(msg)"
        }
    }
}

/// Actor orchestrating resumable long runs with durable checkpointing, pause/resume,
/// retries with backoff, and budget enforcement.
public actor LongRunCoordinator {
    public static let shared = LongRunCoordinator()

    private let store: LongRunCheckpointStore
    private let executor: LongRunStepExecutor

    private var activeRuns: [UUID: Task<LongRunCheckpoint, Error>] = [:]
    private var pauseFlags: [UUID: Bool] = [:]
    private var interruptFlags: [UUID: String] = [:]

    public init(
        store: LongRunCheckpointStore = .shared,
        executor: LongRunStepExecutor = .shared
    ) {
        self.store = store
        self.executor = executor
    }

    /// Submits and starts a new long run.
    @discardableResult
    public func start(spec: LongRunSpec) async throws -> LongRunCheckpoint {
        let runId = spec.id
        guard activeRuns[runId] == nil else {
            throw LongRunCoordinatorError.runAlreadyActive(runId)
        }

        var initialCheckpoint = LongRunCheckpoint(
            runId: runId,
            spec: spec,
            sequenceNumber: 0,
            status: .running,
            currentStepIndex: 0,
            completedStepIds: [],
            stepRecords: spec.steps.map { LongRunStepRecord(stepId: $0.id, title: $0.title) },
            sharedState: [:],
            budgetUsage: LongRunBudgetUsage(),
            savedAt: Date(),
            processId: ProcessInfo.processInfo.processIdentifier,
            logs: [LongRunLogEntry(message: "Started long run '\(spec.name)'", level: "INFO")]
        )

        try await store.save(checkpoint: initialCheckpoint)

        let task = Task<LongRunCheckpoint, Error> {
            try await self.executeRunLoop(checkpoint: &initialCheckpoint)
        }

        activeRuns[runId] = task
        return try await task.value
    }

    /// Pauses an active run cleanly, ensuring durable checkpoint survives.
    @discardableResult
    public func pause(runId: UUID) async throws -> LongRunCheckpoint {
        pauseFlags[runId] = true
        if let task = activeRuns[runId] {
            return try await task.value
        }
        guard var ckpt = await store.loadLatestCheckpoint(runId: runId) else {
            throw LongRunCoordinatorError.runNotFound(runId)
        }
        if ckpt.status == .running {
            ckpt.status = .paused
            ckpt.sequenceNumber += 1
            ckpt.savedAt = Date()
            ckpt.logs.append(LongRunLogEntry(message: "Run marked paused externally", level: "INFO"))
            try await store.save(checkpoint: ckpt)
        }
        return ckpt
    }

    /// Cleanly interrupts an active run, preserving durable checkpoint.
    @discardableResult
    public func interrupt(runId: UUID, reason: String = "Interrupted by user or signal") async throws -> LongRunCheckpoint {
        interruptFlags[runId] = reason
        if let task = activeRuns[runId] {
            return try await task.value
        }
        guard var ckpt = await store.loadLatestCheckpoint(runId: runId) else {
            throw LongRunCoordinatorError.runNotFound(runId)
        }
        if !ckpt.status.isTerminal {
            ckpt.status = .interrupted(reason: reason)
            ckpt.sequenceNumber += 1
            ckpt.savedAt = Date()
            ckpt.logs.append(LongRunLogEntry(message: "Run interrupted: \(reason)", level: "WARN"))
            try await store.save(checkpoint: ckpt)
        }
        return ckpt
    }

    /// Resumes an existing paused or interrupted run from its durable checkpoint.
    @discardableResult
    public func resume(runId: UUID) async throws -> LongRunCheckpoint {
        guard activeRuns[runId] == nil else {
            throw LongRunCoordinatorError.runAlreadyActive(runId)
        }
        guard var ckpt = await store.loadLatestCheckpoint(runId: runId) else {
            throw LongRunCoordinatorError.runNotFound(runId)
        }
        guard ckpt.status.isResumable else {
            throw LongRunCoordinatorError.runNotResumable(runId, currentStatusBadge: ckpt.status.badge)
        }

        pauseFlags.removeValue(forKey: runId)
        interruptFlags.removeValue(forKey: runId)

        ckpt.status = .running
        ckpt.sequenceNumber += 1
        ckpt.savedAt = Date()
        ckpt.processId = ProcessInfo.processInfo.processIdentifier
        ckpt.logs.append(LongRunLogEntry(message: "Resuming run from step \(ckpt.currentStepIndex) (\(ckpt.completedStepIds.count) previously completed)", level: "INFO"))
        try await store.save(checkpoint: ckpt)

        let task = Task<LongRunCheckpoint, Error> {
            try await self.executeRunLoop(checkpoint: &ckpt)
        }

        activeRuns[runId] = task
        return try await task.value
    }

    /// Recovers all interrupted or crashed runs from previous processes.
    public func recoverInterruptedRuns() async -> [LongRunCheckpoint] {
        let interrupted = await store.findInterruptedRuns()
        var recovered: [LongRunCheckpoint] = []

        for var ckpt in interrupted {
            ckpt.status = .interrupted(reason: "Process \(ckpt.processId) terminated unexpectedly (crash or sleep recovery)")
            ckpt.sequenceNumber += 1
            ckpt.savedAt = Date()
            ckpt.logs.append(LongRunLogEntry(message: "Recovered unclosed run from crash/sleep", level: "WARN"))
            try? await store.save(checkpoint: ckpt)
            recovered.append(ckpt)
        }

        return recovered
    }

    /// Internal execution loop iterating through steps, checkpointing durably,
    /// enforcing budgets, and executing retries with backoff.
    private func executeRunLoop(checkpoint: inout LongRunCheckpoint) async throws -> LongRunCheckpoint {
        let runId = checkpoint.runId
        let spec = checkpoint.spec
        let budgetPolicy = spec.budgetPolicy
        let retryPolicy = spec.retryPolicy

        defer {
            activeRuns.removeValue(forKey: runId)
            pauseFlags.removeValue(forKey: runId)
            interruptFlags.removeValue(forKey: runId)
        }

        let loopStartTime = Date()
        // Track carried-over base at loop entry so elapsed reflects total wall-clock
        // time (including any pre-loop accumulated value) without re-adding the full
        // interval on every pre-step check. Previously this used `+=`, which caused
        // each of N checks to add the entire time-since-loop-start again, inflating
        // elapsed (e.g. ~45s reported vs ~9s real for 10 one-second steps) and firing
        // the budget early. Now each check SETS elapsed = base + timeSince(loopStart),
        // so stored elapsed grows linearly with real wall-clock time.
        let baseElapsed = checkpoint.budgetUsage.elapsedWallClockSeconds

        while checkpoint.currentStepIndex < spec.steps.count {
            // 1. Check for external interrupt request
            if let reason = interruptFlags[runId] {
                checkpoint.status = .interrupted(reason: reason)
                checkpoint.sequenceNumber += 1
                checkpoint.savedAt = Date()
                checkpoint.logs.append(LongRunLogEntry(message: "Execution halted by interrupt: \(reason)", level: "WARN"))
                try await store.save(checkpoint: checkpoint)
                return checkpoint
            }

            // 2. Check for external pause request
            if pauseFlags[runId] == true {
                checkpoint.status = .paused
                checkpoint.sequenceNumber += 1
                checkpoint.savedAt = Date()
                checkpoint.logs.append(LongRunLogEntry(message: "Execution paused cleanly before step \(checkpoint.currentStepIndex)", level: "INFO"))
                try await store.save(checkpoint: checkpoint)
                return checkpoint
            }

            // 3. Pre-step budget check
            // SET elapsed = carried-over base + time since loop start (rather than
            // accumulating += timeIntervalSince on every check, which double-counted
            // the full interval N times and inflated elapsed / fired budget early).
            checkpoint.budgetUsage.elapsedWallClockSeconds = baseElapsed + Date().timeIntervalSince(loopStartTime)
            if let exceeded = checkpoint.budgetUsage.evaluateExceeded(policy: budgetPolicy) {
                checkpoint.status = .budgetExceeded(type: exceeded.type, limit: exceeded.limit, actual: exceeded.actual)
                checkpoint.sequenceNumber += 1
                checkpoint.savedAt = Date()
                checkpoint.logs.append(LongRunLogEntry(message: "Budget exceeded (\(exceeded.type.rawValue): \(exceeded.actual) >= \(exceeded.limit))", level: "WARN"))
                try await store.save(checkpoint: checkpoint)
                return checkpoint
            }

            let step = spec.steps[checkpoint.currentStepIndex]

            // If step already completed (e.g. from restored checkpoint), advance
            if checkpoint.completedStepIds.contains(step.id) {
                checkpoint.currentStepIndex += 1
                continue
            }

            // Prepare or retrieve step record
            var stepRecord: LongRunStepRecord
            if let existingIdx = checkpoint.stepRecords.firstIndex(where: { $0.stepId == step.id }) {
                stepRecord = checkpoint.stepRecords[existingIdx]
            } else {
                stepRecord = LongRunStepRecord(stepId: step.id, title: step.title)
                checkpoint.stepRecords.append(stepRecord)
            }

            stepRecord.status = .running
            stepRecord.startedAt = stepRecord.startedAt ?? Date()
            updateStepRecord(stepRecord, in: &checkpoint)
            try await store.save(checkpoint: checkpoint)

            // Retry loop
            var stepSuccess = false
            while !stepSuccess {
                stepRecord.attempts += 1
                // stepsExecuted counts each attempt (not each distinct step): the step
                // budget limits total step attempts including retries, so incrementing
                // per attempt is intended. See LongRunBudgetUsage.stepsExecuted.
                checkpoint.budgetUsage.stepsExecuted += 1

                // Check step budget count
                if let maxSteps = budgetPolicy.maxSteps, checkpoint.budgetUsage.stepsExecuted > maxSteps {
                    checkpoint.status = .budgetExceeded(type: .steps, limit: Double(maxSteps), actual: Double(checkpoint.budgetUsage.stepsExecuted))
                    checkpoint.sequenceNumber += 1
                    checkpoint.savedAt = Date()
                    try await store.save(checkpoint: checkpoint)
                    return checkpoint
                }

                do {
                    let result = try await executor.execute(
                        step: step,
                        currentAttempt: stepRecord.attempts,
                        sharedState: checkpoint.sharedState
                    )

                    // Step succeeded
                    stepSuccess = true
                    stepRecord.status = .completed
                    stepRecord.output = result.output
                    stepRecord.error = nil
                    stepRecord.tokensUsed += result.tokensUsed
                    stepRecord.finishedAt = Date()

                    checkpoint.budgetUsage.tokensConsumed += result.tokensUsed
                    checkpoint.completedStepIds.append(step.id)
                    checkpoint.currentStepIndex += 1
                    checkpoint.sharedState.merge(result.updatedSharedState) { _, new in new }

                    updateStepRecord(stepRecord, in: &checkpoint)

                    // Check token & time budgets post-step
                    if let exceeded = checkpoint.budgetUsage.evaluateExceeded(policy: budgetPolicy) {
                        checkpoint.status = .budgetExceeded(type: exceeded.type, limit: exceeded.limit, actual: exceeded.actual)
                        checkpoint.sequenceNumber += 1
                        checkpoint.savedAt = Date()
                        checkpoint.logs.append(LongRunLogEntry(stepId: step.id, message: "Budget exceeded after step (\(exceeded.type.rawValue))", level: "WARN"))
                        try await store.save(checkpoint: checkpoint)
                        return checkpoint
                    }

                    // Save checkpoint after successful step
                    checkpoint.sequenceNumber += 1
                    checkpoint.savedAt = Date()
                    checkpoint.logs.append(LongRunLogEntry(stepId: step.id, message: "Completed step '\(step.title)'", level: "INFO"))
                    try await store.save(checkpoint: checkpoint)

                } catch {
                    stepRecord.error = error.localizedDescription

                    if stepRecord.attempts <= retryPolicy.maxRetries {
                        let delay = retryPolicy.backoffDelay(forAttempt: stepRecord.attempts)
                        stepRecord.status = .retrying
                        stepRecord.retryDelays.append(delay)
                        updateStepRecord(stepRecord, in: &checkpoint)

                        checkpoint.sequenceNumber += 1
                        checkpoint.savedAt = Date()
                        checkpoint.logs.append(LongRunLogEntry(
                            stepId: step.id,
                            message: "Step failed attempt \(stepRecord.attempts) (\(error.localizedDescription)). Retrying in \(String(format: "%.2f", delay))s...",
                            level: "WARN"
                        ))
                        try await store.save(checkpoint: checkpoint)

                        // Cooperative sleep with interrupt/pause checking
                        let sleepMs = UInt64(delay * 1_000_000_000)
                        let checkIntervalMs: UInt64 = 50_000_000 // 50ms chunks
                        var elapsedMs: UInt64 = 0
                        while elapsedMs < sleepMs {
                            if interruptFlags[runId] != nil || pauseFlags[runId] == true {
                                break
                            }
                            let chunk = min(checkIntervalMs, sleepMs - elapsedMs)
                            try await Task.sleep(nanoseconds: chunk)
                            elapsedMs += chunk
                        }

                        // Check if paused or interrupted during backoff sleep
                        if let reason = interruptFlags[runId] {
                            checkpoint.status = .interrupted(reason: reason)
                            checkpoint.sequenceNumber += 1
                            checkpoint.savedAt = Date()
                            try await store.save(checkpoint: checkpoint)
                            return checkpoint
                        }
                        if pauseFlags[runId] == true {
                            checkpoint.status = .paused
                            checkpoint.sequenceNumber += 1
                            checkpoint.savedAt = Date()
                            try await store.save(checkpoint: checkpoint)
                            return checkpoint
                        }

                    } else {
                        // Retries exhausted
                        stepRecord.status = .failed
                        stepRecord.finishedAt = Date()
                        updateStepRecord(stepRecord, in: &checkpoint)

                        checkpoint.status = .failed(reason: "Step '\(step.id)' failed after \(stepRecord.attempts) attempts: \(error.localizedDescription)")
                        checkpoint.sequenceNumber += 1
                        checkpoint.savedAt = Date()
                        checkpoint.logs.append(LongRunLogEntry(stepId: step.id, message: "Step failed fatally: \(error.localizedDescription)", level: "ERROR"))
                        try await store.save(checkpoint: checkpoint)
                        return checkpoint
                    }
                }
            }

            // Post-step check for pause or interrupt
            if let reason = interruptFlags[runId] {
                checkpoint.status = .interrupted(reason: reason)
                checkpoint.sequenceNumber += 1
                checkpoint.savedAt = Date()
                try await store.save(checkpoint: checkpoint)
                return checkpoint
            }
            if pauseFlags[runId] == true {
                checkpoint.status = .paused
                checkpoint.sequenceNumber += 1
                checkpoint.savedAt = Date()
                try await store.save(checkpoint: checkpoint)
                return checkpoint
            }
        }

        // All steps completed successfully
        checkpoint.status = .completed
        checkpoint.sequenceNumber += 1
        checkpoint.savedAt = Date()
        checkpoint.logs.append(LongRunLogEntry(message: "Run completed successfully", level: "INFO"))
        try await store.save(checkpoint: checkpoint)
        return checkpoint
    }

    private func updateStepRecord(_ record: LongRunStepRecord, in checkpoint: inout LongRunCheckpoint) {
        if let idx = checkpoint.stepRecords.firstIndex(where: { $0.stepId == record.stepId }) {
            checkpoint.stepRecords[idx] = record
        } else {
            checkpoint.stepRecords.append(record)
        }
    }
}
