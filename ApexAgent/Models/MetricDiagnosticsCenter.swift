import Foundation
import MetricKit

// MARK: - MetricKit Field Diagnostics Center (Batch 22)

/// Classification of a field observation captured from MetricKit.
public enum FieldDiagnosticKind: String, Codable, CaseIterable, Sendable {
    case crash
    case hang
    case cpuException
    case diskWriteException
    case appLaunch
    case dailyMetric
}

/// One captured field observation from MetricKit: a diagnostic report (crash,
/// hang, CPU exception, disk-write exception, or launch diagnostic) or a daily
/// metric report summary. Stored as a JSON array with atomic writes so a
/// partially-written file can never be observed by diagnostics.
public struct MetricDiagnosticPayload: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let occurredAt: Date
    public let kind: FieldDiagnosticKind
    public let terminationCategory: String?
    public let signal: Int?
    public let exceptionCode: UInt64?
    public let hangDurationSeconds: Double?
    public let cpuTimeSeconds: Double?
    public let diskBytesWritten: Int64?
    public let bundleIdentifier: String?
    public let applicationBuildVersion: String?
    public let osVersion: String?
    public let stateEntries: Int
    public let intervalEntries: Int

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        kind: FieldDiagnosticKind,
        terminationCategory: String? = nil,
        signal: Int? = nil,
        exceptionCode: UInt64? = nil,
        hangDurationSeconds: Double? = nil,
        cpuTimeSeconds: Double? = nil,
        diskBytesWritten: Int64? = nil,
        bundleIdentifier: String? = nil,
        applicationBuildVersion: String? = nil,
        osVersion: String? = nil,
        stateEntries: Int = 0,
        intervalEntries: Int = 0
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.terminationCategory = terminationCategory
        self.signal = signal
        self.exceptionCode = exceptionCode
        self.hangDurationSeconds = hangDurationSeconds
        self.cpuTimeSeconds = cpuTimeSeconds
        self.diskBytesWritten = diskBytesWritten
        self.bundleIdentifier = bundleIdentifier
        self.applicationBuildVersion = applicationBuildVersion
        self.osVersion = osVersion
        self.stateEntries = stateEntries
        self.intervalEntries = intervalEntries
    }

    /// Converts a macOS 27 `MetricKit.DiagnosticReport` into a persistable record.
    public static func from(diagnosticReport report: DiagnosticReport) -> MetricDiagnosticPayload {
        let env = report.environment
        let osString = "\(env.osVersion.platform) \(env.osVersion.number) (\(env.osVersion.buildNumber))"
        let timestamp = report.timeRange.end

        switch report.result {
        case .crash(let crash):
            return MetricDiagnosticPayload(
                occurredAt: timestamp,
                kind: .crash,
                terminationCategory: crash.terminationCategory?.rawValue,
                signal: crash.signal,
                exceptionCode: crash.exceptionCode,
                bundleIdentifier: env.bundleIdentifier,
                applicationBuildVersion: env.applicationBuildVersion,
                osVersion: osString,
                stateEntries: env.states.count
            )
        case .hang(let hang):
            return MetricDiagnosticPayload(
                occurredAt: timestamp,
                kind: .hang,
                hangDurationSeconds: hang.hangDuration.converted(to: .seconds).value,
                bundleIdentifier: env.bundleIdentifier,
                applicationBuildVersion: env.applicationBuildVersion,
                osVersion: osString,
                stateEntries: env.states.count
            )
        case .cpuException(let cpu):
            return MetricDiagnosticPayload(
                occurredAt: timestamp,
                kind: .cpuException,
                cpuTimeSeconds: cpu.totalCPUTime.converted(to: .seconds).value,
                bundleIdentifier: env.bundleIdentifier,
                applicationBuildVersion: env.applicationBuildVersion,
                osVersion: osString,
                stateEntries: env.states.count
            )
        case .diskWriteException(let disk):
            let bytes = Int64(disk.totalBytesWritten.converted(to: .bytes).value.rounded())
            return MetricDiagnosticPayload(
                occurredAt: timestamp,
                kind: .diskWriteException,
                diskBytesWritten: bytes,
                bundleIdentifier: env.bundleIdentifier,
                applicationBuildVersion: env.applicationBuildVersion,
                osVersion: osString,
                stateEntries: env.states.count
            )
        case .appLaunch(let launch):
            return MetricDiagnosticPayload(
                occurredAt: timestamp,
                kind: .appLaunch,
                hangDurationSeconds: launch.launchDuration.converted(to: .seconds).value,
                bundleIdentifier: env.bundleIdentifier,
                applicationBuildVersion: env.applicationBuildVersion,
                osVersion: osString,
                stateEntries: env.states.count
            )
        @unknown default:
            return MetricDiagnosticPayload(
                occurredAt: timestamp,
                kind: .dailyMetric,
                bundleIdentifier: env.bundleIdentifier,
                applicationBuildVersion: env.applicationBuildVersion,
                osVersion: osString,
                stateEntries: env.states.count
            )
        }
    }

    /// Converts a macOS 27 `MetricKit.MetricReport` into a persistable daily summary record.
    public static func from(metricReport report: MetricReport) -> MetricDiagnosticPayload {
        let env = report.environment
        let osString = env.map { "\($0.osVersion.platform) \($0.osVersion.number) (\($0.osVersion.buildNumber))" }
        var cpuSeconds: Double?
        var diskBytes: Int64?

        for entry in report.intervalEntries {
            for value in entry.values {
                switch value {
                case .cpuTime(let cpu):
                    cpuSeconds = (cpuSeconds ?? 0) + cpu.value.converted(to: .seconds).value
                case .logicalDiskWrites(let writes):
                    let bytes = Int64(writes.value.converted(to: .bytes).value.rounded())
                    diskBytes = (diskBytes ?? 0) + bytes
                default:
                    break
                }
            }
        }

        return MetricDiagnosticPayload(
            occurredAt: report.timeRange.end,
            kind: .dailyMetric,
            cpuTimeSeconds: cpuSeconds,
            diskBytesWritten: diskBytes,
            bundleIdentifier: env?.bundleIdentifier,
            applicationBuildVersion: env?.applicationBuildVersion,
            osVersion: osString,
            stateEntries: report.stateEntries.count,
            intervalEntries: report.intervalEntries.count
        )
    }

    /// Extracts persistable records from an `MXDiagnosticPayload` (Objective-C subscriber path).
    public static func from(mxDiagnosticPayload payload: MXDiagnosticPayload) -> [MetricDiagnosticPayload] {
        var results: [MetricDiagnosticPayload] = []
        let timestamp = (payload.value(forKey: "timeStampEnd") as? Date) ?? Date()

        if let crashes = payload.crashDiagnostics {
            for crash in crashes {
                let meta = crash.value(forKey: "metaData") as? MXMetaData
                results.append(MetricDiagnosticPayload(
                    occurredAt: timestamp,
                    kind: .crash,
                    terminationCategory: crash.terminationReason,
                    signal: crash.signal?.intValue,
                    exceptionCode: crash.exceptionCode?.uint64Value,
                    applicationBuildVersion: meta?.value(forKey: "applicationBuildVersion") as? String,
                    osVersion: meta?.value(forKey: "osVersion") as? String
                ))
            }
        }
        if let hangs = payload.hangDiagnostics {
            for hang in hangs {
                let meta = hang.value(forKey: "metaData") as? MXMetaData
                let hangDur = (hang.value(forKey: "hangDuration") as? Measurement<UnitDuration>)?.converted(to: .seconds).value
                results.append(MetricDiagnosticPayload(
                    occurredAt: timestamp,
                    kind: .hang,
                    hangDurationSeconds: hangDur,
                    applicationBuildVersion: meta?.value(forKey: "applicationBuildVersion") as? String,
                    osVersion: meta?.value(forKey: "osVersion") as? String
                ))
            }
        }
        if let cpuExceptions = payload.cpuExceptionDiagnostics {
            for cpu in cpuExceptions {
                let meta = cpu.value(forKey: "metaData") as? MXMetaData
                let cpuDur = (cpu.value(forKey: "totalCPUTime") as? Measurement<UnitDuration>)?.converted(to: .seconds).value
                results.append(MetricDiagnosticPayload(
                    occurredAt: timestamp,
                    kind: .cpuException,
                    cpuTimeSeconds: cpuDur,
                    applicationBuildVersion: meta?.value(forKey: "applicationBuildVersion") as? String,
                    osVersion: meta?.value(forKey: "osVersion") as? String
                ))
            }
        }
        if let diskExceptions = payload.diskWriteExceptionDiagnostics {
            for disk in diskExceptions {
                let meta = disk.value(forKey: "metaData") as? MXMetaData
                let bytes = (disk.value(forKey: "totalWritesCaused") as? Measurement<UnitInformationStorage>).map {
                    Int64($0.converted(to: .bytes).value.rounded())
                }
                results.append(MetricDiagnosticPayload(
                    occurredAt: timestamp,
                    kind: .diskWriteException,
                    diskBytesWritten: bytes,
                    applicationBuildVersion: meta?.value(forKey: "applicationBuildVersion") as? String,
                    osVersion: meta?.value(forKey: "osVersion") as? String
                ))
            }
        }
        return results
    }

    /// Extracts a persistable daily metric record from an `MXMetricPayload`.
    public static func from(mxMetricPayload payload: MXMetricPayload) -> MetricDiagnosticPayload {
        let timestamp = (payload.value(forKey: "timeStampEnd") as? Date) ?? Date()
        let cpuSeconds = (payload.cpuMetrics?.value(forKey: "cumulativeCPUTime") as? Measurement<UnitDuration>)?.converted(to: .seconds).value
        let diskBytes = (payload.diskIOMetrics?.value(forKey: "cumulativeLogicalWrites") as? Measurement<UnitInformationStorage>).map {
            Int64($0.converted(to: .bytes).value.rounded())
        }
        let meta = payload.metaData
        let buildVer = (meta?.value(forKey: "applicationBuildVersion") as? String)
            ?? (payload.value(forKey: "latestApplicationVersion") as? String)
        let osVer = meta?.value(forKey: "osVersion") as? String
        return MetricDiagnosticPayload(
            occurredAt: timestamp,
            kind: .dailyMetric,
            cpuTimeSeconds: cpuSeconds,
            diskBytesWritten: diskBytes,
            applicationBuildVersion: buildVer,
            osVersion: osVer,
            intervalEntries: 1
        )
    }
}

