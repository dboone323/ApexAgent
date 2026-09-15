import Foundation
import CryptoKit
import Observation

@Observable @MainActor public final class CryptographicAuditChain {
    public static let shared = CryptographicAuditChain()
    
    public struct AuditEntry: Codable, Sendable, Identifiable {
        public let id: UUID
        public let timestamp: Date
        public let toolName: String
        public let inputArguments: String
        public let outputSummary: String
        public let exitStatus: String
        public let botName: String?
        public let previousHash: String
        public let entryHash: String
    }
    
    public private(set) var entries: [AuditEntry] = []
    public private(set) var chainValid: Bool = true
    
    private let auditFilePath: URL
    
    private init() {
        let fileManager = FileManager.default
        let auditDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".apex")
        if !fileManager.fileExists(atPath: auditDir.path) {
            try? fileManager.createDirectory(at: auditDir, withIntermediateDirectories: true)
        }
        self.auditFilePath = auditDir.appendingPathComponent("audit_chain.json")
        self.loadChain()
        _ = self.verifyChain()
    }
    
    private func loadChain() {
        guard let data = try? Data(contentsOf: auditFilePath) else { return }
        if let decoded = try? JSONDecoder().decode([AuditEntry].self, from: data) {
            self.entries = decoded
        }
    }
    
    private func saveChain() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: auditFilePath, options: .atomic)
    }
    
    public func record(toolName: String, input: String, output: String, status: String, botName: String?) {
        let previousHash = entries.last?.entryHash ?? String(repeating: "0", count: 64)
        let timestamp = Date()
        let timestampStr = timestamp.ISO8601Format()
        let outputTruncated = String(output.prefix(500))
        
        let dataToHash = previousHash + timestampStr + toolName + input + outputTruncated + status
        let hash = SHA256.hash(data: Data(dataToHash.utf8))
        let entryHash = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        let entry = AuditEntry(
            id: UUID(),
            timestamp: timestamp,
            toolName: toolName,
            inputArguments: input,
            outputSummary: outputTruncated,
            exitStatus: status,
            botName: botName,
            previousHash: previousHash,
            entryHash: entryHash
        )
        
        entries.append(entry)
        saveChain()
        chainValid = verifyChain()
    }
    
    public func verifyChain() -> Bool {
        self.chainValid = Self.verifyEntries(entries)
        return self.chainValid
    }

    public static func verifyEntries(_ entries: [AuditEntry]) -> Bool {
        guard let first = entries.first else { return true }
        var currentPreviousHash = first.previousHash
        for entry in entries {
            if entry.previousHash != currentPreviousHash {
                return false
            }
            let dataToHash = currentPreviousHash + entry.timestamp.ISO8601Format() + entry.toolName + entry.inputArguments + entry.outputSummary + entry.exitStatus
            let hash = SHA256.hash(data: Data(dataToHash.utf8))
            let computedHash = hash.compactMap { String(format: "%02x", $0) }.joined()
            if entry.entryHash != computedHash {
                return false
            }
            currentPreviousHash = entry.entryHash
        }
        return true
    }

    public func importChain(from data: Data) throws -> Bool {
        let decoded = try JSONDecoder().decode([AuditEntry].self, from: data)
        self.entries = decoded
        self.saveChain()
        self.chainValid = self.verifyChain()
        return self.chainValid
    }
    
    public func exportChain() throws -> Data {
        return try JSONEncoder().encode(entries)
    }
    
    public func trimToLast(_ count: Int) {
        if entries.count > count {
            let keep = entries.suffix(count)
            entries = Array(keep)
            saveChain()
            chainValid = verifyChain()
        }
    }
}
