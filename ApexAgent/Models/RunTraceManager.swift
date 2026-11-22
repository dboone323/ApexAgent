import Foundation
import os

// MARK: - Run Trace Storage & Retention

public enum RunTraceStorage {
    private static let log = Logger(subsystem: "com.apexagent.app", category: "RunTraceStorage")

    public static func traceDirectory(workspacePath: String? = nil) -> URL {
        if let ws = workspacePath, !ws.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let wsURL = URL(fileURLWithPath: (ws as NSString).expandingTildeInPath)
            return wsURL.appendingPathComponent(".apex/traces", isDirectory: true)
        }
        return ApexAgentStoragePaths.directory("traces")
    }

    public static func traceFileURL(for runId: String, workspacePath: String? = nil) -> URL {
        traceDirectory(workspacePath: workspacePath).appendingPathComponent("\(runId).json")
    }

    public static func saveTrace(_ trace: RunTrace, workspacePath: String? = nil) throws {
        let dir = traceDirectory(workspacePath: workspacePath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = traceFileURL(for: trace.id, workspacePath: workspacePath)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(trace)
        try data.write(to: fileURL, options: .atomic)

        // Also mirror to global standard traces registry so lookup by runId works anywhere
        if workspacePath != nil {
            let globalDir = ApexAgentStoragePaths.directory("traces")
            try? FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
            let globalURL = globalDir.appendingPathComponent("\(trace.id).json")
            try? data.write(to: globalURL, options: .atomic)
        }
    }

    public static func loadTrace(for runId: String, workspacePath: String? = nil) throws -> RunTrace? {
        let fileURL = traceFileURL(for: runId, workspacePath: workspacePath)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try loadTrace(from: fileURL)
        }
        if workspacePath != nil {
            let globalURL = traceFileURL(for: runId, workspacePath: nil)
            if FileManager.default.fileExists(atPath: globalURL.path) {
                return try loadTrace(from: globalURL)
            }
        }
        return nil
    }

    public static func loadTrace(from fileURL: URL) throws -> RunTrace {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RunTrace.self, from: data)
    }

    public static func listTraces(workspacePath: String? = nil, limit: Int = 50) -> [URL] {
        let dir = traceDirectory(workspacePath: workspacePath)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        let sorted = jsonFiles.sorted { u1, u2 in
            let d1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let d2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return d1 > d2
        }
        return Array(sorted.prefix(limit))
    }

    /// Sweeps stale run traces older than maxAgeDays (default: 7 days) as part of retention policy.
    @discardableResult
    public static func sweepExpiredTraces(workspacePath: String? = nil, maxAgeDays: Int = 7) -> (deleted: Int, skipped: Int) {
        let dir = traceDirectory(workspacePath: workspacePath)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        let cutoff = Date().addingTimeInterval(-TimeInterval(maxAgeDays * 24 * 60 * 60))
        var deleted = 0
        var skipped = 0

        for item in items where item.pathExtension == "json" {
            let attrs = try? item.resourceValues(forKeys: [.contentModificationDateKey])
            let modDate = attrs?.contentModificationDate ?? Date.distantPast
            if modDate < cutoff {
                do {
                    try FileManager.default.removeItem(at: item)
                    deleted += 1
                } catch {
                    skipped += 1
                }
            } else {
                skipped += 1
            }
        }
        log.info("Retention sweep: deleted \(deleted) expired traces, kept \(skipped)")
        return (deleted, skipped)
    }
}

// MARK: - Run Trace Context (TaskLocal)

public enum RunTraceContext {
    @TaskLocal public static var current: RunTraceRecorder?
}

// MARK: - Run Trace Recorder

