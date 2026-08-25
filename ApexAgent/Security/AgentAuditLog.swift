import Foundation

// MARK: - Agent Audit Log (persistent JSONL tool-call trail)
//
// Persistent audit trail of every tool call ApexAgent makes — critical for
// debugging and security review of an agent that can act on the system
// (WWDC26 "Secure your app: mitigate risks to agentic features"). Entries are
// appended as JSON Lines to Application Support so the trail survives
// restarts and can be inspected with standard tools (jq, grep).

actor AgentAuditLog {
    static let shared = AgentAuditLog()

    struct AuditEntry: Codable, Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let toolName: String
        let arguments: String
        let riskLevel: String
        let wasConfirmed: Bool
        let status: String        // "success" | "failed" | "denied" | "started"
        // Decision-log attribution (O6): WHY the call was allowed/denied and by
        // which rule. Optional so previously-written rows still decode.
        var decisionSource: String? = nil   // ApprovalVerdictSource rawValue, or "user"
        var decisionRule: String? = nil     // guard regex source or granted key
    }

    private(set) var entries: [AuditEntry] = []
    private let maxInMemoryEntries = 500

    /// Resolved lazily; overridable for tests via APEX_AUDIT_LOG_PATH.
    /// Uses getenv (not ProcessInfo) so runtime setenv overrides are honored —
    /// ProcessInfo caches the environment at first access.
    nonisolated static var logFileURL: URL {
        if let raw = getenv("APEX_AUDIT_LOG_PATH") {
            let override = String(cString: raw)
            if !override.isEmpty { return URL(fileURLWithPath: override) }
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ApexAgent", isDirectory: true)
            .appendingPathComponent("apexagent_audit.jsonl")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func record(
        toolName: String,
        arguments: String,
        wasConfirmed: Bool = false,
        status: String = "success"
    ) {
        let entry = AuditEntry(
            id: UUID(),
            timestamp: Date(),
            toolName: toolName,
            // Cap stored arguments — they can contain large file contents.
            arguments: String(arguments.prefix(2000)),
            riskLevel: AgentSecurity.riskLevel(for: toolName).rawValue,
            wasConfirmed: wasConfirmed,
            status: status
        )
        entries.append(entry)
        if entries.count > maxInMemoryEntries {
            entries.removeFirst(entries.count - maxInMemoryEntries)
        }
        persist(entry)
    }

    /// Append an authorization DECISION row: which tool call was allowed or
    /// denied, by which rule, from which source (O6, port of OpenMausBot
    /// decision-log.ts). Arguments are redacted through SecretRedactor first —
    /// summaries carry whatever the agent typed, credentials included.
    func recordDecision(
        toolName: String,
        arguments: String,
        approved: Bool,
        source: ApprovalVerdictSource?,
        rule: String?
    ) {
        let redacted = SecretRedactor.redact(text: arguments)
        let entry = AuditEntry(
            id: UUID(),
            timestamp: Date(),
            toolName: toolName,
            arguments: String(redacted.prefix(2000)),
            riskLevel: AgentSecurity.riskLevel(for: toolName).rawValue,
            wasConfirmed: approved,
            status: approved ? "auto-approved" : "denied",
            decisionSource: source?.rawValue,
            decisionRule: rule
        )
        entries.append(entry)
        if entries.count > maxInMemoryEntries {
            entries.removeFirst(entries.count - maxInMemoryEntries)
        }
        persist(entry)
    }

    /// Most recent entries, newest first.
    func recent(limit: Int = 50) -> [AuditEntry] {
        Array(entries.suffix(limit).reversed())
    }

    private func persist(_ entry: AuditEntry) {
        let url = Self.logFileURL
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard var data = try? Self.encoder.encode(entry) else { return }
            data.append(0x0A) // newline
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // Audit persistence must never crash or block the agent loop.
            print("[AgentAuditLog] persist failed: \(error.localizedDescription)")
        }
    }
}
