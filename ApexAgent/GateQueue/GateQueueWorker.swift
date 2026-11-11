import Foundation
import Darwin

/// Information about a recovered stale in-progress job.
public struct StaleJobRecovery: Sendable, Equatable {
    public let projectPath: String
    public let originalFileURL: URL
    public let recoveredFileURL: URL
    public let jobName: String
    public let reportURL: URL
}

/// Actor managing the Gate Queue lifecycle, strict machine-wide serialization,
/// log streaming, sentinel emission, and report generation.
public actor GateQueueWorker {
    public private(set) var registeredProjects: [URL]
    public let lock: GateSlotLock
    public let analyzer: GateLogAnalyzer

    public init(
        registeredProjects: [URL] = [],
        lock: GateSlotLock = GateSlotLock(),
        analyzer: GateLogAnalyzer = GateLogAnalyzer()
    ) {
        self.registeredProjects = registeredProjects
        self.lock = lock
        self.analyzer = analyzer
    }

    /// Registers a project directory for queue polling.
    public func registerProject(at url: URL) {
        let standard = url.standardizedFileURL
        if !registeredProjects.contains(standard) {
            registeredProjects.append(standard)
        }
    }

    /// Unregisters a project directory.
    public func unregisterProject(at url: URL) {
        let standard = url.standardizedFileURL
        registeredProjects.removeAll { $0 == standard }
    }

    // MARK: - Startup & Recovery (§Intake Lifecycle)

    /// Scans registered projects for any stale `.in-progress` jobs from previous interrupted runs.
    /// Emits a recovery report and renames them to `.stale-recovered.json` so they are never silently re-run or dropped.
    @discardableResult
    public func recoverStaleInProgressJobs() -> [StaleJobRecovery] {
        var recoveries: [StaleJobRecovery] = []

        for projectURL in registeredProjects {
            let queueDir = GateJobSpec.queueDirectory(for: projectURL.path)
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: queueDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for item in items {
                let name = item.lastPathComponent
                if name.contains(".in-progress") {
                    let baseName = name
                        .replacingOccurrences(of: ".in-progress.json", with: "")
                        .replacingOccurrences(of: ".in-progress", with: "")

                    let recoveredURL = queueDir.appendingPathComponent("\(baseName).stale-recovered.json")
                    let reportURL = queueDir.appendingPathComponent("\(baseName)-stale-recovery.md")

                    // Move to recovered file
                    try? FileManager.default.moveItem(at: item, to: recoveredURL)

                    // Write recovery notification report
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    let nowStr = formatter.string(from: Date())

                    let reportContent = """
                    # Stale In-Progress Gate Job Recovery

                    - **Project:** `\(projectURL.path)`
                    - **Stale Job File:** `\(name)`
                    - **Recovered File:** `\(recoveredURL.lastPathComponent)`
                    - **Detected At:** \(nowStr)

                    ## Status
                    This job was found in an `in-progress` state during worker startup, indicating that a previous worker process or machine crashed or was interrupted while processing this job.

                    Per Worker Semantics, this job has been preserved as `\(recoveredURL.lastPathComponent)` and will **not** be silently re-run or dropped. Manual inspection or resubmission is required.
                    """

                    try? reportContent.write(to: reportURL, atomically: true, encoding: .utf8)

                    recoveries.append(StaleJobRecovery(
                        projectPath: projectURL.path,
                        originalFileURL: item,
                        recoveredFileURL: recoveredURL,
                        jobName: baseName,
                        reportURL: reportURL
                    ))
                }
            }
        }

        return recoveries
    }

    // MARK: - Polling & Queue Inspection

    /// Item in the pending queue.
    public struct PendingQueueItem: Sendable {
        public let fileURL: URL
        public let spec: GateJobSpec
        public let fileCreationDate: Date
    }

    /// Finds all pending jobs across registered projects, ordered strictly by submission timestamp.
    public func findPendingJobs() -> [PendingQueueItem] {
        var pending: [PendingQueueItem] = []

        for projectURL in registeredProjects {
            let queueDir = GateJobSpec.queueDirectory(for: projectURL.path)
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: queueDir,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for fileURL in items {
                let name = fileURL.lastPathComponent

                // Pending jobs are .json files that are NOT in-progress, completed, recovered, or reports
                guard name.hasSuffix(".json"),
                      !name.contains(".in-progress"),
                      !name.contains(".completed"),
                      !name.contains(".stale-recovered"),
                      !name.contains(".done") else {
                    continue
                }

                if let data = try? Data(contentsOf: fileURL),
                   let spec = try? GateJobSpec.fromJSONData(data) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let creationDate = (attrs?[.creationDate] as? Date) ?? spec.submittedAt
                    pending.append(PendingQueueItem(
                        fileURL: fileURL,
                        spec: spec,
                        fileCreationDate: creationDate
                    ))
                }
            }
        }

        // Strictly order by submittedAt / creationDate (FIFO queue)
        return pending.sorted {
            if $0.spec.submittedAt != $1.spec.submittedAt {
                return $0.spec.submittedAt < $1.spec.submittedAt
            }
            return $0.fileCreationDate < $1.fileCreationDate
        }
    }

    /// Claims a pending job atomically by renaming its file to `.in-progress.json`.
    /// Returns the new in-progress file URL, or nil if claiming failed (e.g. another worker claimed it).
    public func claim(pendingItem: PendingQueueItem) -> URL? {
        let sourceURL = pendingItem.fileURL
        let queueDir = sourceURL.deletingLastPathComponent()
        let filename = sourceURL.deletingPathExtension().lastPathComponent
        let inProgressURL = queueDir.appendingPathComponent("\(filename).in-progress.json")

        do {
            try FileManager.default.moveItem(at: sourceURL, to: inProgressURL)
            return inProgressURL
        } catch {
            return nil
        }
    }

    // MARK: - Job Execution (§Worker Semantics 1–4)

    /// Executes a claimed job under the gate lock, streaming log output, writing sentinel and report.
    /// If slot is busy, waits until slot becomes free.
    public func executeJob(
        spec: GateJobSpec,
        inProgressURL: URL,
        lockWaitTimeout: TimeInterval? = nil
    ) async throws -> GateJobReport {
        let queueDir = inProgressURL.deletingLastPathComponent()
        let targetURL = URL(fileURLWithPath: spec.targetProject, isDirectory: true)

        // Generate timestamp string formatted: yyyymmdd-hhmmss
        let dateUtcFormatter = DateFormatter()
        dateUtcFormatter.dateFormat = "yyyyMMdd-HHmmss"
        dateUtcFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let timestampSegment = dateUtcFormatter.string(from: Date())

        let sanitizedJobName = spec.jobName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let baseFilePrefix = "\(sanitizedJobName)-\(timestampSegment)"

        let logFileURL = queueDir.appendingPathComponent("\(baseFilePrefix).log")
        let sentinelFileURL = queueDir.appendingPathComponent("\(baseFilePrefix).log.done")
        let reportFileURL = queueDir.appendingPathComponent("\(baseFilePrefix)-report.md")

        // 1. Strict serialization via GateSlotLock: wait-instead-of-stop
        let ownerTag = "gate-queue-worker-\(spec.jobName)-\(spec.id.prefix(8))"
        try await lock.acquire(owner: ownerTag, maxWaitTime: lockWaitTimeout)

        var processExitCode: Int32 = 1
        let startTime = Date()

        do {
            // 2. Prepare log file
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            guard let logHandle = FileHandle(forWritingAtPath: logFileURL.path) else {
                throw NSError(domain: "GateQueueWorker", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create write handle for log at \(logFileURL.path)"
                ])
            }

            // 3. Execution without shell interpolation
            let process = Process()
            process.currentDirectoryURL = targetURL

            guard !spec.gateCommand.isEmpty else {
                throw NSError(domain: "GateQueueWorker", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "gateCommand is empty"
                ])
            }

            let executable = spec.gateCommand[0]
            if executable.hasPrefix("/") || executable.hasPrefix("./") || executable.hasPrefix("../") {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = Array(spec.gateCommand.dropFirst())
            } else {
                // Use /usr/bin/env to resolve executable in PATH without shell interpolation
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = spec.gateCommand
            }

            process.standardOutput = logHandle
            process.standardError = logHandle

            try process.run()
            process.waitUntilExit()

            processExitCode = process.terminationStatus
            try? logHandle.close()
        } catch {
            lock.release()
            throw error
        }

        let duration = Date().timeIntervalSince(startTime)
        let completedAt = Date()

        // Write sibling .done sentinel: "<exit code> <UTC timestamp>\n"
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let sentinelText = "\(processExitCode) \(isoFormatter.string(from: completedAt))\n"
        try? sentinelText.data(using: .utf8)?.write(to: sentinelFileURL, options: .atomic)

        // Load baseline if provided
        var baseline: GateBaseline? = nil
        if let baselinePath = spec.baselineFile, !baselinePath.isEmpty {
            let baselineURL: URL
            if baselinePath.hasPrefix("/") {
                baselineURL = URL(fileURLWithPath: baselinePath)
            } else {
                baselineURL = targetURL.appendingPathComponent(baselinePath)
            }
            baseline = try? GateBaseline.load(from: baselineURL)
        }

        // 3. Report generation
        let logData = (try? Data(contentsOf: logFileURL)) ?? Data()
        let logString = String(data: logData, encoding: .utf8) ?? ""
        let analysis = analyzer.analyze(log: logString, baseline: baseline)

        let report = GateJobReport(
            jobSpec: spec,
            exitCode: processExitCode,
            duration: duration,
            logFileURL: logFileURL,
            sentinelFileURL: sentinelFileURL,
            reportFileURL: reportFileURL,
            completedAt: completedAt,
            analysis: analysis
        )
        try? report.writeReport()

        // 4. Mark job completed
        let filename = inProgressURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".in-progress", with: "")
        let completedURL = queueDir.appendingPathComponent("\(filename).completed.json")
        try? FileManager.default.moveItem(at: inProgressURL, to: completedURL)

        // Release the machine-wide gate lock
        lock.release()

        return report
    }

    /// Processes the next pending job across registered projects.
    /// Returns the report if a job was found and executed, or nil if the queue was empty.
    public func processNextPendingJob(lockWaitTimeout: TimeInterval? = nil) async throws -> GateJobReport? {
        let pending = findPendingJobs()
        guard let nextItem = pending.first else {
            return nil
        }

        guard let inProgressURL = claim(pendingItem: nextItem) else {
            // If claiming failed, another worker or thread claimed it
            return nil
        }

        return try await executeJob(
            spec: nextItem.spec,
            inProgressURL: inProgressURL,
            lockWaitTimeout: lockWaitTimeout
        )
    }

    /// Drains all currently pending jobs one by one in strict submission order.
    public func drainQueue(lockWaitTimeout: TimeInterval? = nil) async throws -> [GateJobReport] {
        var reports: [GateJobReport] = []
        while let report = try await processNextPendingJob(lockWaitTimeout: lockWaitTimeout) {
            reports.append(report)
        }
        return reports
    }

    /// Runs the polling loop on a specified interval until stopped.
    public func runPollLoop(
        intervalSeconds: TimeInterval = 60,
        stopCondition: @Sendable () -> Bool
    ) async throws -> [GateJobReport] {
        var allReports: [GateJobReport] = []
        _ = recoverStaleInProgressJobs()

        while !stopCondition() {
            let reports = try await drainQueue()
            allReports.append(contentsOf: reports)

            if stopCondition() { break }

            let sleepNanos = UInt64(intervalSeconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: sleepNanos)
        }

        return allReports
    }
}
