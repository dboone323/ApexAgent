import Foundation
import CryptoKit
import SwiftData
import SharedModels

// MARK: - SwiftData Store Migration & Integrity Checksum Gate (Batch 67)

/// Severity of a SwiftData store integrity violation.
public enum StoreViolationSeverity: String, Codable, Sendable, Comparable {
    case info = "INFO"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case critical = "CRITICAL"

    private var rank: Int {
        switch self {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: StoreViolationSeverity, rhs: StoreViolationSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A specific integrity or schema violation detected on the persistence store.
public struct StoreIntegrityViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(ruleId):\(message)" }
    public let ruleId: String
    public let severity: StoreViolationSeverity
    public let message: String
    public let remediation: String

    public init(
        ruleId: String,
        severity: StoreViolationSeverity,
        message: String,
        remediation: String
    ) {
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// Metadata description of a validated persistence store.
public struct StoreSnapshotMetadata: Codable, Sendable, Equatable {
    public let storePath: String
    public let fileSize: Int64
    public let sha256Digest: String
    public let isSQLiteFormat: Bool
    public let modelCount: Int

    public init(
        storePath: String,
        fileSize: Int64,
        sha256Digest: String,
        isSQLiteFormat: Bool,
        modelCount: Int
    ) {
        self.storePath = storePath
        self.fileSize = fileSize
        self.sha256Digest = sha256Digest
        self.isSQLiteFormat = isSQLiteFormat
        self.modelCount = modelCount
    }
}

/// Report produced by `SwiftDataStoreIntegrityGate`.
public struct SwiftDataStoreAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let metadata: StoreSnapshotMetadata?
    public let violations: [StoreIntegrityViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        metadata: StoreSnapshotMetadata?,
        violations: [StoreIntegrityViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.metadata = metadata
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Autonomous gate verifying SwiftData sqlite database headers, model registrations,
/// file permissions, and SHA-256 backup checksums.
public enum SwiftDataStoreIntegrityGate {

    /// Expected standard SQLite file header prefix (16 bytes: "SQLite format 3\0").
    public static let sqliteHeaderPrefix: [UInt8] = [
        0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
        0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00
    ]

    /// Audits an on-disk store file and schema registration.
    public static func audit(
        storeURL: URL? = nil,
        registeredModels: [any PersistentModel.Type] = ApexSuiteSchemaV1.models
    ) -> SwiftDataStoreAuditReport {
        var violations: [StoreIntegrityViolation] = []

        // Rule 1: Schema model count validation
        if registeredModels.isEmpty {
            violations.append(
                StoreIntegrityViolation(
                    ruleId: "SCHEMA-001",
                    severity: .critical,
                    message: "No PersistentModel classes registered in active schema.",
                    remediation: "Include persistent model types in Schema.models."
                )
            )
        }

        var meta: StoreSnapshotMetadata? = nil

        if let url = storeURL {
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                violations.append(
                    StoreIntegrityViolation(
                        ruleId: "STORE-001",
                        severity: .high,
                        message: "Store file does not exist at '\(url.path)'.",
                        remediation: "Verify container database path before invoking integrity gate."
                    )
                )
            } else {
                do {
                    let attrs = try fm.attributesOfItem(atPath: url.path)
                    let size = (attrs[.size] as? Int64) ?? 0

                    // Check file permissions (should not be world-writable)
                    if let posix = attrs[.posixPermissions] as? NSNumber {
                        let perm = posix.intValue
                        if (perm & 0o002) != 0 {
                            violations.append(
                                StoreIntegrityViolation(
                                    ruleId: "STORE-002",
                                    severity: .high,
                                    message: "Store file permissions (\(String(format: "%o", perm))) allow world write access.",
                                    remediation: "Chmod store file to 0600."
                                )
                            )
                        }
                    }

                    // Check data header and compute checksum
                    let fileData = try Data(contentsOf: url)
                    let digest = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()

                    var isSqlite = false
                    if fileData.count >= 16 {
                        let headerBytes = Array(fileData.prefix(16))
                        isSqlite = (headerBytes == sqliteHeaderPrefix)
                    }

                    if !isSqlite && size > 0 {
                        violations.append(
                            StoreIntegrityViolation(
                                ruleId: "STORE-003",
                                severity: .critical,
                                message: "Store file header is corrupt or does not match valid SQLite magic bytes.",
                                remediation: "Restore store file from backup snapshot."
                            )
                        )
                    }

                    meta = StoreSnapshotMetadata(
                        storePath: url.path,
                        fileSize: size,
                        sha256Digest: digest,
                        isSQLiteFormat: isSqlite,
                        modelCount: registeredModels.count
                    )
                } catch {
                    violations.append(
                        StoreIntegrityViolation(
                            ruleId: "STORE-004",
                            severity: .critical,
                            message: "Failed reading store file: \(error.localizedDescription)",
                            remediation: "Check file system permissions."
                        )
                    )
                }
            }
        } else {
            // In-memory or schema-only validation
            meta = StoreSnapshotMetadata(
                storePath: "memory://",
                fileSize: 0,
                sha256Digest: "in-memory",
                isSQLiteFormat: true,
                modelCount: registeredModels.count
            )
        }

        let penalty = violations.reduce(0.0) { acc, v in
            switch v.severity {
            case .critical: return acc + 35.0
            case .high: return acc + 20.0
            case .medium: return acc + 10.0
            case .low: return acc + 5.0
            case .info: return acc + 1.0
            }
        }

        let score = max(0.0, 100.0 - penalty)
        let hasCriticalOrHigh = violations.contains { $0.severity >= .high }
        let passed = !hasCriticalOrHigh && score >= 80.0

        var recs: [String] = []
        if !passed {
            recs.append("Verify SwiftData SQLite store header and restore from verified backup if corrupted.")
        }

        return SwiftDataStoreAuditReport(
            passed: passed,
            score: score,
            metadata: meta,
            violations: violations,
            recommendations: recs
        )
    }

    /// Verifies that a temporary file has the valid SQLite header bytes.
    public static func verifyHeader(data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        return Array(data.prefix(16)) == sqliteHeaderPrefix
    }
}
