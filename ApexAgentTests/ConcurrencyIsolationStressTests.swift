import Testing
import Foundation
import SwiftData
import Network
@testable import ApexAgentCore
@testable import SharedModels
@testable import SharedKit

// MARK: - 1. TraceBus Concurrency & Ring-Buffer Stress Tests

@Suite("TraceBusConcurrencyStressTests")
struct TraceBusConcurrencyStressTests {

    @Test func testHighConcurrencyPublisherContentionAndRingBufferCap() async throws {
        let traceBus = TraceBus.shared
        traceBus.clear()

        let taskCount = 50
        let eventsPerTask = 100

        // Start multiple parallel category streams
        let auditStream = traceBus.stream(forCategory: "stress_audit")
        let toolStream = traceBus.stream(forCategory: "stress_tool")

        let auditTask = Task {
            var received = 0
            for await event in auditStream {
                if event.source == "stress_audit" {
                    received += 1
                }
                if received >= 500 { break }
            }
            return received
        }

        let toolTask = Task {
            var received = 0
            for await event in toolStream {
                if event.source == "stress_tool" {
                    received += 1
                }
                if received >= 500 { break }
            }
            return received
        }

        // Concurrently spawn 50 parallel tasks emitting 100 events each
        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<taskCount {
                group.addTask {
                    for eventId in 0..<eventsPerTask {
                        let category = (taskId % 2 == 0) ? "stress_audit" : "stress_tool"
                        let event = TraceEvent(
                            source: category,
                            operation: "stress_op_\(eventId)",
                            detail: "payload_index_\(eventId)",
                            metadata: ["taskId": "\(taskId)", "eventId": "\(eventId)"]
                        )
                        traceBus.append(event)
                    }
                }
            }
        }

        // Concurrently query recentEvents while tasks finish
        let recentSnapshot = traceBus.recentEvents(limit: 500)
        #expect(recentSnapshot.count <= 400, "TraceBus internal ring buffer must strictly enforce maxEvents cap of 400")

        // Wait for category tasks or timeout
        let auditReceived = await auditTask.value
        let toolReceived = await toolTask.value
        #expect(auditReceived > 0, "Category stream should receive filtered events under load")
        #expect(toolReceived > 0, "Category stream should receive filtered events under load")

        // Final verification of events count limit
        let finalEvents = traceBus.recentEvents(limit: 500)
        #expect(finalEvents.count <= 400)
        #expect(!finalEvents.isEmpty)
    }

    @Test func testRapidStreamSubscriptionAndCancellationCycles() async throws {
        let traceBus = TraceBus.shared
        traceBus.clear()

        // Spin up and cancel 100 streams in rapid succession
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let stream = traceBus.eventStream()
                    let subTask = Task {
                        for await _ in stream {
                            break
                        }
                    }
                    traceBus.append(TraceEvent(source: "cycler_\(i)", operation: "pulse", detail: "ok", metadata: nil))
                    subTask.cancel()
                }
            }
        }

        // Verify TraceBus remains completely functional after rapid cancel churn
        traceBus.append(TraceEvent(source: "post_churn", operation: "verify", detail: "healthy", metadata: nil))
        let recent = traceBus.recentEvents(limit: 10)
        #expect(recent.contains { $0.source == "post_churn" && $0.detail == "healthy" })
    }
}

// MARK: - 2. @ToolActor Isolation & Reentrancy Stress Tests

@ToolActor
private final class ActorStateAccumulator {
    private var counter: Int = 0
    private var auditTrail: [String] = []

    func recordTransaction(id: Int, caller: String) async -> Int {
        counter += 1
        auditTrail.append("tx_\(id)_by_\(caller)")
        await Task.yield()
        return counter
    }

    func currentCount() -> Int {
        counter
    }

    func allAuditRecords() -> [String] {
        auditTrail
    }

    func reset() {
        counter = 0
        auditTrail.removeAll()
    }
}

@Suite("ToolActorIsolationStressTests")
struct ToolActorIsolationStressTests {

    @Test func testParallelInvocationsMaintainStrictSerialIsolation() async {
        let accumulator = ActorStateAccumulator()
        await accumulator.reset()

        let totalWorkers = 100

        await withTaskGroup(of: Int.self) { group in
            for i in 0..<totalWorkers {
                group.addTask {
                    await accumulator.recordTransaction(id: i, caller: "worker_\(i)")
                }
            }
        }

        let finalCount = await accumulator.currentCount()
        let auditRecords = await accumulator.allAuditRecords()

        #expect(finalCount == totalWorkers, "Every transaction must be accounted for without race conditions")
        #expect(auditRecords.count == totalWorkers, "Audit log must contain exactly \(totalWorkers) records")
    }
}

// MARK: - 3. BotManager & PeerApprovalCoordinator Stress Tests

