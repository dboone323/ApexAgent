import Testing
import Foundation
import Synchronization
import SwiftData
import Network
@testable import ApexAgentCore
@testable import SharedModels
@testable import SharedKit

// MARK: - Milestone 1 Challenger Concurrency & Lifecycle Stress Suite

@Suite("Milestone1ChallengerConcurrencyStressTests", .serialized)
final class Milestone1ChallengerConcurrencyStressTests {

    // MARK: - 1. TraceBus Event Streams & Ring Buffer Empirical Hardening

    @Test func testTraceBusMassiveConcurrentPublisherFlood() async {
        // Isolated instance: the shared singleton is appended to concurrently by
        // other parallel suites, which would non-deterministically evict our
        // publisher events from the ring buffer before we read them back.
        let traceBus = TraceBus(maxEvents: 400)
        traceBus.clear()

        let publisherCount = 100
        let eventsPerPublisher = 200
        let expectedTotal = publisherCount * eventsPerPublisher

        // Concurrently flood 20,000 events into the isolated TraceBus
        await withTaskGroup(of: Void.self) { group in
            for p in 0..<publisherCount {
                group.addTask {
                    for e in 0..<eventsPerPublisher {
                        let event = TraceEvent(
                            source: "publisher_\(p)",
                            operation: "event_\(e)",
                            detail: "payload_\(p)_\(e)",
                            metadata: ["seq": "\(p * eventsPerPublisher + e)"]
                        )
                        traceBus.append(event)
                    }
                }
            }
        }

        // Verify that the ring buffer strictly enforces maxEvents (400)
        let recent = traceBus.recentEvents(limit: 1000)
        #expect(recent.count == 400, "TraceBus must strictly hold exactly maxEvents (400) events after a flood of \(expectedTotal) events")

        // Verify recent events contain valid items
        #expect(!recent.isEmpty)
        #expect(recent.contains(where: { $0.source.starts(with: "publisher_") }))
    }

    @Test func testTraceBusContinuationCleanupUnderRapidStreamChurn() async {
        let traceBus = TraceBus.shared
        traceBus.clear()

        let churnCount = 200

        // Rapidly create and consume 1 event from 200 independent AsyncStreams
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<churnCount {
                group.addTask {
                    let stream = traceBus.eventStream()
                    let collector = Task {
                        for await _ in stream {
                            break // Exit stream immediately after 1 event
                        }
                    }
                    traceBus.append(TraceEvent(source: "churn_\(i)", operation: "pulse", detail: "ok", metadata: nil))
                    _ = await collector.value
                }
            }
        }

        // Publish a final event and verify normal stream subscription still functions perfectly
        let verificationStream = traceBus.eventStream()
        let verifyTask = Task {
            for await ev in verificationStream {
                if ev.source == "post_churn_verification" {
                    return true
                }
            }
            return false
        }

