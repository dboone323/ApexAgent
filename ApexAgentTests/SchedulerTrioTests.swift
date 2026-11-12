import Foundation
import Testing
import Network
@testable import ApexAgentCore

@Suite("Scheduler Trio Tests (Issue #76)")
struct SchedulerTrioTests {

    private func createTempDirectory(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // MARK: - 1. Exact Cron Tests

    @Test("Exact Cron: registration, next date calculation, and enable/disable toggle")
    func testExactCronRegistrationAndNextDateCalculation() async throws {
        let scheduler = ExactCronScheduler()
        let expr = "0 9 * * 1-5" // Weekdays at 9:00 AM

        let jobId = try await scheduler.register(name: "morning-standup", expression: expr) {
            // real action
        }

        guard let job = await scheduler.job(id: jobId) else {
            Issue.record("Job should be registered")
            return
        }

        #expect(job.name == "morning-standup")
        #expect(job.expression == expr)
        #expect(job.isEnabled == true)
        #expect(job.runCount == 0)
        #expect(job.nextRunDate != nil)

        // Toggle disabled
        await scheduler.setEnabled(false, for: jobId)
        let disabledJob = await scheduler.job(id: jobId)
        #expect(disabledJob?.isEnabled == false)
        #expect(disabledJob?.nextRunDate == nil)

        // Toggle re-enabled
        await scheduler.setEnabled(true, for: jobId)
        let reenabledJob = await scheduler.job(id: jobId)
        #expect(reenabledJob?.isEnabled == true)
        #expect(reenabledJob?.nextRunDate != nil)

        await scheduler.unregister(id: jobId)
        #expect(await scheduler.job(id: jobId) == nil)
    }

    @Test("Exact Cron: execution and no double fire in same minute bucket")
    func testExactCronExecutionAndNoDoubleFireInSameMinute() async throws {
        let scheduler = ExactCronScheduler()
        let expr = "* * * * *" // Every minute

        final class Counter: @unchecked Sendable {
            var value = 0
            let lock = NSLock()
            func inc() {
                lock.lock()
                defer { lock.unlock() }
                value += 1
            }
            func get() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let counter = Counter()

        let jobId = try await scheduler.register(name: "minute-task", expression: expr) {
            counter.inc()
        }

        // Target minute: 2026-11-12 12:00:00 UTC (timestamp 1794484800)
        let targetMinute1 = Date(timeIntervalSince1970: 1794484800)

        // First evaluation: should fire
        let firedCount1 = await scheduler.evaluateDueJobs(at: targetMinute1)
        #expect(firedCount1 == 1)
        #expect(counter.get() == 1)

        // Second evaluation in same minute (e.g. 25 seconds later): should NOT double fire
        let targetMinute1Later = Date(timeIntervalSince1970: 1794484825)
        let firedCountDuplicate = await scheduler.evaluateDueJobs(at: targetMinute1Later)
        #expect(firedCountDuplicate == 0)
        #expect(counter.get() == 1)

        // Third evaluation at next minute (timestamp 1794484860): should fire again
        let targetMinute2 = Date(timeIntervalSince1970: 1794484860)
        let firedCount2 = await scheduler.evaluateDueJobs(at: targetMinute2)
        #expect(firedCount2 == 1)
        #expect(counter.get() == 2)

        let updatedJob = await scheduler.job(id: jobId)
        #expect(updatedJob?.runCount == 2)
        #expect(updatedJob?.lastRunDate == targetMinute2)

        await scheduler.unregister(id: jobId)
    }

    @Test("Exact Cron: manual triggerNow execution updates state")
    func testExactCronManualTriggerNow() async throws {
        let scheduler = ExactCronScheduler()
        final class Flag: @unchecked Sendable {
            var fired = false
            let lock = NSLock()
            func set() { lock.lock(); defer { lock.unlock() }; fired = true }
            func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return fired }
        }
        let flag = Flag()

        let jobId = try await scheduler.register(name: "manual-job", expression: "0 0 * * *") {
            flag.set()
        }

        let fireDate = try await scheduler.triggerNow(id: jobId)
        #expect(flag.isSet())

        let job = await scheduler.job(id: jobId)
        #expect(job?.runCount == 1)
        #expect(job?.lastRunDate != nil)
        #expect(job?.lastRunDate == fireDate)

        await scheduler.unregister(id: jobId)
    }

    // MARK: - 2. Heartbeat Judgement Pass Tests

    @Test("Heartbeat Judgement: parses markdown checklist items and rules accurately")
    func testHeartbeatJudgementPassParsing() async throws {
        let markdown = """
        # Operational Checklist

        - [ ] Command: echo "system healthy"
        - [ ] File exists: /tmp/apex-test.txt
        - [ ] File not exists: /tmp/missing-file.txt
        - [ ] File contains /tmp/apex-test.txt: APEX_OK
        - [ ] Lock not stale: runs/gate.lock.d
        - [ ] Disk free: 5% on /
        - [x] Pre-checked item
        - [!] Previous failed item
        - [-] Skipped item
        """

        let pass = HeartbeatJudgementPass()
        let items = await pass.parseChecklist(from: markdown)

        #expect(items.count == 9)
        #expect(items[0].status == .pending)
        #expect(items[0].title == "Command: echo \"system healthy\"")
        #expect(items[1].title == "File exists: /tmp/apex-test.txt")
        #expect(items[6].status == .passed)
        #expect(items[7].status == .failed)
        #expect(items[8].status == .skipped)
    }

    @Test("Heartbeat Judgement: executes full pass, updates file in place, and writes receipts")
    func testHeartbeatJudgementPassExecutionAndReceiptEmission() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-judgement-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleFile = tempDir.appendingPathComponent("data.txt")
        try "APEX_PAYLOAD_VERIFIED".write(to: sampleFile, atomically: true, encoding: .utf8)

        let checklistURL = tempDir.appendingPathComponent("checklist.md")
        let initialMarkdown = """
        # Verification Checklist

        - [ ] Command: /bin/echo "all good"
        - [ ] File exists: \(sampleFile.path)
        - [ ] File contains \(sampleFile.path): APEX_PAYLOAD_VERIFIED
        - [ ] Command: exit 0
        """
        try initialMarkdown.write(to: checklistURL, atomically: true, encoding: .utf8)

        let pass = HeartbeatJudgementPass()
        let report = try await pass.runPass(checklistURL: checklistURL, updateInPlace: true)

        #expect(report.overallPassed == true)
        #expect(report.totalItems == 4)
        #expect(report.passedCount == 4)
        #expect(report.failedCount == 0)

        // Verify updated file on disk
        let updatedContent = try String(contentsOf: checklistURL, encoding: .utf8)
        #expect(!updatedContent.contains("- [ ]"))
        #expect(updatedContent.contains("- [x] Command: /bin/echo \"all good\""))
        #expect(updatedContent.contains("<!-- judged: PASSED"))

        // Verify json and md receipt files exist and are valid
        let jsonReceipt = tempDir.appendingPathComponent("checklist.judgement.json")
        let mdReceipt = tempDir.appendingPathComponent("checklist.judgement.md")
        #expect(FileManager.default.fileExists(atPath: jsonReceipt.path))
        #expect(FileManager.default.fileExists(atPath: mdReceipt.path))

        let jsonData = try Data(contentsOf: jsonReceipt)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(JudgementPassReport.self, from: jsonData)
        #expect(decoded.passedCount == 4)
        #expect(decoded.overallPassed == true)
    }

