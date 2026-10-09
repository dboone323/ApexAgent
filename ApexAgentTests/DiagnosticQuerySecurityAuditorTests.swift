import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 89 — System Diagnostics OSLog Query Predicate Sanitizer Gate Tests")
struct DiagnosticQuerySecurityAuditorTests {

    @Test("Valid OSLog query configuration passes security audit with 100% score")
    func validQueryPasses() {
        let report = DiagnosticQuerySecurityAuditor.auditAndSanitizeQuery(
            subsystem: "com.apple.dt.xcode",
            category: "build",
            level: "error",
            lastSeconds: 600,
            searchText: "failed",
            limit: 100
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.sanitizedQuery?.subsystem == "com.apple.dt.xcode")
        #expect(report.sanitizedQuery?.category == "build")
        #expect(report.sanitizedQuery?.level == "error")
        #expect(report.sanitizedQuery?.lastSeconds == 600)
        #expect(report.sanitizedQuery?.limit == 100)
        #expect(report.violations.isEmpty)
    }

    @Test("Sensitive credentials in log output are masked with redaction placeholders")
    func sensitiveLogDataMasking() {
        let rawLog = "Authentication header Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 with apiKey=secret_key_12345 and password=\"MySecr3t!\""
        let masked = DiagnosticQuerySecurityAuditor.maskSensitiveLogContent(rawLog)

        #expect(!masked.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        #expect(masked.contains("Bearer [REDACTED_TOKEN]"))
        #expect(!masked.contains("secret_key_12345"))
        #expect(masked.contains("apiKey=[REDACTED]"))
        #expect(!masked.contains("MySecr3t!"))
    }

    @Test("NSPredicate injection payload in subsystem is detected and blocked")
    func predicateInjectionBlocked() {
        let report = DiagnosticQuerySecurityAuditor.auditAndSanitizeQuery(
            subsystem: "com.apple; TRUEPREDICATE"
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "PREDICATE_INJECTION_DETECTED" })
    }

    @Test("Invalid subsystem syntax with spaces or illegal characters is rejected")
    func invalidSubsystemSyntaxFails() {
        let report = DiagnosticQuerySecurityAuditor.auditAndSanitizeQuery(
            subsystem: "Invalid Subsystem Name!"
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "INVALID_SUBSYSTEM_SYNTAX" })
    }

    @Test("Non-positive lookback window fails with NON_POSITIVE_LOOKBACK")
    func nonPositiveLookbackFails() {
        let report = DiagnosticQuerySecurityAuditor.auditAndSanitizeQuery(
            lastSeconds: -10
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "NON_POSITIVE_LOOKBACK" })
    }

    @Test("Excessive lookback and limit are safely clamped within acceptable ceilings")
    func excessiveValuesClamped() {
        let report = DiagnosticQuerySecurityAuditor.auditAndSanitizeQuery(
            lastSeconds: 200_000, // Exceeds 86,400s
            limit: 2000           // Exceeds 500
        )

        #expect(report.passed)
        #expect(report.sanitizedQuery?.lastSeconds == DiagnosticQuerySecurityAuditor.maxLookbackSeconds)
        #expect(report.sanitizedQuery?.limit == DiagnosticQuerySecurityAuditor.maxEntriesLimit)
        #expect(report.violations.contains { $0.code == "LOOKBACK_EXCEEDS_MAXIMUM" })
        #expect(report.violations.contains { $0.code == "LIMIT_EXCEEDS_MAXIMUM" })
    }

    @Test("Unknown log level triggers warning violation")
    func unknownLogLevelWarning() {
        let report = DiagnosticQuerySecurityAuditor.auditAndSanitizeQuery(
            level: "super_critical"
        )

        #expect(report.passed)
        #expect(report.violations.contains { $0.code == "INVALID_LOG_LEVEL" })
    }
}
