import Foundation
import SharedKit

// MARK: - SharedContainer Cross-Process Task Queue & Concurrency Gate (Batch 82)

/// Valid lifecycle statuses for cross-process shared tasks.
public enum SharedTaskStatus: String, Sendable, Codable, CaseIterable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

/// Standard task priority levels.
public enum SharedTaskPriority: String, Sendable, Codable, CaseIterable, Comparable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case critical = "critical"

    public var weight: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: SharedTaskPriority, rhs: SharedTaskPriority) -> Bool {
        lhs.weight < rhs.weight
    }
}

/// Violation detected in shared task queue or state transition.
public struct SharedTaskViolation: Sendable, Codable, Equatable {
    public let taskId: UUID?
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(taskId: UUID? = nil, code: String, message: String, isFatal: Bool = true) {
        self.taskId = taskId
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Policy constraints for cross-process task queue execution.
public struct SharedQueuePolicy: Sendable, Codable, Equatable {
    public var maxConcurrentRunningTasks: Int
    public var maxTaskExecutionSeconds: TimeInterval
    public var allowAutoRetry: Bool

    public init(
        maxConcurrentRunningTasks: Int = 4,
        maxTaskExecutionSeconds: TimeInterval = 300.0,
        allowAutoRetry: Bool = true
    ) {
        self.maxConcurrentRunningTasks = maxConcurrentRunningTasks
        self.maxTaskExecutionSeconds = maxTaskExecutionSeconds
        self.allowAutoRetry = allowAutoRetry
    }
}

/// Complete report of shared container task queue health.
public struct TaskQueueAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let totalTasksCount: Int
    public let pendingCount: Int
    public let runningCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let orphanedTasksCount: Int
    public let violations: [SharedTaskViolation]

    public init(
        passed: Bool,
        score: Double,
        totalTasksCount: Int,
        pendingCount: Int,
        runningCount: Int,
        completedCount: Int,
        failedCount: Int,
        orphanedTasksCount: Int,
        violations: [SharedTaskViolation]
    ) {
        self.passed = passed
        self.score = score
        self.totalTasksCount = totalTasksCount
        self.pendingCount = pendingCount
        self.runningCount = runningCount
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.orphanedTasksCount = orphanedTasksCount
        self.violations = violations
    }
}

/// Auditor for cross-process SharedTask state machines, priority queues, and concurrency bounds.
public enum SharedContainerIntegrityAuditor {

    // Valid state transitions graph
    private static let validTransitions: [SharedTaskStatus: Set<SharedTaskStatus>] = [
        .pending: [.running, .failed],
        .running: [.completed, .failed],
        .completed: [],
        .failed: [.pending] // Retry path
    ]

    // MARK: - State Transition Validation

    /// Validates if a state transition between two statuses is strictly valid.
    public static func validateStateTransition(from current: String, to next: String) -> Bool {
        guard let currentStatus = SharedTaskStatus(rawValue: current.lowercased()),
              let nextStatus = SharedTaskStatus(rawValue: next.lowercased()) else {
            return false
        }
        if currentStatus == nextStatus { return true }
        return validTransitions[currentStatus]?.contains(nextStatus) ?? false
    }

    // MARK: - Priority Sorting

    /// Sorts an array of SharedTasks by priority descending, placing critical tasks first.
    public static func sortQueueByPriority(tasks: [SharedTask]) -> [SharedTask] {
        tasks.sorted { a, b in
            let pA = SharedTaskPriority(rawValue: a.priority.lowercased()) ?? .medium
            let pB = SharedTaskPriority(rawValue: b.priority.lowercased()) ?? .medium
            return pA > pB
        }
    }

    // MARK: - Queue Audit

    /// Audits the entire cross-process shared queue against policy limits, orphaned tasks, and schema validity.
    public static func auditQueue(
        tasks: [SharedTask],
        activeHeartbeats: [UUID: Date] = [:],
        now: Date = Date(),
        policy: SharedQueuePolicy = SharedQueuePolicy()
    ) -> TaskQueueAuditReport {
        var violations: [SharedTaskViolation] = []
        var pendingCount = 0
        var runningCount = 0
        var completedCount = 0
        var failedCount = 0
        var orphanedCount = 0

        for task in tasks {
            // 1. Title validation
            if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                violations.append(SharedTaskViolation(
                    taskId: task.id,
                    code: "EMPTY_TASK_TITLE",
                    message: "Task has empty title."
                ))
            }

            // 2. Status classification
            guard let status = SharedTaskStatus(rawValue: task.status.lowercased()) else {
                violations.append(SharedTaskViolation(
                    taskId: task.id,
                    code: "INVALID_TASK_STATUS",
                    message: "Task has unrecognized status '\(task.status)'."
                ))
                continue
            }

            switch status {
            case .pending:
                pendingCount += 1
            case .running:
                runningCount += 1
                // Check heartbeat for orphaned tasks
                if let lastSeen = activeHeartbeats[task.id] {
                    let elapsed = now.timeIntervalSince(lastSeen)
                    if elapsed > policy.maxTaskExecutionSeconds {
                        orphanedCount += 1
                        violations.append(SharedTaskViolation(
                            taskId: task.id,
                            code: "ORPHANED_RUNNING_TASK",
                            message: "Task '\(task.title)' running for \(String(format: "%.1f", elapsed))s without heartbeat update.",
                            isFatal: false
                        ))
                    }
                }
            case .completed:
                completedCount += 1
            case .failed:
                failedCount += 1
            }
        }

        // 3. Concurrency limit check
        if runningCount > policy.maxConcurrentRunningTasks {
            violations.append(SharedTaskViolation(
                code: "CONCURRENCY_LIMIT_EXCEEDED",
                message: "Running tasks count (\(runningCount)) exceeds policy limit of \(policy.maxConcurrentRunningTasks)."
            ))
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? (violations.isEmpty ? 100.0 : 85.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 25.0)

        return TaskQueueAuditReport(
            passed: passed,
            score: score,
            totalTasksCount: tasks.count,
            pendingCount: pendingCount,
            runningCount: runningCount,
            completedCount: completedCount,
            failedCount: failedCount,
            orphanedTasksCount: orphanedCount,
            violations: violations
        )
    }
}
