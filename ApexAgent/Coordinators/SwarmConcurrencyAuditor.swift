import Foundation

// MARK: - Swarm Worker Priority & Concurrency Throttling Gate (Batch 97)

/// Priority levels for multi-agent swarm task execution.
public enum SwarmPriority: Int, Sendable, Codable, Comparable, CaseIterable {
    case background = 0
    case normal = 1
    case high = 2
    case critical = 3

    public static func < (lhs: SwarmPriority, rhs: SwarmPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Description of an individual worker task queued for swarm dispatch.
public struct SwarmTaskDescriptor: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let botName: String
    public let prompt: String
    public let priority: SwarmPriority
    public let timeoutSeconds: TimeInterval
    public let estimatedMemoryMB: Int

    public init(
        id: UUID = UUID(),
        botName: String,
        prompt: String,
        priority: SwarmPriority = .normal,
        timeoutSeconds: TimeInterval = 60.0,
        estimatedMemoryMB: Int = 256
    ) {
        self.id = id
        self.botName = botName
        self.prompt = prompt
        self.priority = priority
        self.timeoutSeconds = timeoutSeconds
        self.estimatedMemoryMB = estimatedMemoryMB
    }
}

/// Configuration governing parallel worker limits and memory pressure limits.
public struct SwarmConcurrencyConfig: Sendable, Codable, Equatable {
    public var maxConcurrentWorkers: Int
    public var maxTotalWorkers: Int
    public var maxMemoryBudgetMB: Int
    public var maxSwarmTimeoutSeconds: TimeInterval

    public init(
        maxConcurrentWorkers: Int = 4,
        maxTotalWorkers: Int = 12,
        maxMemoryBudgetMB: Int = 4096,
        maxSwarmTimeoutSeconds: TimeInterval = 300.0
    ) {
        self.maxConcurrentWorkers = maxConcurrentWorkers
        self.maxTotalWorkers = maxTotalWorkers
        self.maxMemoryBudgetMB = maxMemoryBudgetMB
        self.maxSwarmTimeoutSeconds = maxSwarmTimeoutSeconds
    }
}

/// Violation detected during swarm scheduling and concurrency audit.
public struct SwarmSchedulingViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Discrete concurrent execution stage scheduled by the concurrency auditor.
public struct SwarmSchedulingBatch: Sendable, Codable, Equatable {
    public let batchIndex: Int
    public let tasks: [SwarmTaskDescriptor]
    public let totalEstimatedMemoryMB: Int
    public let estimatedDurationSeconds: TimeInterval

    public init(
        batchIndex: Int,
        tasks: [SwarmTaskDescriptor],
        totalEstimatedMemoryMB: Int,
        estimatedDurationSeconds: TimeInterval
    ) {
        self.batchIndex = batchIndex
        self.tasks = tasks
        self.totalEstimatedMemoryMB = totalEstimatedMemoryMB
        self.estimatedDurationSeconds = estimatedDurationSeconds
    }
}

/// Final audit result and multi-stage execution plan for a swarm dispatch.
public struct SwarmSchedulingPlan: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let violations: [SwarmSchedulingViolation]
    public let scheduledBatches: [SwarmSchedulingBatch]
    public let totalBatches: Int
    public let totalEstimatedTimeSeconds: TimeInterval

    public init(
        passed: Bool,
        score: Double,
        violations: [SwarmSchedulingViolation],
        scheduledBatches: [SwarmSchedulingBatch],
        totalBatches: Int,
        totalEstimatedTimeSeconds: TimeInterval
    ) {
        self.passed = passed
        self.score = score
        self.violations = violations
        self.scheduledBatches = scheduledBatches
        self.totalBatches = totalBatches
        self.totalEstimatedTimeSeconds = totalEstimatedTimeSeconds
    }
}

/// Concurrency orchestrator, rate limiter, and priority scheduler for multi-bot swarms.
public enum SwarmConcurrencyAuditor {

