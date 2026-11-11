import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Gate Queue Worker Tests (Issue #138)")
struct GateQueueWorkerTests {

    private func createTempDirectory(prefix: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    @Test("Strict serialization: two jobs submitted together execute in submission order without concurrency")
    func testSerializationOrder() async throws {
        let projectDir = try createTempDirectory(prefix: "apex-test-project")
        let lockDir = try createTempDirectory(prefix: "apex-test-lock").appendingPathComponent("gate.lock.d")
        defer {
            try? FileManager.default.removeItem(at: projectDir)
            try? FileManager.default.removeItem(at: lockDir.deletingLastPathComponent())
        }

        let lock = GateSlotLock(lockDirectoryURL: lockDir, staleTimeout: 3600, pollInterval: 0.05)
        let worker = GateQueueWorker(registeredProjects: [projectDir], lock: lock)

        // Script for Job 1: outputs start marker, sleeps 0.2s, outputs end marker
        let job1Cmd = [
            "/bin/sh", "-c",
            "date +%s%N; sleep 0.2; date +%s%N"
        ]
        let job1 = GateJobSpec(
            jobName: "job1",
            targetProject: projectDir.path,
            gateCommand: job1Cmd,
            submittedAt: Date(timeIntervalSince1970: 1000)
        )
        try job1.submit()

        // Script for Job 2: outputs start marker, sleeps 0.2s, outputs end marker
        let job2Cmd = [
            "/bin/sh", "-c",
            "date +%s%N; sleep 0.2; date +%s%N"
        ]
        let job2 = GateJobSpec(
            jobName: "job2",
            targetProject: projectDir.path,
            gateCommand: job2Cmd,
            submittedAt: Date(timeIntervalSince1970: 2000) // Submitted after job1
        )
        try job2.submit()

        // Drain the queue
        let reports = try await worker.drainQueue(lockWaitTimeout: 10)
        #expect(reports.count == 2)
        #expect(reports[0].jobSpec.jobName == "job1")
        #expect(reports[1].jobSpec.jobName == "job2")

        // Read log outputs to verify non-concurrency and strict order
        let log1 = try String(contentsOf: reports[0].logFileURL, encoding: .utf8)
        let log2 = try String(contentsOf: reports[1].logFileURL, encoding: .utf8)

        let lines1 = log1.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        let lines2 = log2.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)

        #expect(lines1.count >= 2)
        #expect(lines2.count >= 2)

        if let end1 = Int64(lines1[1]), let start2 = Int64(lines2[0]) {
            // Proves Job 1 finished BEFORE Job 2 started (strict serialization, zero overlap)
            #expect(end1 <= start2)
        }
    }

    @Test("Wait behavior: a job submitted while a slot is held waits and executes upon release")
    func testWaitBehavior() async throws {
        let projectDir = try createTempDirectory(prefix: "apex-wait-project")
        let lockDir = try createTempDirectory(prefix: "apex-wait-lock").appendingPathComponent("gate.lock.d")
        defer {
            try? FileManager.default.removeItem(at: projectDir)
            try? FileManager.default.removeItem(at: lockDir.deletingLastPathComponent())
        }

        let lock = GateSlotLock(lockDirectoryURL: lockDir, staleTimeout: 3600, pollInterval: 0.05)
        let worker = GateQueueWorker(registeredProjects: [projectDir], lock: lock)

        // Hold the lock in a background task for 0.4 seconds
        let holderLock = GateSlotLock(lockDirectoryURL: lockDir, staleTimeout: 3600, pollInterval: 0.05)
        let holderTask = Task.detached {
            try await holderLock.acquire(owner: "synthetic-holder")
            try await Task.sleep(nanoseconds: 400_000_000) // 0.4s
            holderLock.release()
        }

        // Wait slightly so holder definitely creates the lock
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(lock.isLocked)

        let spec = GateJobSpec(
            jobName: "waited-job",
            targetProject: projectDir.path,
            gateCommand: ["/bin/echo", "waited-job-finished"]
        )
        try spec.submit()

        // Execute job with wait-instead-of-stop
        let report = try await worker.processNextPendingJob(lockWaitTimeout: 5.0)
        _ = try await holderTask.value

        #expect(report != nil)
        #expect(report?.exitCode == 0)
        #expect(report?.jobSpec.jobName == "waited-job")

        let logContent = try String(contentsOf: report!.logFileURL, encoding: .utf8)
        #expect(logContent.contains("waited-job-finished"))
    }

    @Test("Sentinel and report shape: passing and failing jobs produce valid logs, .done sentinels, and reports without blocking the queue")
    func testSentinelAndReportShape() async throws {
        let projectDir = try createTempDirectory(prefix: "apex-shape-project")
        let lockDir = try createTempDirectory(prefix: "apex-shape-lock").appendingPathComponent("gate.lock.d")
        defer {
            try? FileManager.default.removeItem(at: projectDir)
            try? FileManager.default.removeItem(at: lockDir.deletingLastPathComponent())
        }

        let lock = GateSlotLock(lockDirectoryURL: lockDir, staleTimeout: 3600, pollInterval: 0.05)
        let worker = GateQueueWorker(registeredProjects: [projectDir], lock: lock)

        // 1. Passing Job
        let passCmd = [
            "/bin/sh", "-c",
            "echo '10 total / 10 passed / 0 failed / 0 skipped'; exit 0"
        ]
        let passSpec = GateJobSpec(
            jobName: "passing-gate",
            targetProject: projectDir.path,
            gateCommand: passCmd,
            submittedAt: Date(timeIntervalSince1970: 100)
        )
        try passSpec.submit()

        // 2. Failing Job
        let failCmd = [
            "/bin/sh", "-c",
            "echo 'error: test failed'; echo '10 total / 8 passed / 2 failed / 0 skipped'; exit 2"
        ]
        let failSpec = GateJobSpec(
            jobName: "failing-gate",
            targetProject: projectDir.path,
            gateCommand: failCmd,
            submittedAt: Date(timeIntervalSince1970: 200)
        )
        try failSpec.submit()

        // 3. Subsequent Passing Job (must not be blocked by failing job!)
        let nextCmd = [
            "/bin/sh", "-c",
            "echo '5 total / 5 passed / 0 failed / 0 skipped'; exit 0"
        ]
        let nextSpec = GateJobSpec(
            jobName: "subsequent-gate",
            targetProject: projectDir.path,
            gateCommand: nextCmd,
            submittedAt: Date(timeIntervalSince1970: 300)
        )
        try nextSpec.submit()

        let reports = try await worker.drainQueue(lockWaitTimeout: 10)
        #expect(reports.count == 3)

        // Check passing job
        let rep1 = reports[0]
        #expect(rep1.exitCode == 0)
        #expect(rep1.analysis.totals?.total == 10)
        #expect(rep1.analysis.totals?.passed == 10)
        #expect(rep1.analysis.totals?.failed == 0)

        let sentinel1 = try String(contentsOf: rep1.sentinelFileURL, encoding: .utf8)
        #expect(sentinel1.hasPrefix("0 "))
        #expect(sentinel1.contains("T") && sentinel1.contains("Z"))

        let rep1Markdown = try String(contentsOf: rep1.reportFileURL, encoding: .utf8)
        #expect(rep1Markdown.contains("Exit Code:** `0` (PASS)"))
        #expect(rep1Markdown.contains("Total Tests | 10"))

        // Check failing job
        let rep2 = reports[1]
        #expect(rep2.exitCode == 2)
        #expect(rep2.analysis.totals?.total == 10)
        #expect(rep2.analysis.totals?.passed == 8)
        #expect(rep2.analysis.totals?.failed == 2)

        let sentinel2 = try String(contentsOf: rep2.sentinelFileURL, encoding: .utf8)
        #expect(sentinel2.hasPrefix("2 "))

        let rep2Markdown = try String(contentsOf: rep2.reportFileURL, encoding: .utf8)
        #expect(rep2Markdown.contains("Exit Code:** `2` (FAIL)"))
        #expect(rep2Markdown.contains("NEW Alerts (Action Required)"))

        // Check subsequent job ran successfully (not blocked by failure)
        let rep3 = reports[2]
        #expect(rep3.exitCode == 0)
        #expect(rep3.analysis.totals?.total == 5)
        #expect(rep3.jobSpec.jobName == "subsequent-gate")
    }

    @Test("Crash recovery: stale in-progress jobs are discovered, reported, and preserved without re-running")
    func testStaleInProgressRecovery() async throws {
        let projectDir = try createTempDirectory(prefix: "apex-stale-project")
        let queueDir = GateJobSpec.queueDirectory(for: projectDir.path)
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: projectDir)
        }

        // Simulate a crashed worker leaving an in-progress file
        let staleFileURL = queueDir.appendingPathComponent("crashed-job.in-progress.json")
        let dummySpec = GateJobSpec(
            jobName: "crashed-job",
            targetProject: projectDir.path,
            gateCommand: ["/bin/echo", "crashed"]
        )
        try (try dummySpec.toJSONData()).write(to: staleFileURL)

        let worker = GateQueueWorker(registeredProjects: [projectDir])
        let recoveries = await worker.recoverStaleInProgressJobs()

        #expect(recoveries.count == 1)
        #expect(recoveries[0].jobName == "crashed-job")
        #expect(FileManager.default.fileExists(atPath: recoveries[0].recoveredFileURL.path))
        #expect(FileManager.default.fileExists(atPath: recoveries[0].reportURL.path))
        #expect(!FileManager.default.fileExists(atPath: staleFileURL.path))

        // Ensure pending jobs count is zero (not silently re-queued)
        let pending = await worker.findPendingJobs()
        #expect(pending.isEmpty)
    }

    @Test("Baseline alert classification: known noise matches baseline-known while novel warnings and errors are surfaced as NEW")
    func testBaselineAlertClassification() async throws {
        let projectDir = try createTempDirectory(prefix: "apex-baseline-project")
        let lockDir = try createTempDirectory(prefix: "apex-baseline-lock").appendingPathComponent("gate.lock.d")
        defer {
            try? FileManager.default.removeItem(at: projectDir)
            try? FileManager.default.removeItem(at: lockDir.deletingLastPathComponent())
        }

        // Write baseline file
        let baselineContent = """
        # Gate Baseline
        1893 total / 1878 passed / 0 failed / 15 skipped

        ## Known Noise
        - redundant conformance of 'SpaceModel' to protocol 'Sendable'
        """
        let baselineURL = projectDir.appendingPathComponent("baseline.md")
        try baselineContent.write(to: baselineURL, atomically: true, encoding: .utf8)

        let lock = GateSlotLock(lockDirectoryURL: lockDir, staleTimeout: 3600, pollInterval: 0.05)
        let worker = GateQueueWorker(registeredProjects: [projectDir], lock: lock)

        // Gate command that outputs known noise warning, new warning, and an error
        let testCmd = [
            "/bin/sh", "-c",
            """
            echo "warning: redundant conformance of 'SpaceModel' to protocol 'Sendable'"
            echo "warning: unused variable 'unhandledToken'"
            echo "error: symbol not found in flat namespace"
            echo "1893 total / 1878 passed / 0 failed / 15 skipped"
            exit 0
            """
        ]

        let spec = GateJobSpec(
            jobName: "baseline-classification-test",
            targetProject: projectDir.path,
            gateCommand: testCmd,
            baselineFile: baselineURL.path
        )
        try spec.submit()

        let report = try await worker.processNextPendingJob(lockWaitTimeout: 10)
        #expect(report != nil)

        let analysis = report!.analysis
        #expect(analysis.totals?.total == 1893)
        #expect(analysis.totals?.passed == 1878)

        // Warnings count
        let warningCounts = analysis.countsByCategory[.warning]
        #expect(warningCounts?.total == 2)
        #expect(warningCounts?.baselineKnown == 1) // redundant conformance
        #expect(warningCounts?.newAlerts == 1)     // unhandledToken

        // Errors count
        let errorCounts = analysis.countsByCategory[.error]
        #expect(errorCounts?.total == 1)
        #expect(errorCounts?.baselineKnown == 0)
        #expect(errorCounts?.newAlerts == 1)       // symbol not found

        // Report markdown check
        let md = try String(contentsOf: report!.reportFileURL, encoding: .utf8)
        #expect(md.contains("warning: unused variable 'unhandledToken'"))
        #expect(md.contains("error: symbol not found in flat namespace"))
        #expect(md.contains("redundant conformance of 'SpaceModel'"))
    }

    @Test("Direct argv execution: preserves special characters without shell interpolation")
    func testDirectArgvExecutionNoShellInterpolation() async throws {
        let projectDir = try createTempDirectory(prefix: "apex-argv-project")
        let lockDir = try createTempDirectory(prefix: "apex-argv-lock").appendingPathComponent("gate.lock.d")
        defer {
            try? FileManager.default.removeItem(at: projectDir)
            try? FileManager.default.removeItem(at: lockDir.deletingLastPathComponent())
        }

        let lock = GateSlotLock(lockDirectoryURL: lockDir, staleTimeout: 3600, pollInterval: 0.05)
        let worker = GateQueueWorker(registeredProjects: [projectDir], lock: lock)

        let literalArg = "literal $VAR; echo 'injected'; && || \n\t tab"
        let spec = GateJobSpec(
            jobName: "argv-test",
            targetProject: projectDir.path,
            gateCommand: ["/bin/echo", literalArg]
        )
        try spec.submit()

        let report = try await worker.processNextPendingJob(lockWaitTimeout: 10)
        #expect(report != nil)

        let logContent = try String(contentsOf: report!.logFileURL, encoding: .utf8)
        #expect(logContent.contains(literalArg))
    }
}
