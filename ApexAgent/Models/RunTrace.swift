import Foundation

// MARK: - Run Trace Event Kinds

/// Minimum required event kinds for per-run structured observability.
public enum RunTraceEventKind: String, Codable, Sendable, CaseIterable {
    case modelCall = "modelCall"
    case toolCall = "toolCall"
    case memoryRead = "memoryRead"
    case memoryWrite = "memoryWrite"
    case subAgentHandoff = "subAgentHandoff"
    case approval = "approval"
    case reviewCheckpoint = "reviewCheckpoint"
}

// MARK: - Token Count Information

public struct TokenCountInfo: Codable, Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int = 0, completionTokens: Int = 0, totalTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens > 0 ? totalTokens : (promptTokens + completionTokens)
    }
}

// MARK: - Run Trace Event

public struct RunTraceEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let sequence: Int
    public let timestamp: Date
    public let kind: RunTraceEventKind

    // Model Call details
    public let model: String?
    public let promptSummary: String?
    public let tokenCounts: TokenCountInfo?
    public let durationMs: Double?

    // Tool Call details
    public let toolName: String?
    public let argumentsSummary: String?
    public let resultSummary: String?
    public let toolStatus: String?

    // Memory Read / Memory Write details
    public let memoryTier: String? // "curated", "persona", "userContext", "dailyNotes"
    public let filePath: String?
    public let bytesTransferred: Int?
    public let memoryDetail: String?

    // Sub-Agent Handoff details
    public let parentRunId: String?
    public let subAgentId: String?
    public let agentType: String?
    public let contextSummary: String?

    // Approval details
    public let verdict: String? // "approved", "denied"
    public let verdictSource: String? // ApprovalVerdictSource rawValue
    public let rule: String?

    // Review Checkpoint details (Issue #103)
    public let reviewVerdict: String? // "pass", "fail"
    public let findingsCount: Int?
    public let findingsSummary: String?

    public init(
        id: UUID = UUID(),
        sequence: Int,
        timestamp: Date = Date(),
        kind: RunTraceEventKind,
        model: String? = nil,
        promptSummary: String? = nil,
        tokenCounts: TokenCountInfo? = nil,
        durationMs: Double? = nil,
        toolName: String? = nil,
        argumentsSummary: String? = nil,
        resultSummary: String? = nil,
        toolStatus: String? = nil,
        memoryTier: String? = nil,
        filePath: String? = nil,
        bytesTransferred: Int? = nil,
        memoryDetail: String? = nil,
        parentRunId: String? = nil,
        subAgentId: String? = nil,
        agentType: String? = nil,
        contextSummary: String? = nil,
        verdict: String? = nil,
        verdictSource: String? = nil,
        rule: String? = nil,
        reviewVerdict: String? = nil,
        findingsCount: Int? = nil,
        findingsSummary: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.model = model
        self.promptSummary = promptSummary.map { Self.sanitizeSummary($0) }
        self.tokenCounts = tokenCounts
        self.durationMs = durationMs
        self.toolName = toolName
        self.argumentsSummary = argumentsSummary.map { Self.sanitizeSummary($0) }
        self.resultSummary = resultSummary.map { Self.sanitizeSummary($0) }
        self.toolStatus = toolStatus
        self.memoryTier = memoryTier
        self.filePath = filePath.map { SecretRedactor.redact(text: $0) }
        self.bytesTransferred = bytesTransferred
        self.memoryDetail = memoryDetail.map { Self.sanitizeSummary($0) }
        self.parentRunId = parentRunId
        self.subAgentId = subAgentId
        self.agentType = agentType
        self.contextSummary = contextSummary.map { Self.sanitizeSummary($0) }
        self.verdict = verdict
        self.verdictSource = verdictSource
        self.rule = rule
        self.reviewVerdict = reviewVerdict
        self.findingsCount = findingsCount
        self.findingsSummary = findingsSummary.map { Self.sanitizeSummary($0) }
    }

    // MARK: - Secrets Sanitization
    /// Sanitizes text using SecretRedactor and summarization so secrets are never stored.
    public static func sanitizeSummary(_ text: String, maxChars: Int = 200) -> String {
        let redacted = SecretRedactor.redact(text: text)
        if redacted.contains("«redacted»") {
            return "«redacted sensitive payload (\(text.utf8.count) bytes)»"
        }
        let singleLine = redacted
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count > maxChars {
            return String(singleLine.prefix(maxChars - 3)) + "..."
        }
        return singleLine
    }

    // MARK: - Factory Initializers

    public static func modelCall(
        sequence: Int,
        model: String,
        prompt: String,
        tokenCounts: TokenCountInfo? = nil,
        durationMs: Double? = nil
    ) -> RunTraceEvent {
        RunTraceEvent(
            sequence: sequence,
            kind: .modelCall,
            model: model,
            promptSummary: sanitizeSummary(prompt),
            tokenCounts: tokenCounts,
            durationMs: durationMs
        )
    }

    public static func toolCall(
        sequence: Int,
        toolName: String,
        arguments: String,
        result: String,
        status: String = "success",
        durationMs: Double? = nil
    ) -> RunTraceEvent {
        RunTraceEvent(
            sequence: sequence,
            kind: .toolCall,
            durationMs: durationMs,
            toolName: toolName,
            argumentsSummary: sanitizeSummary(arguments),
            resultSummary: sanitizeSummary(result),
            toolStatus: status
        )
    }

    public static func memoryRead(
        sequence: Int,
        tier: String,
        path: String,
        detail: String = "",
        bytesRead: Int? = nil
    ) -> RunTraceEvent {
        RunTraceEvent(
            sequence: sequence,
            kind: .memoryRead,
            memoryTier: tier,
            filePath: path,
            bytesTransferred: bytesRead,
            memoryDetail: sanitizeSummary(detail)
        )
    }

    public static func memoryWrite(
        sequence: Int,
        tier: String,
        path: String,
        bytesWritten: Int,
        detail: String = ""
    ) -> RunTraceEvent {
        RunTraceEvent(
            sequence: sequence,
            kind: .memoryWrite,
            memoryTier: tier,
            filePath: path,
            bytesTransferred: bytesWritten,
            memoryDetail: sanitizeSummary(detail)
        )
    }

    public static func subAgentHandoff(
        sequence: Int,
        parentRunId: String,
        subAgentId: String,
        agentType: String,
        context: String
    ) -> RunTraceEvent {
        RunTraceEvent(
            sequence: sequence,
            kind: .subAgentHandoff,
            parentRunId: parentRunId,
            subAgentId: subAgentId,
            agentType: agentType,
            contextSummary: sanitizeSummary(context)
        )
    }

    public static func approval(
        sequence: Int,
        toolName: String,
        approved: Bool,
        source: ApprovalVerdictSource,
        rule: String? = nil
    ) -> RunTraceEvent {
        RunTraceEvent(
            sequence: sequence,
            kind: .approval,
            toolName: toolName,
            verdict: approved ? "approved" : "denied",
            verdictSource: source.rawValue,
            rule: rule
        )
    }

    public static func reviewCheckpoint(
        sequence: Int,
        verdict: String,
        findingsCount: Int,
        findingsSummary: String
    ) -> RunTraceEvent {
        RunTraceEvent(
            sequence: sequence,
            kind: .reviewCheckpoint,
            reviewVerdict: verdict,
            findingsCount: findingsCount,
            findingsSummary: sanitizeSummary(findingsSummary)
        )
    }

    public var eventDescription: String {
        let desc: String
        switch kind {
        case .modelCall:
            let modelName = model ?? "unknown-model"
            let prompt = promptSummary ?? ""
            let ms = durationMs != nil ? String(format: " (%.1fms)", durationMs!) : ""
            desc = "modelCall: \(modelName)\(ms) - \"\(prompt)\""
        case .toolCall:
            let name = toolName ?? "unknown-tool"
            let stat = toolStatus ?? "success"
            desc = "toolCall: \(name) [\(stat)] args=\"\(argumentsSummary ?? "")\" result=\"\(resultSummary ?? "")\""
        case .memoryRead:
            desc = "memoryRead [\(memoryTier ?? "unknown")]: \(filePath ?? "") \(memoryDetail ?? "")"
        case .memoryWrite:
            let bytes = bytesTransferred != nil ? " (\(bytesTransferred!) bytes)" : ""
            desc = "memoryWrite [\(memoryTier ?? "unknown")]: \(filePath ?? "")\(bytes) \(memoryDetail ?? "")"
        case .subAgentHandoff:
            desc = "subAgentHandoff: parent=\(parentRunId ?? "") → subAgent=\(subAgentId ?? "") (\(agentType ?? "")) context=\"\(contextSummary ?? "")\""
        case .approval:
            desc = "approval: \(toolName ?? "") -> \(verdict ?? "") via \(verdictSource ?? "unknown")" + (rule != nil ? " [rule: \(rule!)]" : "")
        case .reviewCheckpoint:
            desc = "reviewCheckpoint: \(reviewVerdict ?? "unknown") (findings: \(findingsCount ?? 0)) - \"\(findingsSummary ?? "")\""
        }
        return SecretRedactor.redact(text: desc)
    }
}

