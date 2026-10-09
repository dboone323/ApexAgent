import Testing
import Foundation
import SwiftData
@testable import ApexAgentCore
@testable import SharedModels

@Suite("Batch 67 — SwiftData Store Migration & Integrity Checksum Gate Tests")
struct SwiftDataStoreIntegrityGateTests {

    @Test("Schema-only validation of ApexSuiteSchemaV1 passes with score 100.0")
    func schemaOnlyValidationPasses() {
        let report = SwiftDataStoreIntegrityGate.audit(storeURL: nil)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.metadata?.modelCount == 8)
        #expect(report.violations.isEmpty)
    }

    @Test("Valid SQLite header file passes store audit with SHA-256 digest")
    func validSQLiteFilePassesAudit() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let storeURL = tempDir.appendingPathComponent("test_\(UUID().uuidString).store")

        var data = Data(SwiftDataStoreIntegrityGate.sqliteHeaderPrefix)
        data.append(Data(repeating: 0x00, count: 512)) // page padding
        try data.write(to: storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let report = SwiftDataStoreIntegrityGate.audit(storeURL: storeURL)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.metadata?.isSQLiteFormat == true)
        #expect(report.metadata?.sha256Digest.count == 64)
    }

    @Test("Corrupted store file missing SQLite magic bytes triggers critical violation")
    func corruptedStoreTriggersCriticalViolation() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let storeURL = tempDir.appendingPathComponent("corrupt_\(UUID().uuidString).store")

        let junk = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        try junk.write(to: storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let report = SwiftDataStoreIntegrityGate.audit(storeURL: storeURL)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "STORE-003" && $0.severity == .critical })
    }

    @Test("Non-existent store URL triggers high violation")
    func missingStoreFileTriggersViolation() {
        let missingURL = URL(fileURLWithPath: "/tmp/non_existent_store_\(UUID().uuidString).sqlite")
        let report = SwiftDataStoreIntegrityGate.audit(storeURL: missingURL)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "STORE-001" && $0.severity == .high })
    }

    @Test("verifyHeader detects valid and invalid SQLite prefixes")
    func verifyHeaderMatchesSQLiteMagicBytes() {
        let valid = Data(SwiftDataStoreIntegrityGate.sqliteHeaderPrefix)
        #expect(SwiftDataStoreIntegrityGate.verifyHeader(data: valid))

        let invalid = Data(repeating: 0x41, count: 16)
        #expect(!SwiftDataStoreIntegrityGate.verifyHeader(data: invalid))

        let short = Data([0x53, 0x51])
        #expect(!SwiftDataStoreIntegrityGate.verifyHeader(data: short))
    }

    @Test("Report serializes to formatted JSON")
    func reportSerializesToJSON() {
        let report = SwiftDataStoreIntegrityGate.audit(storeURL: nil)
        let json = report.toJSON()
        #expect(json.contains("\"passed\" : true"))
        #expect(json.contains("\"score\" : 100"))
        #expect(json.contains("\"modelCount\" : 8"))
    }
}
