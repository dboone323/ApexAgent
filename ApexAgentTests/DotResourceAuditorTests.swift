// DotResourceAuditorTests.swift
// Batch 128: Functional tests for DotResourceAuditor process monitor,
// runaway process watchdog, and subprocess reaper.

import XCTest
import Darwin
@testable import ApexAgentCore

final class DotResourceAuditorTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await DotResourceAuditor.shared.resetAll()
    }

    override func tearDown() async throws {
        await DotResourceAuditor.shared.resetAll()
        try await super.tearDown()
    }

    // MARK: - 1. Registration & Tracking

    func testRegisterAndTrackProcess() async {
        let auditor = DotResourceAuditor.shared
        let dummyPid: pid_t = 99999
        let dotId = UUID()

        let initialTracking = await auditor.isTracking(pid: dummyPid)
        XCTAssertFalse(initialTracking)

        await auditor.registerProcess(pid: dummyPid, dotId: dotId)

        let isTracking = await auditor.isTracking(pid: dummyPid)
        XCTAssertTrue(isTracking)
        let trackedPids = await auditor.getTrackedPids()
        XCTAssertTrue(trackedPids.contains(dummyPid))
    }

    // MARK: - 2. Unregister Process

    func testUnregisterProcessStopsTracking() async {
        let auditor = DotResourceAuditor.shared
        let dummyPid: pid_t = 99998
        let dotId = UUID()

        await auditor.registerProcess(pid: dummyPid, dotId: dotId)
        let isTrackingBefore = await auditor.isTracking(pid: dummyPid)
        XCTAssertTrue(isTrackingBefore)

        await auditor.unregisterProcess(pid: dummyPid)
        let isTrackingAfter = await auditor.isTracking(pid: dummyPid)
        XCTAssertFalse(isTrackingAfter)

        let sampled = await auditor.sampleProcess(pid: dummyPid)
        XCTAssertNil(sampled)
    }

    // MARK: - 3. Sample Real Process Active Usage

    func testSampleProcessReturnsActiveUsage() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        let pid = process.processIdentifier

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let auditor = DotResourceAuditor.shared
        let dotId = UUID()
        await auditor.registerProcess(pid: pid, dotId: dotId)

        let usage = await auditor.sampleProcess(pid: pid)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.pid, pid)
        XCTAssertEqual(usage?.dotId, dotId)
        XCTAssertEqual(usage?.isExceeded, false)
        XCTAssertNil(usage?.violationReason)
        XCTAssertGreaterThanOrEqual(usage?.runningDurationSeconds ?? 0, 0)
        XCTAssertGreaterThanOrEqual(usage?.residentMemoryMB ?? 0, 0)
    }

    // MARK: - 4. Duration Violation Exceeded

    func testDurationViolationFlagsExceeded() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        let pid = process.processIdentifier

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let auditor = DotResourceAuditor.shared
        let dotId = UUID()
        let tightLimits = DotResourceLimits(maxExecutionDurationSeconds: 0.001)
        await auditor.registerProcess(pid: pid, dotId: dotId, limits: tightLimits)

        try await Task.sleep(for: .milliseconds(50))

        let usage = await auditor.sampleProcess(pid: pid)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.isExceeded, true)
        XCTAssertTrue(usage?.violationReason?.contains("duration") == true)
    }

    // MARK: - 5. Reap Exceeded Processes Terminating Process

    func testReapExceededProcessesTerminatesProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let auditor = DotResourceAuditor.shared
        let dotId = UUID()
        let tightLimits = DotResourceLimits(maxExecutionDurationSeconds: 0.001)
        await auditor.registerProcess(pid: pid, dotId: dotId, limits: tightLimits)

        try await Task.sleep(for: .milliseconds(50))

        let reaped = await auditor.reapExceededProcesses()
        XCTAssertTrue(reaped.contains(pid))

        let history = await auditor.getReapedHistory()
        XCTAssertTrue(history.contains(pid))

        // Auditor must no longer be tracking the reaped process
        let isStillTracking = await auditor.isTracking(pid: pid)
        XCTAssertFalse(isStillTracking)

        // Process must be terminated
        var isTerminated = false
        for _ in 0..<20 {
            if Darwin.kill(pid, 0) != 0 || !process.isRunning {
                isTerminated = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(isTerminated, "Child process should have been terminated by SIGTERM")
    }

    // MARK: - 6. Reset All Auditor State

    func testResetAllClearsAuditorState() async {
        let auditor = DotResourceAuditor.shared
        let pid1: pid_t = 11111
        let pid2: pid_t = 22222
        let dotId = UUID()

        await auditor.registerProcess(pid: pid1, dotId: dotId)
        await auditor.registerProcess(pid: pid2, dotId: dotId)
        let isTracking1 = await auditor.isTracking(pid: pid1)
        let isTracking2 = await auditor.isTracking(pid: pid2)
        XCTAssertTrue(isTracking1)
        XCTAssertTrue(isTracking2)

        await auditor.resetAll()

        let isTracking1After = await auditor.isTracking(pid: pid1)
        let isTracking2After = await auditor.isTracking(pid: pid2)
        XCTAssertFalse(isTracking1After)
        XCTAssertFalse(isTracking2After)

        let history = await auditor.getReapedHistory()
        XCTAssertTrue(history.isEmpty)
        let tracked = await auditor.getTrackedPids()
        XCTAssertTrue(tracked.isEmpty)
    }

    // MARK: - 7. Memory Budget Violation

    func testMemoryViolationFlagsExceeded() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        let pid = process.processIdentifier

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let auditor = DotResourceAuditor.shared
        let dotId = UUID()
        // Sleep takes ~0.25MB resident memory, set tiny limit of 0.0001 MB
        let tinyMemoryLimit = DotResourceLimits(
            maxResidentMemoryMB: 0.0001,
            maxExecutionDurationSeconds: 120.0
        )
        await auditor.registerProcess(pid: pid, dotId: dotId, limits: tinyMemoryLimit)

        let usage = await auditor.sampleProcess(pid: pid)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.isExceeded, true)
        XCTAssertTrue(usage?.violationReason?.contains("Memory") == true)
    }

    // MARK: - 8. Well-Behaved Process Is Not Reaped

    func testReapWhenNoViolationDoesNotTerminate() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        let pid = process.processIdentifier

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let auditor = DotResourceAuditor.shared
        let dotId = UUID()
        let generousLimits = DotResourceLimits(
            maxCPUPercentage: 99.0,
            maxResidentMemoryMB: 1024.0,
            maxExecutionDurationSeconds: 300.0
        )
        await auditor.registerProcess(pid: pid, dotId: dotId, limits: generousLimits)

        let reaped = await auditor.reapExceededProcesses()
        XCTAssertFalse(reaped.contains(pid))
        XCTAssertTrue(process.isRunning)
        let isStillTracking = await auditor.isTracking(pid: pid)
        XCTAssertTrue(isStillTracking)
    }

    // MARK: - 9. Codable Conformance

    func testCodableConformance() throws {
        let limits = DotResourceLimits(maxCPUPercentage: 75.0, maxResidentMemoryMB: 256.0, maxExecutionDurationSeconds: 60.0)
        let encodedLimits = try JSONEncoder().encode(limits)
        let decodedLimits = try JSONDecoder().decode(DotResourceLimits.self, from: encodedLimits)
        XCTAssertEqual(limits, decodedLimits)

        let usage = DotProcessResourceUsage(
            pid: 1234,
            dotId: UUID(),
            cpuPercentage: 45.2,
            residentMemoryMB: 128.5,
            runningDurationSeconds: 15.0,
            isExceeded: true,
            violationReason: "Max duration exceeded"
        )
        let encodedUsage = try JSONEncoder().encode(usage)
        let decodedUsage = try JSONDecoder().decode(DotProcessResourceUsage.self, from: encodedUsage)
        XCTAssertEqual(usage, decodedUsage)
    }
}