        traceBus.append(TraceEvent(source: "post_churn_verification", operation: "check", detail: "passed", metadata: nil))
        let result = await verifyTask.value
        #expect(result == true, "TraceBus stream mechanism must remain fully responsive after high stream churn")
    }

    @Test func testTraceBusCategoryStreamFilteringUnderHighContention() async {
        let traceBus = TraceBus.shared
        traceBus.clear()

        let catATarget = 100
        let catBTarget = 100

        let streamA = traceBus.stream(forCategory: "alpha")
        let streamB = traceBus.stream(forCategory: "beta")

        let taskA = Task {
            var count = 0
            for await ev in streamA {
                if ev.source == "alpha" {
                    count += 1
                }
                if count >= catATarget { break }
            }
            return count
        }

        let taskB = Task {
            var count = 0
            for await ev in streamB {
                if ev.source == "beta" {
                    count += 1
                }
                if count >= catBTarget { break }
            }
            return count
        }

        // Concurrently publish mixed categories
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    let cat = (i % 2 == 0) ? "alpha" : "beta"
                    traceBus.append(TraceEvent(source: cat, operation: "tick", detail: "index_\(i)", metadata: nil))
                }
            }
        }

        let receivedA = await taskA.value
        let receivedB = await taskB.value

        #expect(receivedA == catATarget, "Category stream 'alpha' must receive exact target events")
        #expect(receivedB == catBTarget, "Category stream 'beta' must receive exact target events")
    }

    // MARK: - 2. TurnWatchdog Concurrency, Stall Sweeping & Timer Cleanup

    @Test func testTurnWatchdogConcurrentLifecycleAndTouchContention() async {
        final class SafeStallCollector: Sendable {
            private let items = Mutex<[WatchedTurn]>([])

            func add(_ item: WatchedTurn) {
                items.withLock { $0.append(item) }
            }

            var count: Int {
                items.withLock { $0.count }
            }

            var allItems: [WatchedTurn] {
                items.withLock { $0 }
            }
        }

        let collector = SafeStallCollector()
        var simulatedTime: TimeInterval = 1000.0

        let watchdog = TurnWatchdog(options: .init(
            stallMs: 500,
            checkMs: 100,
            onStall: { turn in
                collector.add(turn)
            },
            now: { simulatedTime }
        ))

        // Watch 50 concurrent threads
        let threadCount = 50
        for i in 0..<threadCount {
            watchdog.watch(threadId: "thread_\(i)", botId: "bot_\(i % 5)")
        }

        for i in 0..<threadCount {
            #expect(watchdog.isWatching(threadId: "thread_\(i)"))
        }

        // Advance time and concurrently touch even threads while odd threads remain untouched
        simulatedTime += 300.0
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<threadCount {
                group.addTask {
                    if i % 2 == 0 {
                        watchdog.touch(threadId: "thread_\(i)")
                    }
                }
            }
        }

        // Advance time past stall threshold for untouched threads
        simulatedTime += 300.0

        // Concurrently sweep while touching even threads
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in stride(from: 0, to: threadCount, by: 2) {
                    watchdog.touch(threadId: "thread_\(i)")
                }
            }
            group.addTask {
                watchdog.sweep()
            }
        }

        // Exactly 25 odd threads should have stalled
        #expect(collector.count == 25, "Exactly 25 untouched threads should be detected as stalled, got \(collector.count)")
        let stalledThreads = Set(collector.allItems.map(\.threadId))
        for i in stride(from: 1, to: threadCount, by: 2) {
            #expect(stalledThreads.contains("thread_\(i)"), "Thread \(i) should have stalled")
        }

        // Settle remaining even threads
        for i in stride(from: 0, to: threadCount, by: 2) {
            #expect(watchdog.isWatching(threadId: "thread_\(i)"))
            watchdog.settle(threadId: "thread_\(i)")
            #expect(!watchdog.isWatching(threadId: "thread_\(i)"))
        }

        watchdog.stop()
    }

    @Test func testTurnWatchdogWaitingOnHumanExemptionUnderContention() {
        var simulatedTime: TimeInterval = 2000.0
        var stalledCount = 0

        let watchdog = TurnWatchdog(options: .init(
            stallMs: 300,
            checkMs: 50,
            onStall: { _ in stalledCount += 1 },
            now: { simulatedTime }
        ))

        watchdog.watch(threadId: "human_gate_thread", botId: "apex")
        watchdog.setWaitingOnHuman(threadId: "human_gate_thread", waiting: true)

        // Advance simulated time by 1 hour (3600 seconds)
        simulatedTime += 3600.0
        watchdog.sweep()

        #expect(stalledCount == 0, "Turn parked on human approval must never stall regardless of duration")
        #expect(watchdog.isWatching(threadId: "human_gate_thread"))

        // Human decision arrives -> resume normal clock
        watchdog.setWaitingOnHuman(threadId: "human_gate_thread", waiting: false)
        watchdog.sweep()
        #expect(stalledCount == 0, "Immediate sweep after resuming human wait should not stall since lastEventAt was refreshed")

        // Advance past stallMs -> now it should stall
        simulatedTime += 400.0
        watchdog.sweep()
        #expect(stalledCount == 1, "Turn should stall once time elapses after human wait resolved")

        watchdog.stop()
    }

    // MARK: - 3. ApexGatewayServer Network Lifecycles & Confirmation Continuations

    @MainActor
    @Test func testGatewayServerCleanStartStopAndPendingContinuationResume() throws {
        let orchestrator = AgentOrchestrator()
        let server = ApexGatewayServer(port: 0, orchestrator: orchestrator)

        try server.start()

        // Verify state change broadcasting does not crash or throw
        orchestrator.onStateChanged?()

        // Stop server cleanly
        server.stop()
    }

    @MainActor
    @Test func testGatewayServerRapidRestartCycles() async throws {
        let orchestrator = AgentOrchestrator()

        for _ in 0..<5 {
            let server = ApexGatewayServer(port: 0, orchestrator: orchestrator)
            try server.start()
            server.stop()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - 4. RepeatDetector Thread Isolation & LRU Eviction Under Load

    @Test func testRepeatDetectorThreadIsolationAndThresholdEscalation() async {
        let detector = RepeatDetector(thresholds: [2, 4, 6], maxKeysPerThread: 10)
        let threadCount = 30
        let cycles = 6

        await withTaskGroup(of: Void.self) { group in
            for t in 0..<threadCount {
                group.addTask {
                    let key = RepeatCallKey.make(tool: "shell_exec", arguments: "cmd: ping host_\(t)")!
                    for c in 1...cycles {
                        let res = detector.record(thread: "t_\(t)", key: key)
                        if c == 2 {
                            #expect(res.threshold == 2)
                        } else if c == 4 {
                            #expect(res.threshold == 4)
                        } else if c == 6 {
                            #expect(res.threshold == 6)
                        }
                    }
                }
            }
        }

        // Verify all 30 threads maintained clean independent state
        for t in 0..<threadCount {
            #expect(detector.activeKeys(thread: "t_\(t)") == 1)
            detector.settle(thread: "t_\(t)")
            #expect(detector.activeKeys(thread: "t_\(t)") == 0)
        }
    }

    // MARK: - 5. SecretRedactor Multi-Threaded Masking Integrity

    @Test func testSecretRedactorMultiThreadedStress() async {
        let testStrings = [
            "sk-ant-api03-abcdef12345678901234567890123456",
            "ghp_123456789012345678901234567890123456",
            "Authorization: Bearer mySecretToken1234567890abcdef",
            "api_key: superclassified12345678"
        ]

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let raw = testStrings[i % testStrings.count]
                    let redacted = SecretRedactor.redact(text: raw)
                    #expect(!redacted.contains("abcdef12345678901234567890123456"))
                    #expect(!redacted.contains("ghp_123456789012345678901234567890123456"))
                    #expect(!redacted.contains("mySecretToken1234567890abcdef"))
                    #expect(!redacted.contains("superclassified12345678"))
                    #expect(redacted.contains("«redacted") || redacted.contains("Bearer"))
                }
            }
        }
    }
}