/// Aggregate field health summary computed over persisted `MetricDiagnosticPayload` entries.
public struct FieldHealthSummary: Sendable, Equatable {
    public let totalPayloads: Int
    public let crashCount: Int
    public let hangCount: Int
    public let cpuExceptionCount: Int
    public let diskWriteExceptionCount: Int
    public let dailyMetricCount: Int
    public let maxHangDurationSeconds: Double
    public let totalCPUExceptionSeconds: Double
    public let totalDiskBytesWritten: Int64
    public let status: DiagnosticStatus

    public var headline: String {
        if totalPayloads == 0 {
            return "No field diagnostics recorded yet."
        }
        return "\(crashCount) crash\(crashCount == 1 ? "" : "es"), \(hangCount) hang\(hangCount == 1 ? "" : "s"), \(cpuExceptionCount) CPU, \(diskWriteExceptionCount) disk, \(dailyMetricCount) daily metric\(dailyMetricCount == 1 ? "" : "s")"
    }

    public static func compute(from payloads: [MetricDiagnosticPayload]) -> FieldHealthSummary {
        var crashes = 0
        var hangs = 0
        var cpuCount = 0
        var diskCount = 0
        var dailyCount = 0
        var maxHang: Double = 0
        var totalCPU: Double = 0
        var totalDisk: Int64 = 0

        for item in payloads {
            switch item.kind {
            case .crash:
                crashes += 1
            case .hang:
                hangs += 1
                if let dur = item.hangDurationSeconds, dur > maxHang {
                    maxHang = dur
                }
            case .cpuException:
                cpuCount += 1
                if let cpu = item.cpuTimeSeconds {
                    totalCPU += cpu
                }
            case .diskWriteException:
                diskCount += 1
                if let bytes = item.diskBytesWritten {
                    totalDisk += bytes
                }
            case .appLaunch:
                break
            case .dailyMetric:
                dailyCount += 1
                if let bytes = item.diskBytesWritten {
                    totalDisk += bytes
                }
            }
        }

        let status: DiagnosticStatus
        if crashes > 0 {
            status = .fail
        } else if hangs > 0 || cpuCount > 0 || diskCount > 0 {
            status = .warning
        } else {
            status = .pass
        }

        return FieldHealthSummary(
            totalPayloads: payloads.count,
            crashCount: crashes,
            hangCount: hangs,
            cpuExceptionCount: cpuCount,
            diskWriteExceptionCount: diskCount,
            dailyMetricCount: dailyCount,
            maxHangDurationSeconds: maxHang,
            totalCPUExceptionSeconds: totalCPU,
            totalDiskBytesWritten: totalDisk,
            status: status
        )
    }
}