public final class RunTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var trace: RunTrace
    public let workspacePath: String?

    public var runId: String { trace.id }

    public init(trace: RunTrace, workspacePath: String? = nil) {
        self.trace = trace
        self.workspacePath = workspacePath
        try? RunTraceStorage.saveTrace(self.trace, workspacePath: self.workspacePath)
    }

    @discardableResult
    public func appendEvent(_ buildEvent: (Int) -> RunTraceEvent) -> RunTraceEvent {
        lock.lock()
        defer { lock.unlock() }

        let nextSeq = trace.events.count + 1
        let event = buildEvent(nextSeq)
        trace.events.append(event)
        try? RunTraceStorage.saveTrace(trace, workspacePath: workspacePath)

        // Also emit to in-memory TraceBus for unified telemetry view
        TraceBus.shared.append(TraceEvent(
            source: "RunTrace",
            operation: event.kind.rawValue,
            detail: event.eventDescription
        ))

        return event
    }

    public func finish(status: String = "completed") {
        lock.lock()
        defer { lock.unlock() }
        trace.finishedAt = Date()
        trace.status = status
        try? RunTraceStorage.saveTrace(trace, workspacePath: workspacePath)
    }

    public func currentTraceSnapshot() -> RunTrace {
        lock.lock()
        defer { lock.unlock() }
        return trace
    }
}

// MARK: - Run Trace Manager

public final class RunTraceManager: @unchecked Sendable {
    public static let shared = RunTraceManager()

    private let lock = NSLock()
    private var activeRecorders: [String: RunTraceRecorder] = [:]
    private var globalActiveRecorder: RunTraceRecorder?

    public var activeRecorder: RunTraceRecorder? {
        RunTraceContext.current ?? lock.withLock { globalActiveRecorder }
    }

    public var activeRunId: String? {
        activeRecorder?.runId
    }

    public init() {
        // Run 7-day retention sweep on startup
        RunTraceStorage.sweepExpiredTraces(maxAgeDays: 7)
    }

    @discardableResult
    public func startRun(
        runId: String? = nil,
        conversationId: UUID? = nil,
        workspacePath: String? = nil,
        metadata: [String: String] = [:]
    ) -> RunTraceRecorder {
        let id = runId ?? RunTrace.generateRunId()
        let trace = RunTrace(
            id: id,
            conversationId: conversationId,
            startedAt: Date(),
            status: "running",
            events: [],
            metadata: metadata
        )
        let recorder = RunTraceRecorder(trace: trace, workspacePath: workspacePath)
        lock.lock()
        activeRecorders[id] = recorder
        globalActiveRecorder = recorder
        lock.unlock()
        return recorder
    }

    public func endRun(runId: String? = nil, status: String = "completed") {
        lock.lock()
        let targetId = runId ?? globalActiveRecorder?.runId
        let recorder = targetId != nil ? activeRecorders[targetId!] : globalActiveRecorder
        if let rec = recorder {
            rec.finish(status: status)
            if let id = targetId {
                activeRecorders.removeValue(forKey: id)
            }
            if globalActiveRecorder?.runId == rec.runId {
                globalActiveRecorder = nil
            }
        }
        lock.unlock()
    }

    // MARK: - Event Recording Helpers

    @discardableResult
    public func recordModelCall(
        model: String,
        prompt: String,
        tokenCounts: TokenCountInfo? = nil,
        durationMs: Double? = nil
    ) -> RunTraceEvent? {
        guard let recorder = activeRecorder else { return nil }
        return recorder.appendEvent { seq in
            RunTraceEvent.modelCall(
                sequence: seq,
                model: model,
                prompt: prompt,
                tokenCounts: tokenCounts,
                durationMs: durationMs
            )
        }
    }

    @discardableResult
    public func recordToolCall(
        toolName: String,
        arguments: String,
        result: String,
        status: String = "success",
        durationMs: Double? = nil
    ) -> RunTraceEvent? {
        guard let recorder = activeRecorder else { return nil }
        return recorder.appendEvent { seq in
            RunTraceEvent.toolCall(
                sequence: seq,
                toolName: toolName,
                arguments: arguments,
                result: result,
                status: status,
                durationMs: durationMs
            )
        }
    }

    @discardableResult
    public func recordMemoryRead(
        tier: String,
        path: String,
        detail: String = "",
        bytesRead: Int? = nil
    ) -> RunTraceEvent? {
        guard let recorder = activeRecorder else { return nil }
        return recorder.appendEvent { seq in
            RunTraceEvent.memoryRead(
                sequence: seq,
                tier: tier,
                path: path,
                detail: detail,
                bytesRead: bytesRead
            )
        }
    }