    @Test("Heartbeat Judgement: accurately catches and records failing items")
    func testHeartbeatJudgementPassFailingRuleDetection() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-judgement-fail")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let checklistURL = tempDir.appendingPathComponent("checklist.md")
        let initialMarkdown = """
        # Failure Check

        - [ ] Command: /bin/sh -c "exit 42"
        """
        try initialMarkdown.write(to: checklistURL, atomically: true, encoding: .utf8)

        let pass = HeartbeatJudgementPass()
        let report = try await pass.runPass(checklistURL: checklistURL, updateInPlace: true)

        #expect(report.overallPassed == false)
        #expect(report.failedCount == 1)
        #expect(report.passedCount == 0)

        let updatedContent = try String(contentsOf: checklistURL, encoding: .utf8)
        #expect(updatedContent.contains("- [!] Command: /bin/sh -c \"exit 42\""))
        #expect(updatedContent.contains("<!-- judged: FAILED"))
    }

    // MARK: - 3. Event Triggers Tests

    @Test("Event Triggers: FileEventWatcher detects real file system modification")
    func testFileEventTriggerWatcherRealFileSystemEvent() async throws {
        let tempDir = try createTempDirectory(prefix: "apex-file-trigger")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("watch-target.log")
        try "initial".write(to: testFile, atomically: true, encoding: .utf8)

        final class EventBox: @unchecked Sendable {
            var events: [EventTriggerPayload] = []
            let lock = NSLock()
            func add(_ e: EventTriggerPayload) {
                lock.lock()
                defer { lock.unlock() }
                events.append(e)
            }
            func count() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return events.count
            }
        }
        let box = EventBox()

        let coordinator = EventTriggerCoordinator()
        let config = EventTriggerConfig(kind: .file, identifier: "log-watcher", targetPath: testFile.path)
        let triggerId = try await coordinator.register(config: config) { payload in
            box.add(payload)
        }

        try await coordinator.start(id: triggerId)

        // Give the dispatch source a brief moment to initialize
        try await Task.sleep(nanoseconds: 100_000_000)

        // Perform real file modification
        let updateData = "appended-content-\(Date().timeIntervalSince1970)\n".data(using: .utf8)!
        let fileHandle = try FileHandle(forWritingTo: testFile)
        fileHandle.seekToEndOfFile()
        fileHandle.write(updateData)
        try fileHandle.close()

        // Wait up to 2.0s for event
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && box.count() == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        await coordinator.stop(id: triggerId)

        #expect(box.count() >= 1)
        let stats = await coordinator.stats(for: triggerId)
        #expect((stats?.fireCount ?? 0) >= 1)
        #expect(stats?.isLiveVerified == true)
    }

    @Test("Event Triggers: WebhookEventWatcher receives real HTTP POST request")
    func testWebhookEventTriggerWatcherRealHTTPPost() async throws {
        let port: UInt16 = 19482
        let endpoint = "test-webhook"

        final class Box: @unchecked Sendable {
            var receivedPayloads: [EventTriggerPayload] = []
            let lock = NSLock()
            func add(_ p: EventTriggerPayload) {
                lock.lock()
                defer { lock.unlock() }
                receivedPayloads.append(p)
            }
            func count() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return receivedPayloads.count
            }
            func first() -> EventTriggerPayload? {
                lock.lock()
                defer { lock.unlock() }
                return receivedPayloads.first
            }
        }
        let box = Box()

        let coordinator = EventTriggerCoordinator()
        let config = EventTriggerConfig(kind: .webhook, identifier: endpoint, port: port)
        let triggerId = try await coordinator.register(config: config) { payload in
            box.add(payload)
        }

        try await coordinator.start(id: triggerId)

        // Wait for NWListener to bind
        try await Task.sleep(nanoseconds: 200_000_000)

        // Send a real HTTP POST request using URLSession
        let url = URL(string: "http://127.0.0.1:\(port)/webhook/\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = "{\"alert\":\"deploy_complete\",\"version\":\"2.0\"}".data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        #expect(respStr.contains("received"))

        // Verify coordinator received payload
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && box.count() == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        await coordinator.stop(id: triggerId)

        #expect(box.count() >= 1)
        if let payload = box.first() {
            #expect(payload.triggerType == "webhook")
            #expect(payload.identifier == endpoint)
            if let bodyData = payload.dataPayload, let bodyStr = String(data: bodyData, encoding: .utf8) {
                #expect(bodyStr.contains("deploy_complete"))
            }
        }
    }

    @Test("Event Triggers: LANPeerEventWatcher receives real peer TCP frame and sends ACK")
    func testLANPeerEventTriggerWatcherRealTCPSocket() async throws {
        let port: UInt16 = 19483

        final class Box: @unchecked Sendable {
            var payloads: [EventTriggerPayload] = []
            let lock = NSLock()
            func add(_ p: EventTriggerPayload) {
                lock.lock()
                defer { lock.unlock() }
                payloads.append(p)
            }
            func count() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return payloads.count
            }
            func first() -> EventTriggerPayload? {
                lock.lock()
                defer { lock.unlock() }
                return payloads.first
            }
        }
        let box = Box()

        let coordinator = EventTriggerCoordinator()
        let config = EventTriggerConfig(kind: .lanPeer, identifier: "lan-service", port: port)
        let triggerId = try await coordinator.register(config: config) { payload in
            box.add(payload)
        }

        try await coordinator.start(id: triggerId)

        // Wait for NWListener to bind
        try await Task.sleep(nanoseconds: 200_000_000)

        // Connect as real TCP peer client
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let client = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let clientQueue = DispatchQueue(label: "com.apexagent.testClient")
        client.start(queue: clientQueue)

        let sendData = "{\"peer\":\"node-alpha\",\"msg\":\"heartbeat_ack\"}\n".data(using: .utf8)!
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.send(content: sendData, completion: .contentProcessed({ error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }))
        }

        // Wait for ACK
        let ackReceived = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let str = String(data: data, encoding: .utf8), str.contains("acknowledged") {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
        #expect(ackReceived == true)
        client.cancel()

        // Verify coordinator received event
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && box.count() == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        await coordinator.stop(id: triggerId)

        #expect(box.count() >= 1)
        if let payload = box.first() {
            #expect(payload.triggerType == "lanPeer")
            if let data = payload.dataPayload, let str = String(data: data, encoding: .utf8) {
                #expect(str.contains("node-alpha"))
            }
        }
    }

    @Test("Event Triggers: Mail and Calendar triggers configure and register cleanly")
    func testMailAndCalendarTriggerConfigRegistration() async throws {
        let coordinator = EventTriggerCoordinator()

        let mailConfig = EventTriggerConfig(kind: .mail, identifier: "inbox-watcher", pollIntervalSeconds: 5.0)
        let mailId = try await coordinator.register(config: mailConfig) { _ in }

        let calConfig = EventTriggerConfig(kind: .calendar, identifier: "calendar-horizon-watcher")
        let calId = try await coordinator.register(config: calConfig) { _ in }

        let stats = await coordinator.allStats()
        #expect(stats.count == 2)
        #expect(stats.contains { $0.kind == .mail })
        #expect(stats.contains { $0.kind == .calendar })

        await coordinator.unregister(id: mailId)
        await coordinator.unregister(id: calId)
        #expect(await coordinator.allStats().isEmpty)
    }
}