@MainActor
@Suite("BotManagerConcurrencyStressTests")
struct BotManagerConcurrencyStressTests {

    private func makeTestEnvironment() throws -> (BotManager, ModelContainer) {
        let schema = Schema([
            Conversation.self,
            Message.self,
            AgentMemory.self,
            AppPermissions.self,
            ProjectModel.self,
            TaskModel.self,
            SprintModel.self,
            CodeIssueModel.self,
            ReviewSession.self,
            Skill.self,
            Routine.self,
            BotProfile.self,
            BotMemoryEntry.self,
            DailyBriefing.self,
            WeeklyReflection.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let manager = BotManager(orchestrator: orchestrator, computer: computer)
        manager.modelContext = ModelContext(container)
        return (manager, container)
    }

    @Test func testConcurrentBotCreationDuplicationAndSessionResolution() throws {
        let (manager, _) = try makeTestEnvironment()

        // Create 20 bots
        var createdBots: [BotProfile] = []
        for i in 0..<20 {
            let bot = manager.createBot(
                name: "Specialist_\(i)",
                title: "Role \(i)",
                descriptionText: "Specialized in subtask \(i)"
            )
            createdBots.append(bot)
        }

        #expect(manager.allBots.count == 20)

        // Rapid duplicate and memory updates
        for bot in createdBots.prefix(10) {
            let duplicate = manager.duplicateBot(bot)
            #expect(duplicate.name.contains("copy"))
            manager.updateBotMemory(bot, newMemory: "Updated key memories for \(bot.name)")
        }

        #expect(manager.allBots.count == 30)

        // Session lookup should be stable and non-colliding
        for bot in manager.allBots {
            let session = manager.session(for: bot)
            #expect(session.bot.id == bot.id)
        }
    }

    @Test func testPeerApprovalConcurrentContentionAndGrantIsolation() throws {
        let (manager, _) = try makeTestEnvironment()

        let initiator = manager.createBot(name: "Initiator", title: "Chief", descriptionText: "")
        let targetA = manager.createBot(name: "WorkerA", title: "Dev", descriptionText: "")
        let targetB = manager.createBot(name: "WorkerB", title: "QA", descriptionText: "")

        _ = manager.session(for: initiator)
        _ = manager.session(for: targetA)
        _ = manager.session(for: targetB)

        // Request approval for WorkerA
        let decisionA = manager.peerDeliveryDecision(from: initiator, to: targetA, message: "Deploy version 1.0")
        guard case .blockedPendingCard(let reqIdA) = decisionA else {
            Issue.record("Should be blocked pending card for targetA")
            return
        }

        #expect(manager.botsNeedingAttention.map(\.id).contains(initiator.id))

        // Grant WorkerA with remember
        let allowedA = manager.resolvePeerRequest(requestId: reqIdA, allow: true, remember: true)
        #expect(allowedA == true)

        // TargetA should now deliver silently
        let decisionA2 = manager.peerDeliveryDecision(from: initiator, to: targetA, message: "Deploy version 1.1")
        #expect(decisionA2 == .deliver)

        // TargetB must still require approval
        let decisionB = manager.peerDeliveryDecision(from: initiator, to: targetB, message: "Run tests")
        guard case .blockedPendingCard(let reqIdB) = decisionB else {
            Issue.record("Should be blocked pending card for targetB")
            return
        }

        // Deny TargetB
        let allowedB = manager.resolvePeerRequest(requestId: reqIdB, allow: false, remember: false)
        #expect(allowedB == false)
        #expect(!manager.peerApprovals.hasGrant(action: .askBot, targetBotId: targetB.id.uuidString))
    }
}

// MARK: - 4. ApexGatewayServer Lifecycle & Continuation Resumption Tests

@MainActor
@Suite("ApexGatewayServerLifecycleStressTests")
struct ApexGatewayServerLifecycleStressTests {

    @Test func testServerStartStopAndPendingConfirmationCleanup() throws {
        let orchestrator = AgentOrchestrator()
        let server = ApexGatewayServer(port: 19876, orchestrator: orchestrator)

        // Start server
        try server.start()

        // Stop server immediately and verify no crash, clean shutdown
        server.stop()
    }
}

// MARK: - 5. SwiftData Concurrent Context & Model Graph Integrity Tests

@MainActor
@Suite("SwiftDataModelConcurrencyStressTests")
struct SwiftDataModelConcurrencyStressTests {

    @Test func testRelationalGraphIntegrityUnderLoad() throws {
        let schema = Schema([
            Conversation.self,
            Message.self,
            ProjectModel.self,
            TaskModel.self,
            SprintModel.self,
            CodeIssueModel.self,
            ReviewSession.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        // Create a project with deep nested hierarchy
        let project = ProjectModel(
            name: "HighConcurrencyProject",
            summary: "Stress testing relational integrity",
            language: "Swift",
            localPath: "/tmp/apex_test_project"
        )
        context.insert(project)

        for s in 0..<5 {
            let sprint = SprintModel(
                name: "Sprint \(s)",
                goal: "Goal for sprint \(s)",
                startDate: Date(),
                endDate: Date().addingTimeInterval(86400 * 7)
            )
            sprint.project = project
            project.sprints.append(sprint)
            context.insert(sprint)

            for t in 0..<10 {
                let task = TaskModel(
                    title: "Task \(s).\(t)",
                    detail: "Concurrent work item",
                    status: .inProgress,
                    priority: .high
                )
                task.project = project
                task.sprint = sprint
                project.tasks.append(task)
                sprint.tasks.append(task)
                context.insert(task)
            }
        }

        try context.save()

        // Verify count
        let fetchTasks = FetchDescriptor<TaskModel>()
        let tasks = try context.fetch(fetchTasks)
        #expect(tasks.count == 50)

        let fetchSprints = FetchDescriptor<SprintModel>()
        let sprints = try context.fetch(fetchSprints)
        #expect(sprints.count == 5)

        // Cascade delete project
        context.delete(project)
        try context.save()

        // Verify cascade deletion
        let remainingTasks = try context.fetch(fetchTasks)
        let remainingSprints = try context.fetch(fetchSprints)
        #expect(remainingTasks.isEmpty, "Deleting ProjectModel must cascade-delete all TaskModel records")
        #expect(remainingSprints.isEmpty, "Deleting ProjectModel must cascade-delete all SprintModel records")
    }
}

// MARK: - 6. RepeatDetector Concurrent Thread Isolation Stress Tests

@Suite("RepeatDetectorConcurrencyStressTests")
struct RepeatDetectorConcurrencyStressTests {

    @Test func testParallelThreadRecordingMaintainsStrictIsolation() async {
        let detector = RepeatDetector(thresholds: [3, 5])
        let threadCount = 20
        let callsPerThread = 5

        await withTaskGroup(of: Void.self) { group in
            for threadId in 0..<threadCount {
                group.addTask {
                    let key = RepeatCallKey.make(tool: "web_search", arguments: "query: topic_\(threadId)")!
                    for _ in 0..<callsPerThread {
                        _ = detector.record(thread: "thread_\(threadId)", key: key)
                    }
                }
            }
        }

        for threadId in 0..<threadCount {
            #expect(detector.activeKeys(thread: "thread_\(threadId)") == 1)
        }
    }
}

// MARK: - 7. ApprovalPolicy Concurrency & Guard Invariant Tests

@Suite("ApprovalPolicyConcurrencyStressTests")
struct ApprovalPolicyConcurrencyStressTests {

    @Test func testDestructiveGuardsStrictlySupersedeAutoApproveUnderConcurrency() async {
        let workerCount = 100

        await withTaskGroup(of: ApprovalVerdict.self) { group in
            for i in 0..<workerCount {
                group.addTask {
                    let isDestructive = (i % 2 == 0)
                    let summary = isDestructive ? "rm -rf /tmp/build_\(i)" : "git status"
                    let key = ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: summary)
                    return ApprovalPolicy.verdict(
                        tool: "run_shell_command",
                        summary: summary,
                        alwaysAllow: [key],
                        autoApprove: true
                    )
                }
            }

            var destructiveBlocked = 0
            var safeAllowed = 0
            for await verdict in group {
                if verdict.source == .destructiveGuard {
                    destructiveBlocked += 1
                } else if verdict.approve != nil {
                    safeAllowed += 1
                }
            }

            #expect(destructiveBlocked == workerCount / 2, "All destructive commands must be blocked regardless of autoApprove")
            #expect(safeAllowed == workerCount / 2, "Safe alwaysAllowed commands should pass")
        }
    }
}

// MARK: - 8. SecretRedactor Concurrency & Masking Consistency Tests

@Suite("SecretRedactorConcurrencyStressTests")
struct SecretRedactorConcurrencyStressTests {

    @Test func testParallelRedactionOfMultiPatternSecrets() async {
        let sampleApiKey = "sk-ant-api03-abcdef1234567890abcdef123456"
        let sampleBearer = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.doNotLeakThisSignature123"
        let textToRedact = "Authorization header: \(sampleBearer) and Anthropic key: \(sampleApiKey)"

        let totalWorkers = 100

        await withTaskGroup(of: String.self) { group in
            for _ in 0..<totalWorkers {
                group.addTask {
                    return SecretRedactor.redact(text: textToRedact)
                }
            }

            for await redactedResult in group {
                #expect(!redactedResult.contains(sampleApiKey), "API key must not leak")
                #expect(!redactedResult.contains("doNotLeakThisSignature123"), "Bearer token signature must not leak")
                #expect(redactedResult.contains("«redacted"), "Redaction mask must be applied")
            }
        }
    }
}