    @discardableResult
    public func recordMemoryWrite(
        tier: String,
        path: String,
        bytesWritten: Int,
        detail: String = ""
    ) -> RunTraceEvent? {
        guard let recorder = activeRecorder else { return nil }
        return recorder.appendEvent { seq in
            RunTraceEvent.memoryWrite(
                sequence: seq,
                tier: tier,
                path: path,
                bytesWritten: bytesWritten,
                detail: detail
            )
        }
    }

    @discardableResult
    public func recordSubAgentHandoff(
        parentRunId: String,
        subAgentId: String,
        agentType: String,
        context: String
    ) -> RunTraceEvent? {
        guard let recorder = activeRecorder else { return nil }
        return recorder.appendEvent { seq in
            RunTraceEvent.subAgentHandoff(
                sequence: seq,
                parentRunId: parentRunId,
                subAgentId: subAgentId,
                agentType: agentType,
                context: context
            )
        }
    }

    @discardableResult
    public func recordApproval(
        toolName: String,
        approved: Bool,
        source: ApprovalVerdictSource,
        rule: String? = nil
    ) -> RunTraceEvent? {
        guard let recorder = activeRecorder else { return nil }
        return recorder.appendEvent { seq in
            RunTraceEvent.approval(
                sequence: seq,
                toolName: toolName,
                approved: approved,
                source: source,
                rule: rule
            )
        }
    }

    @discardableResult
    public func recordReviewCheckpoint(
        verdict: String,
        findingsCount: Int,
        findingsSummary: String
    ) -> RunTraceEvent? {
        guard let recorder = activeRecorder else { return nil }
        return recorder.appendEvent { seq in
            RunTraceEvent.reviewCheckpoint(
                sequence: seq,
                verdict: verdict,
                findingsCount: findingsCount,
                findingsSummary: findingsSummary
            )
        }
    }

    /// Resets all active recording state (useful for tests).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        activeRecorders.removeAll()
        globalActiveRecorder = nil
    }

    // MARK: - Verification Artifacts & Comments (Issue #114)

    private func activeTrace(for runId: String) -> RunTrace? {
        lock.lock()
        defer { lock.unlock() }
        return activeRecorders[runId]?.trace ?? (globalActiveRecorder?.runId == runId ? globalActiveRecorder?.trace : nil)
    }

    /// Retrieves verification artifacts for a run, extracting them from the trace if not already present.
    public func getArtifacts(for runId: String, workspacePath: String? = nil) throws -> [VerificationArtifact] {
        guard let trace = try RunTraceStorage.loadTrace(for: runId, workspacePath: workspacePath) ?? activeTrace(for: runId) else {
            return []
        }
        if !trace.artifacts.isEmpty {
            return trace.artifacts
        }
        return VerificationArtifactExtractor.extractArtifacts(from: trace)
    }

    /// Attaches a comment to a verification artifact for a run and persists it immediately with the run's trace.
    @discardableResult
    public func attachComment(
        to artifactId: String,
        runId: String,
        comment: VerificationComment,
        workspacePath: String? = nil
    ) throws -> VerificationArtifact {
        guard var trace = try RunTraceStorage.loadTrace(for: runId, workspacePath: workspacePath) ?? activeTrace(for: runId) else {
            throw NSError(domain: "RunTraceManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Trace for runId '\(runId)' not found."])
        }

        if trace.artifacts.isEmpty {
            trace.artifacts = VerificationArtifactExtractor.extractArtifacts(from: trace)
        }

        guard let index = trace.artifacts.firstIndex(where: { $0.id == artifactId }) else {
            throw NSError(domain: "RunTraceManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Artifact '\(artifactId)' not found in run '\(runId)'."])
        }

        trace.artifacts[index].comments.append(comment)
        try RunTraceStorage.saveTrace(trace, workspacePath: workspacePath)
        return trace.artifacts[index]
    }

    /// Updates or replaces the artifacts on a run trace and persists the update.
    public func saveArtifacts(
        _ artifacts: [VerificationArtifact],
        for runId: String,
        workspacePath: String? = nil
    ) throws {
        guard var trace = try RunTraceStorage.loadTrace(for: runId, workspacePath: workspacePath) ?? activeTrace(for: runId) else {
            throw NSError(domain: "RunTraceManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Trace for runId '\(runId)' not found."])
        }
        trace.artifacts = artifacts
        try RunTraceStorage.saveTrace(trace, workspacePath: workspacePath)
    }
}
