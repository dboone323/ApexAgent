import Foundation
import CryptoKit

// MARK: - Audit Event Models

public struct AgentAuditRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sequenceNumber: UInt64
    public let timestamp: Date
    public let botId: String
    public let botName: String
    public let eventType: String
    public let actionName: String
    public let payloadSummary: String
    public let status: String
    public let previousHash: String
    public let recordHash: String

    public init(
        id: UUID = UUID(),
        sequenceNumber: UInt64,
        timestamp: Date = Date(),
        botId: String,
        botName: String,
        eventType: String,
        actionName: String,
        payloadSummary: String,
        status: String,
        previousHash: String
    ) {
        self.id = id
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.botId = botId
        self.botName = botName
        self.eventType = eventType
        self.actionName = actionName
        self.payloadSummary = payloadSummary
        self.status = status
        self.previousHash = previousHash
        
        let contentToHash = "\(id.uuidString)|\(sequenceNumber)|\(timestamp.timeIntervalSince1970)|\(botId)|\(botName)|\(eventType)|\(actionName)|\(payloadSummary)|\(status)|\(previousHash)"
        let digest = SHA256.hash(data: Data(contentToHash.utf8))
        self.recordHash = digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - AgentAuditLogger (Actor)

public actor AgentAuditLogger {
    public static let shared = AgentAuditLogger()

    private let logFileURL: URL
    private var lastHash: String = "GENESIS_HASH_APEX_AGENT_0000"
    private var currentSequence: UInt64 = 0
    private var inMemoryRecords: [AgentAuditRecord] = []

    public init(customFileURL: URL? = nil) {
        if let custom = customFileURL {
            self.logFileURL = custom
        } else {
            let logsDir = ApexAgentStoragePaths.auditLogs
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            self.logFileURL = logsDir.appendingPathComponent("audit.jsonl")
        }
    }

    /// Logs an audit event with SHA-256 cryptographic chaining.
    @discardableResult
    public func logEvent(
        botId: String,
        botName: String,
        eventType: String,
        actionName: String,
        payloadSummary: String,
        status: String
    ) -> AgentAuditRecord {
        currentSequence += 1
        let record = AgentAuditRecord(
            sequenceNumber: currentSequence,
            botId: botId,
            botName: botName,
            eventType: eventType,
            actionName: actionName,
            payloadSummary: payloadSummary,
            status: status,
            previousHash: lastHash
        )

        lastHash = record.recordHash
        inMemoryRecords.append(record)

        // Persist to JSONL file
        if let data = try? JSONEncoder().encode(record),
           let jsonString = String(data: data, encoding: .utf8) {
            let line = jsonString + "\n"
            if let lineData = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logFileURL) {
                        defer { try? handle.close() }
                        handle.seekToEndOfFile()
                        handle.write(lineData)
                    }
                } else {
                    try? lineData.write(to: logFileURL)
                }
            }
        }

        return record
    }

    /// Verifies the cryptographic integrity of the entire audit chain.
    public func verifyChainIntegrity() -> (isValid: Bool, totalRecords: Int) {
        let result = Self.verifyRecordSequenceIntegrity(inMemoryRecords)
        return (result.isValid, inMemoryRecords.count)
    }

    /// Verifies cryptographic integrity of an arbitrary sequence of audit records, identifying the first tampered sequence index if invalid.
    public static func verifyRecordSequenceIntegrity(_ records: [AgentAuditRecord]) -> (isValid: Bool, invalidIndex: Int?) {
        var expectedPrev = "GENESIS_HASH_APEX_AGENT_0000"
        for (index, record) in records.enumerated() {
            if record.previousHash != expectedPrev {
                return (false, index)
            }
            
            let contentToHash = "\(record.id.uuidString)|\(record.sequenceNumber)|\(record.timestamp.timeIntervalSince1970)|\(record.botId)|\(record.botName)|\(record.eventType)|\(record.actionName)|\(record.payloadSummary)|\(record.status)|\(record.previousHash)"
            let digest = SHA256.hash(data: Data(contentToHash.utf8))
            let calculatedHash = digest.map { String(format: "%02x", $0) }.joined()
            
            if calculatedHash != record.recordHash {
                return (false, index)
            }
            expectedPrev = record.recordHash
        }
        return (true, nil)
    }

    /// Verifies cryptographic integrity of the on-disk JSONL log file, detecting any manual file tampering or truncation.
    public func verifyFileIntegrity() -> (isValid: Bool, totalRecords: Int, tamperedLine: Int?) {
        guard FileManager.default.fileExists(atPath: logFileURL.path),
              let content = try? String(contentsOf: logFileURL, encoding: .utf8) else {
            return (true, 0, nil)
        }
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var records: [AgentAuditRecord] = []
        for (idx, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(AgentAuditRecord.self, from: data) else {
                return (false, records.count, idx)
            }
            records.append(record)
        }
        let result = Self.verifyRecordSequenceIntegrity(records)
        return (result.isValid, records.count, result.invalidIndex)
    }

    public func fetchRecentRecords(limit: Int = 50) -> [AgentAuditRecord] {
        return Array(inMemoryRecords.suffix(limit))
    }

    public func reset() {
        inMemoryRecords.removeAll()
        lastHash = "GENESIS_HASH_APEX_AGENT_0000"
        currentSequence = 0
        try? FileManager.default.removeItem(at: logFileURL)
    }
}
