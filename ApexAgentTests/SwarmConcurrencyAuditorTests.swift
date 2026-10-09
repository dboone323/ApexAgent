import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 97 — Swarm Worker Priority & Concurrency Throttling Gate Tests")
struct SwarmConcurrencyAuditorTests {

    @Test("Valid swarm schedule organizes tasks into batches respecting concurrency limit")
    func validSwarmScheduleBatches() {
        let tasks = [
            SwarmTaskDescriptor(botName: "Codex", prompt: "Write unit tests", priority: .high, timeoutSeconds: 30),
            SwarmTaskDescriptor(botName: "Nexus", prompt: "Review PR diffs", priority: .normal, timeoutSeconds: 20),
            SwarmTaskDescriptor(botName: "Auditor", prompt: "Run security audit", priority: .critical, timeoutSeconds: 15),
            SwarmTaskDescriptor(botName: "Chronos", prompt: "Cleanup artifacts", priority: .background, timeoutSeconds: 10)
        ]

        let config = SwarmConcurrencyConfig(maxConcurrentWorkers: 2, maxTotalWorkers: 10)
        let plan = SwarmConcurrencyAuditor.auditAndPlanSwarm(tasks: tasks, config: config)

        #expect(plan.passed)
        #expect(plan.score == 100.0)
        #expect(plan.scheduledBatches.count == 2)
        #expect(plan.violations.isEmpty)

        // Critical task (Auditor) and High task (Codex) must be in the first batch
        let firstBatch = plan.scheduledBatches[0]
        #expect(firstBatch.tasks.count == 2)
        #expect(firstBatch.tasks.contains { $0.botName == "Auditor" })
        #expect(firstBatch.tasks.contains { $0.botName == "Codex" })
    }

    @Test("Bot collision prevents assigning the same bot concurrently in a single batch")
    func botCollisionPreventsParallelExecution() {
        let tasks = [
            SwarmTaskDescriptor(botName: "Codex", prompt: "First task for Codex", priority: .high),
            SwarmTaskDescriptor(botName: "Codex", prompt: "Second task for Codex", priority: .high),
            SwarmTaskDescriptor(botName: "Nexus", prompt: "Task for Nexus", priority: .high)
        ]

        let config = SwarmConcurrencyConfig(maxConcurrentWorkers: 4)
        let plan = SwarmConcurrencyAuditor.auditAndPlanSwarm(tasks: tasks, config: config)

        #expect(plan.passed)
        #expect(plan.scheduledBatches.count == 2)

        // Batch 1 has one Codex and one Nexus
        let batch1Bots = plan.scheduledBatches[0].tasks.map(\.botName)
        #expect(batch1Bots.filter { $0 == "Codex" }.count == 1)

        // Batch 2 has the second Codex
        let batch2Bots = plan.scheduledBatches[1].tasks.map(\.botName)
        #expect(batch2Bots.filter { $0 == "Codex" }.count == 1)
    }

    @Test("Memory budget limits task grouping per batch")
    func memoryBudgetThrottlesBatching() {
        let tasks = [
            SwarmTaskDescriptor(botName: "BotA", prompt: "Task A", estimatedMemoryMB: 800),
            SwarmTaskDescriptor(botName: "BotB", prompt: "Task B", estimatedMemoryMB: 800),
            SwarmTaskDescriptor(botName: "BotC", prompt: "Task C", estimatedMemoryMB: 800)
        ]

        // 1000MB limit allows only 1 task of 800MB per batch
        let config = SwarmConcurrencyConfig(maxConcurrentWorkers: 4, maxMemoryBudgetMB: 1000)
        let plan = SwarmConcurrencyAuditor.auditAndPlanSwarm(tasks: tasks, config: config)

        #expect(plan.passed)
        #expect(plan.scheduledBatches.count == 3)
    }

    @Test("Empty task list fails validation immediately")
    func emptyTaskListFails() {
        let config = SwarmConcurrencyConfig()
        let plan = SwarmConcurrencyAuditor.auditAndPlanSwarm(tasks: [], config: config)

        #expect(!plan.passed)
        #expect(plan.violations.contains { $0.code == "EMPTY_SWARM_TASKS" })
    }

    @Test("Task count exceeding maximum allowed fails validation")
    func excessiveTaskCountFails() {
        let tasks = (1...15).map { i in
            SwarmTaskDescriptor(botName: "Bot\(i)", prompt: "Task \(i)")
        }

        let config = SwarmConcurrencyConfig(maxTotalWorkers: 10)
        let plan = SwarmConcurrencyAuditor.auditAndPlanSwarm(tasks: tasks, config: config)

        #expect(!plan.passed)
        #expect(plan.violations.contains { $0.code == "EXCESSIVE_TOTAL_WORKERS" })
    }

    @Test("Task with empty bot name or empty prompt generates fatal violation")
    func emptyBotNameOrPromptFails() {
        let tasks = [
            SwarmTaskDescriptor(botName: "  ", prompt: "Do something"),
            SwarmTaskDescriptor(botName: "ValidBot", prompt: "   ")
        ]

        let config = SwarmConcurrencyConfig()
        let plan = SwarmConcurrencyAuditor.auditAndPlanSwarm(tasks: tasks, config: config)

        #expect(!plan.passed)
        #expect(plan.violations.contains { $0.code == "EMPTY_BOT_NAME" })
        #expect(plan.violations.contains { $0.code == "EMPTY_TASK_PROMPT" })
    }
}