/// Subscriber and atomic JSON store for MetricKit field diagnostics and daily metrics.
public final class MetricDiagnosticsCenter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = MetricDiagnosticsCenter()

    /// Maximum number of field diagnostic records retained on disk.
    public static let maxEntries = 200

    private let lock = NSLock()
    private let storageURL: URL
    private var entries: [MetricDiagnosticPayload] = []
    private var isStarted = false
    private var streamTasks: [Task<Void, Never>] = []

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = appSupport.appendingPathComponent("ApexAgent", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageURL = dir.appendingPathComponent("metric_diagnostics.json")
        }
        super.init()
        loadFromDisk()
    }

    deinit {
        for task in streamTasks { task.cancel() }
    }

    /// Starts listening to `MXMetricManager` and macOS 27 `MetricManager` streams.
    public func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        MXMetricManager.shared.add(self)
        let manager = MetricManager()
        let diagTask = Task.detached { [weak self] in
            for await report in manager.diagnosticReports {
                self?.record(diagnosticReport: report)
            }
        }
        let metricTask = Task.detached { [weak self] in
            for await report in manager.metricReports {
                self?.record(metricReport: report)
            }
        }
        lock.lock()
        streamTasks = [diagTask, metricTask]
        lock.unlock()
        AppLog.info(.audit, "MetricDiagnosticsCenter subscribed to MetricKit field diagnostics.")
    }

    /// Stops listening to MetricKit streams.
    public func stop() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        isStarted = false
        let tasks = streamTasks
        streamTasks.removeAll()
        lock.unlock()

        for task in tasks { task.cancel() }
        MXMetricManager.shared.remove(self)
    }

    // MARK: - MXMetricManagerSubscriber callbacks

    public func didReceive(_ payloads: [MXMetricPayload]) {
        let converted = payloads.map { MetricDiagnosticPayload.from(mxMetricPayload: $0) }
        append(converted)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let converted = payloads.flatMap { MetricDiagnosticPayload.from(mxDiagnosticPayload: $0) }
        append(converted)
    }

    // MARK: - Direct Recording & JSON Ingestion

    public func record(diagnosticReport: DiagnosticReport) {
        append([MetricDiagnosticPayload.from(diagnosticReport: diagnosticReport)])
    }

    public func record(metricReport: MetricReport) {
        append([MetricDiagnosticPayload.from(metricReport: metricReport)])
    }

    /// Decodes a real `MetricKit.DiagnosticReport` JSON payload and persists it.
    @discardableResult
    public func ingestDiagnosticJSON(_ data: Data) throws -> MetricDiagnosticPayload {
        let report = try JSONDecoder().decode(DiagnosticReport.self, from: data)
        let payload = MetricDiagnosticPayload.from(diagnosticReport: report)
        append([payload])
        return payload
    }

    /// Decodes a real `MetricKit.MetricReport` JSON payload and persists it.
    @discardableResult
    public func ingestMetricJSON(_ data: Data) throws -> MetricDiagnosticPayload {
        let report = try JSONDecoder().decode(MetricReport.self, from: data)
        let payload = MetricDiagnosticPayload.from(metricReport: report)
        append([payload])
        return payload
    }

    public func append(_ newItems: [MetricDiagnosticPayload]) {
        guard !newItems.isEmpty else { return }
        lock.lock()
        entries.append(contentsOf: newItems)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        let snapshot = entries
        lock.unlock()
        saveToDisk(snapshot)
    }

    /// Returns persisted entries ordered newest-first.
    public func recentPayloads(limit: Int? = nil) -> [MetricDiagnosticPayload] {
        lock.lock()
        let snapshot = Array(entries.reversed())
        lock.unlock()
        guard let limit else { return snapshot }
        return Array(snapshot.prefix(max(0, limit)))
    }

    /// Computes the aggregate health summary across all retained payloads.
    public func summary() -> FieldHealthSummary {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return FieldHealthSummary.compute(from: snapshot)
    }

    /// Clears all persisted and in-memory field diagnostic payloads.
    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        saveToDisk([])
    }

    // MARK: - Atomic Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([MetricDiagnosticPayload].self, from: data)
            lock.lock()
            entries = Array(decoded.suffix(Self.maxEntries))
            lock.unlock()
        } catch {
            AppLog.error(.audit, "Failed to load metric diagnostics from disk", error: error)
        }
    }

    private func saveToDisk(_ snapshot: [MetricDiagnosticPayload]) {
        do {
            let dir = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            AppLog.error(.audit, "Failed to save metric diagnostics to disk", error: error)
        }
    }
}
