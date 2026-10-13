// DotResourceAuditor.swift
// Batch 128: Dot background task resource monitor, runaway process
// watchdog, and subprocess reaper enforcing CPU, memory, and duration budgets.

import Foundation
import Darwin

/// Resource limits applied to monitored Dot subprocesses.
public struct DotResourceLimits: Sendable, Codable, Equatable {
    public var maxCPUPercentage: Double
    public var maxResidentMemoryMB: Double
    public var maxExecutionDurationSeconds: TimeInterval

    public init(
        maxCPUPercentage: Double = 90.0,
        maxResidentMemoryMB: Double = 512.0,
        maxExecutionDurationSeconds: TimeInterval = 120.0
    ) {
        self.maxCPUPercentage = maxCPUPercentage
        self.maxResidentMemoryMB = maxResidentMemoryMB
        self.maxExecutionDurationSeconds = maxExecutionDurationSeconds
    }
}

/// Instantaneous resource utilization snapshot for a tracked Dot subprocess.
public struct DotProcessResourceUsage: Sendable, Codable, Equatable {
    public let pid: pid_t
    public let dotId: UUID
    public var cpuPercentage: Double
    public var residentMemoryMB: Double
    public var runningDurationSeconds: TimeInterval
    public var isExceeded: Bool
    public var violationReason: String?

    public init(
        pid: pid_t,
        dotId: UUID,
        cpuPercentage: Double = 0.0,
        residentMemoryMB: Double = 0.0,
        runningDurationSeconds: TimeInterval = 0.0,
        isExceeded: Bool = false,
        violationReason: String? = nil
    ) {
        self.pid = pid
        self.dotId = dotId
        self.cpuPercentage = cpuPercentage
        self.residentMemoryMB = residentMemoryMB
        self.runningDurationSeconds = runningDurationSeconds
        self.isExceeded = isExceeded
        self.violationReason = violationReason
    }
}

/// Actor monitoring child process resource usage and terminating runaway or budget-exceeded subprocesses.
public actor DotResourceAuditor {
    public static let shared = DotResourceAuditor()

    private struct TrackedProcessInfo: Sendable {
        let dotId: UUID
        let startTime: Date
        let limits: DotResourceLimits
    }

    private var trackedProcesses: [pid_t: TrackedProcessInfo] = [:]
    private var reapedPids: [pid_t] = []

    public init() {}

    /// Registers a subprocess PID with its associated Dot identifier and resource constraints.
    public func registerProcess(pid: pid_t, dotId: UUID, limits: DotResourceLimits = DotResourceLimits()) {
        trackedProcesses[pid] = TrackedProcessInfo(dotId: dotId, startTime: Date(), limits: limits)
    }

    /// Unregisters a subprocess PID from active tracking.
    public func unregisterProcess(pid: pid_t) {
        trackedProcesses.removeValue(forKey: pid)
    }

    /// Returns whether the specified PID is currently being monitored.
    public func isTracking(pid: pid_t) -> Bool {
        trackedProcesses[pid] != nil
    }

    /// Samples CPU percentage, resident memory, and runtime duration for a monitored subprocess.
    public func sampleProcess(pid: pid_t) -> DotProcessResourceUsage? {
        guard let info = trackedProcesses[pid] else { return nil }
        let duration = Date().timeIntervalSince(info.startTime)

        var residentMB: Double = 0.0
        var cpuPercent: Double = 0.0

        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size)

        if result == size {
            residentMB = Double(taskInfo.pti_resident_size) / (1024.0 * 1024.0)
            if duration > 0.0001 {
                let totalCPUNanoseconds = Double(taskInfo.pti_total_user + taskInfo.pti_total_system)
                let totalCPUSeconds = totalCPUNanoseconds / 1_000_000_000.0
                cpuPercent = min(100.0, (totalCPUSeconds / duration) * 100.0)
            }
        } else if Darwin.kill(pid, 0) == 0 {
            // Fallback: query via /bin/ps
            if let (psCpu, psRssMB) = sampleViaPs(pid: pid) {
                cpuPercent = psCpu
                residentMB = psRssMB
            }
        }

        var isExceeded = false
        var violationReason: String? = nil

        if duration > info.limits.maxExecutionDurationSeconds {
            isExceeded = true
            violationReason = "Max duration exceeded"
        } else if cpuPercent > info.limits.maxCPUPercentage {
            isExceeded = true
            violationReason = "CPU budget exceeded"
        } else if residentMB > info.limits.maxResidentMemoryMB {
            isExceeded = true
            violationReason = "Memory budget exceeded"
        }

        return DotProcessResourceUsage(
            pid: pid,
            dotId: info.dotId,
            cpuPercentage: cpuPercent,
            residentMemoryMB: residentMB,
            runningDurationSeconds: duration,
            isExceeded: isExceeded,
            violationReason: violationReason
        )
    }

    /// Scans all tracked processes, sends SIGTERM to those exceeding limits, and returns reaped PIDs.
    public func reapExceededProcesses() -> [pid_t] {
        var reapedThisRun: [pid_t] = []
        let pids = Array(trackedProcesses.keys)

        for pid in pids {
            if let usage = sampleProcess(pid: pid), usage.isExceeded {
                Darwin.kill(pid, SIGTERM)
                reapedPids.append(pid)
                trackedProcesses.removeValue(forKey: pid)
                reapedThisRun.append(pid)
            }
        }

        return reapedThisRun
    }

    /// Returns the complete history of PIDs terminated by the reaper.
    public func getReapedHistory() -> [pid_t] {
        reapedPids
    }

    /// Clears all tracked processes and reaped PID history.
    public func resetAll() {
        trackedProcesses.removeAll()
        reapedPids.removeAll()
    }

    /// Returns list of all currently tracked PIDs.
    public func getTrackedPids() -> [pid_t] {
        Array(trackedProcesses.keys)
    }

    // MARK: - Private Helpers

    private func sampleViaPs(pid: pid_t) -> (Double, Double)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "%cpu,rss"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            let lines = output.split(whereSeparator: \.isNewline)
            guard lines.count >= 2 else { return nil }
            let values = lines[1].split(whereSeparator: \.isWhitespace)
            guard values.count >= 2,
                  let cpu = Double(values[0]),
                  let rssKB = Double(values[1]) else { return nil }
            return (cpu, rssKB / 1024.0)
        } catch {
            return nil
        }
    }
}
