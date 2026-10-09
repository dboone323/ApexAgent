import Foundation
import Testing
import SharedModels
@testable import ApexAgentCore

@Suite("Batch 82 — SharedContainer Cross-Process Task Queue & Concurrency Gate Tests")
struct SharedContainerIntegrityAuditorTests {

    @Test("Valid task state transitions are accepted and invalid transitions rejected")
    func stateTransitionsValidation() {
        // Valid forward transitions
        #expect(SharedContainerIntegrityAuditor.validateStateTransition(from: "pending", to: "running"))
        #expect(SharedContainerIntegrityAuditor.validateStateTransition(from: "running", to: "completed"))
        #expect(SharedContainerIntegrityAuditor.validateStateTransition(from: "running", to: "failed"))
        #expect(SharedContainerIntegrityAuditor.validateStateTransition(from: "failed", to: "pending")) // Retry

        // Invalid transitions
        #expect(!SharedContainerIntegrityAuditor.validateStateTransition(from: "completed", to: "running"))
        #expect(!SharedContainerIntegrityAuditor.validateStateTransition(from: "completed", to: "pending"))
        #expect(!SharedContainerIntegrityAuditor.validateStateTransition(from: "pending", to: "completed"))
    }

    @Test("Tasks are sorted by priority correctly with critical first")
    func prioritySortingOrdersTasks() {
        let low = SharedTask(title: "Cleanup temp logs", detail: "", status: "pending", priority: "low")
        let critical = SharedTask(title: "Kernel panic restart", detail: "", status: "pending", priority: "critical")
        let medium = SharedTask(title: "Update cache", detail: "", status: "pending", priority: "medium")
        let high = SharedTask(title: "Flush memory store", detail: "", status: "pending", priority: "high")

        let sorted = SharedContainerIntegrityAuditor.sortQueueByPriority(tasks: [low, medium, critical, high])
        #expect(sorted.map(\.title) == [
            "Kernel panic restart",
            "Flush memory store",
            "Update cache",
            "Cleanup temp logs"
        ])
    }

    @Test("Clean task queue passes audit with 100% score")
    func cleanQueuePassesAudit() {
        let tasks = [
            SharedTask(title: "Task 1", detail: "", status: "pending", priority: "high"),
            SharedTask(title: "Task 2", detail: "", status: "running", priority: "medium"),
            SharedTask(title: "Task 3", detail: "", status: "completed", priority: "low")
        ]

        let report = SharedContainerIntegrityAuditor.auditQueue(tasks: tasks)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.totalTasksCount == 3)
        #expect(report.pendingCount == 1)
        #expect(report.runningCount == 1)
        #expect(report.completedCount == 1)
        #expect(report.violations.isEmpty)
    }

    @Test("Excessive concurrent running tasks triggers CONCURRENCY_LIMIT_EXCEEDED")
    func concurrencyLimitExceededFails() {
        let tasks = (0..<6).map { i in
            SharedTask(title: "Task \(i)", detail: "", status: "running", priority: "medium")
        }
        let policy = SharedQueuePolicy(maxConcurrentRunningTasks: 4)

        let report = SharedContainerIntegrityAuditor.auditQueue(tasks: tasks, policy: policy)
        #expect(!report.passed)
        #expect(report.runningCount == 6)
        #expect(report.violations.contains { $0.code == "CONCURRENCY_LIMIT_EXCEEDED" })
    }

    @Test("Orphaned running task without heartbeat triggers warning violation")
    func orphanedTaskDetected() {
        let now = Date()
        let staleTaskId = UUID()
        let tasks = [
            SharedTask(id: staleTaskId, title: "Stale task", detail: "", status: "running", priority: "medium")
        ]
        // Heartbeat seen 400s ago > 300s threshold
        let heartbeats = [staleTaskId: now.addingTimeInterval(-400.0)]

        let report = SharedContainerIntegrityAuditor.auditQueue(
            tasks: tasks,
            activeHeartbeats: heartbeats,
            now: now
        )

        #expect(report.orphanedTasksCount == 1)
        #expect(report.violations.contains { $0.code == "ORPHANED_RUNNING_TASK" })
    }
}
