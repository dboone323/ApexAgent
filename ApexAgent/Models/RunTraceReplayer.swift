import Foundation

// MARK: - Replayed Event Model

public struct ReplayedEvent: Codable, Sendable, Equatable {
    public let sequence: Int
    public let timestamp: Date
    public let kind: RunTraceEventKind
    public let summary: String
    public let detail: String

    public init(sequence: Int, timestamp: Date, kind: RunTraceEventKind, summary: String, detail: String) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }
}

// MARK: - Run Trace Replay Report

public struct RunTraceReplayReport: Codable, Sendable, Equatable {
    public let runId: String
    public let totalEvents: Int
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: String
    public let isReadOnly: Bool
    public let replayedEvents: [ReplayedEvent]

    public init(
        runId: String,
        totalEvents: Int,
        startedAt: Date,
        finishedAt: Date?,
        status: String,
        replayedEvents: [ReplayedEvent]
    ) {
        self.runId = runId
        self.totalEvents = totalEvents
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.isReadOnly = true
        self.replayedEvents = replayedEvents
    }

    public func toFormattedString() -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("================================================================================")
        lines.append("APEXAGENT RUN TRACE REPLAY: \(runId)")
        lines.append("Started:     \(iso.string(from: startedAt))")
        if let fin = finishedAt {
            lines.append("Finished:    \(iso.string(from: fin))")
        }
        lines.append("Status:      \(status)")
        lines.append("Read-Only:   \(isReadOnly ? "true (no tools or model calls executed)" : "false")")
        lines.append("Total Steps: \(totalEvents)")
        lines.append("================================================================================")
        lines.append("\nEvent Chronological Sequence:")
        for ev in replayedEvents {
            let ts = iso.string(from: ev.timestamp)
            lines.append("  [\(String(format: "%03d", ev.sequence))] [\(ts)] [\(ev.kind.rawValue)] \(ev.summary)")
            if !ev.detail.isEmpty {
                lines.append("        -> \(ev.detail)")
            }
        }
        lines.append("\nReplay finished successfully (\(totalEvents) steps replayed in exact recorded order).")
        return SecretRedactor.redact(text: lines.joined(separator: "\n"))
    }

    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}

// MARK: - Run Trace Replayer

public enum RunTraceReplayer {

    /// Loads and replays a recorded trace from an in-memory `RunTrace` model.
    /// Strictly read-only: does not execute tools, model calls, or write to disk.
    public static func replay(trace: RunTrace) -> RunTraceReplayReport {
        // Events replayed in strict sequence order
        let sortedEvents = trace.events.sorted { $0.sequence < $1.sequence }
        var replayed: [ReplayedEvent] = []

        for ev in sortedEvents {
            let summary = SecretRedactor.redact(text: ev.eventDescription)
            let rawDetail: String
            switch ev.kind {
            case .modelCall:
                let tokenStr = ev.tokenCounts.map { "\($0.totalTokens)" } ?? "not reported"
                rawDetail = "model=\(ev.model ?? "") tokens=\(tokenStr) duration=\(String(format: "%.1f", ev.durationMs ?? 0.0))ms"
            case .toolCall:
                rawDetail = "args=\(ev.argumentsSummary ?? "") status=\(ev.toolStatus ?? "") result=\(ev.resultSummary ?? "")"
            case .memoryRead:
                rawDetail = "tier=\(ev.memoryTier ?? "") path=\(ev.filePath ?? "")"
            case .memoryWrite:
                rawDetail = "tier=\(ev.memoryTier ?? "") path=\(ev.filePath ?? "") bytes=\(ev.bytesTransferred ?? 0)"
            case .subAgentHandoff:
                rawDetail = "parent=\(ev.parentRunId ?? "") subAgent=\(ev.subAgentId ?? "") type=\(ev.agentType ?? "")"
            case .approval:
                rawDetail = "tool=\(ev.toolName ?? "") verdict=\(ev.verdict ?? "") source=\(ev.verdictSource ?? "") rule=\(ev.rule ?? "none")"
            case .reviewCheckpoint:
                rawDetail = "verdict=\(ev.reviewVerdict ?? "") findings=\(ev.findingsCount ?? 0) summary=\(ev.findingsSummary ?? "")"
            }
            let detail = SecretRedactor.redact(text: rawDetail)

            replayed.append(ReplayedEvent(
                sequence: ev.sequence,
                timestamp: ev.timestamp,
                kind: ev.kind,
                summary: summary,
                detail: detail
            ))
        }

        return RunTraceReplayReport(
            runId: trace.id,
            totalEvents: replayed.count,
            startedAt: trace.startedAt,
            finishedAt: trace.finishedAt,
            status: trace.status,
            replayedEvents: replayed
        )
    }

    /// Loads a recorded trace from a file URL and replays it.
    public static func replay(fileURL: URL) throws -> RunTraceReplayReport {
        let trace = try RunTraceStorage.loadTrace(from: fileURL)
        return replay(trace: trace)
    }

    /// Loads a recorded trace by runId (or file path string) and replays it.
    public static func replay(target: String, workspacePath: String? = nil) throws -> RunTraceReplayReport {
        // Check if target is a direct file path
        if FileManager.default.fileExists(atPath: (target as NSString).expandingTildeInPath) {
            let url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            return try replay(fileURL: url)
        }

        // Otherwise look up by runId in workspace or standard storage
        if let trace = try RunTraceStorage.loadTrace(for: target, workspacePath: workspacePath) {
            return replay(trace: trace)
        }

        // Also check default storage if custom workspace wasn't specified
        if workspacePath != nil, let trace = try RunTraceStorage.loadTrace(for: target, workspacePath: nil) {
            return replay(trace: trace)
        }

        throw NSError(
            domain: "RunTraceReplayer",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Trace '\(target)' not found in workspace or standard storage."]
        )
    }
}