// MARK: - Run Trace

public struct RunTrace: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let conversationId: UUID?
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: String // "running", "completed", "failed", "cancelled"
    public var events: [RunTraceEvent]
    public var metadata: [String: String]
    public var artifacts: [VerificationArtifact]

    enum CodingKeys: String, CodingKey {
        case id, conversationId, startedAt, finishedAt, status, events, metadata, artifacts
    }

    public init(
        id: String = RunTrace.generateRunId(),
        conversationId: UUID? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: String = "running",
        events: [RunTraceEvent] = [],
        metadata: [String: String] = [:],
        artifacts: [VerificationArtifact] = []
    ) {
        self.id = id
        self.conversationId = conversationId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.events = events
        // Secrets hygiene: redact metadata values to prevent credentials from persisting in trace JSON
        self.metadata = Dictionary(uniqueKeysWithValues: metadata.map { key, value in
            (key, SecretRedactor.redact(text: value))
        })
        self.artifacts = artifacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.conversationId = try container.decodeIfPresent(UUID.self, forKey: .conversationId)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.status = try container.decode(String.self, forKey: .status)
        self.events = try container.decodeIfPresent([RunTraceEvent].self, forKey: .events) ?? []
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        self.artifacts = try container.decodeIfPresent([VerificationArtifact].self, forKey: .artifacts) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(conversationId, forKey: .conversationId)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try container.encode(status, forKey: .status)
        try container.encode(events, forKey: .events)
        try container.encode(metadata, forKey: .metadata)
        if !artifacts.isEmpty {
            try container.encode(artifacts, forKey: .artifacts)
        }
    }

    public static func generateRunId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let shortId = UUID().uuidString.prefix(8).lowercased()
        return "run-\(timestamp)-\(shortId)"
    }

    public func toFormattedString() -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("=== Run Trace: \(id) ===")
        lines.append("Started:  \(iso.string(from: startedAt))")
        if let fin = finishedAt {
            lines.append("Finished: \(iso.string(from: fin))")
        }
        lines.append("Status:   \(status)")
        lines.append("Events (\(events.count)):")
        for ev in events {
            let ts = iso.string(from: ev.timestamp)
            lines.append("  [\(String(format: "%03d", ev.sequence))] [\(ts)] [\(ev.kind.rawValue)] \(ev.eventDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