    /// Audits task parameters, enforces throttling limits, resolves bot collisions, and produces an optimal execution plan.
    public static func auditAndPlanSwarm(
        tasks: [SwarmTaskDescriptor],
        config: SwarmConcurrencyConfig
    ) -> SwarmSchedulingPlan {
        var violations: [SwarmSchedulingViolation] = []

        // 1. Minimum and Maximum worker count validations
        if tasks.isEmpty {
            violations.append(SwarmSchedulingViolation(
                code: "EMPTY_SWARM_TASKS",
                message: "Swarm dispatch must contain at least one task."
            ))
            return SwarmSchedulingPlan(
                passed: false,
                score: 0.0,
                violations: violations,
                scheduledBatches: [],
                totalBatches: 0,
                totalEstimatedTimeSeconds: 0.0
            )
        }

        if tasks.count > config.maxTotalWorkers {
            violations.append(SwarmSchedulingViolation(
                code: "EXCESSIVE_TOTAL_WORKERS",
                message: "Total task count (\(tasks.count)) exceeds maximum allowed (\(config.maxTotalWorkers))."
            ))
        }

        let clampedConcurrency = max(1, min(16, config.maxConcurrentWorkers))
        if config.maxConcurrentWorkers < 1 || config.maxConcurrentWorkers > 16 {
            violations.append(SwarmSchedulingViolation(
                code: "INVALID_CONCURRENCY_LIMIT",
                message: "maxConcurrentWorkers must be between 1 and 16 (provided: \(config.maxConcurrentWorkers)).",
                isFatal: false
            ))
        }

        // 2. Validate individual task parameters
        for task in tasks {
            let cleanBot = task.botName.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanBot.isEmpty {
                violations.append(SwarmSchedulingViolation(
                    code: "EMPTY_BOT_NAME",
                    message: "Task has empty bot name."
                ))
            }
            let cleanPrompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanPrompt.isEmpty {
                violations.append(SwarmSchedulingViolation(
                    code: "EMPTY_TASK_PROMPT",
                    message: "Task for bot '\(task.botName)' has empty prompt."
                ))
            }
            if task.timeoutSeconds > config.maxSwarmTimeoutSeconds {
                violations.append(SwarmSchedulingViolation(
                    code: "TASK_TIMEOUT_EXCEEDS_GLOBAL",
                    message: "Task for bot '\(task.botName)' timeout (\(task.timeoutSeconds)s) exceeds swarm ceiling (\(config.maxSwarmTimeoutSeconds)s)."
                ))
            }
        }

        // 3. Priority sort (Critical first, descending to Background)
        let sortedTasks = tasks.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            return lhs.estimatedMemoryMB < rhs.estimatedMemoryMB
        }

        // 4. Batch scheduling algorithm preventing same-bot parallel collision & respecting concurrency/memory ceilings
        var batches: [SwarmSchedulingBatch] = []
        var remainingTasks = sortedTasks
        var batchIndex = 1

        while !remainingTasks.isEmpty {
            var currentBatchTasks: [SwarmTaskDescriptor] = []
            var currentBatchBots = Set<String>()
            var currentBatchMemory = 0
            var unassignedRemaining: [SwarmTaskDescriptor] = []

            for task in remainingTasks {
                let normalizedBot = task.botName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let wouldExceedWorkers = currentBatchTasks.count >= clampedConcurrency
                let wouldCollideBot = currentBatchBots.contains(normalizedBot)
                let wouldExceedMemory = (currentBatchMemory + task.estimatedMemoryMB) > config.maxMemoryBudgetMB && !currentBatchTasks.isEmpty

                if !wouldExceedWorkers && !wouldCollideBot && !wouldExceedMemory {
                    currentBatchTasks.append(task)
                    currentBatchBots.insert(normalizedBot)
                    currentBatchMemory += task.estimatedMemoryMB
                } else {
                    unassignedRemaining.append(task)
                }
            }

            // Fallback if a single task is larger than total memory budget: allow it to run alone
            if currentBatchTasks.isEmpty && !remainingTasks.isEmpty {
                let oversizedTask = remainingTasks.removeFirst()
                currentBatchTasks.append(oversizedTask)
                currentBatchMemory = oversizedTask.estimatedMemoryMB
                unassignedRemaining = remainingTasks
            }

            let maxDurationInBatch = currentBatchTasks.map(\.timeoutSeconds).max() ?? 0.0
            batches.append(SwarmSchedulingBatch(
                batchIndex: batchIndex,
                tasks: currentBatchTasks,
                totalEstimatedMemoryMB: currentBatchMemory,
                estimatedDurationSeconds: maxDurationInBatch
            ))

            batchIndex += 1
            remainingTasks = unassignedRemaining
        }

        let totalTime = batches.reduce(0.0) { $0 + $1.estimatedDurationSeconds }
        if totalTime > config.maxSwarmTimeoutSeconds {
            violations.append(SwarmSchedulingViolation(
                code: "TOTAL_ESTIMATED_TIME_EXCEEDS_BUDGET",
                message: "Total scheduled duration (\(totalTime)s) exceeds swarm budget (\(config.maxSwarmTimeoutSeconds)s).",
                isFatal: false
            ))
        }

        let fatalViolations = violations.filter(\.isFatal)
        let nonFatalViolations = violations.filter { !$0.isFatal }
        let passed = fatalViolations.isEmpty

        var score = 100.0 - Double(fatalViolations.count) * 25.0 - Double(nonFatalViolations.count) * 10.0
        score = max(0.0, min(100.0, score))

        return SwarmSchedulingPlan(
            passed: passed,
            score: score,
            violations: violations,
            scheduledBatches: batches,
            totalBatches: batches.count,
            totalEstimatedTimeSeconds: totalTime
        )
    }
}
