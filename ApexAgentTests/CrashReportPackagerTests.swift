import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Crash Report Packager Tests")
struct CrashReportPackagerTests {
    @Test("Anonymizes user home directories and sensitive file paths")
    func anonymizeHomePaths() {
        let rawPath = "Thread crashed while accessing /Users/john_doe/Library/Caches/ApexAgent/model.bin"
        let scrubbed = CrashReportPackager.scrubText(rawPath)

        #expect(!scrubbed.contains("john_doe"))
        #expect(scrubbed.contains("/Users/<anonymized>/Library/Caches/ApexAgent/model.bin"))
    }

    @Test("Redacts IP addresses and sensitive API key secrets")
    func redactIPAndSecrets() {
        let rawLog = "Connection to 192.168.1.144 failed with token sk-ant-api03-abcdef1234567890"
        let scrubbed = CrashReportPackager.scrubText(rawLog)

        #expect(!scrubbed.contains("192.168.1.144"))
        #expect(scrubbed.contains("[REDACTED_IP]"))
        #expect(!scrubbed.contains("sk-ant-api03"))
        #expect(scrubbed.contains("[REDACTED_SECRET]"))
    }

    @Test("Packages payloads into signed bundle with valid SHA-256 digest")
    func packageAndVerifyBundle() {
        let crashPayload = MetricDiagnosticPayload(
            kind: .crash,
            terminationCategory: "SIGSEGV at /Users/developer/Code/ApexAgent/main.swift",
            signal: 11,
            exceptionCode: 0xbaadcafe
        )

        let hangPayload = MetricDiagnosticPayload(
            kind: .hang,
            hangDurationSeconds: 4.5
        )

        let bundle = CrashReportPackager.package(
            payloads: [crashPayload, hangPayload],
            appVersion: "1.2.0",
            osVersion: "macOS 27.1"
        )

        #expect(bundle.entries.count == 2)
        #expect(!bundle.sha256Digest.isEmpty)
        #expect(!bundle.bundleSignature.isEmpty)

        // Verify that the path was scrubbed in the packaged entry
        let crashEntry = bundle.entries.first { $0.kind == .crash }
        #expect(crashEntry?.terminationCategory?.contains("/Users/<anonymized>") == true)
        #expect(crashEntry?.terminationCategory?.contains("developer") == false)

        // Cryptographic verification
        let isValid = CrashReportPackager.verify(bundle: bundle)
        #expect(isValid)

        // JSON serialization verification
        let json = bundle.toJSON()
        #expect(json.contains("SIGSEGV"))
        #expect(json.contains("sha256Digest"))

        // Markdown export verification
        let md = bundle.toMarkdown()
        #expect(md.contains("Packaged Crash & Diagnostic Bundle"))
        #expect(md.contains("SIG11"))
    }

    @Test("Detects bundle tampering and fails verification")
    func tamperDetection() {
        let payload = MetricDiagnosticPayload(kind: .crash, signal: 9)
        let bundle = CrashReportPackager.package(payloads: [payload])

        #expect(CrashReportPackager.verify(bundle: bundle))

        // Create tampered bundle with altered signal
        let tamperedEntries = [
            AnonymizedDiagnosticEntry(
                id: bundle.entries[0].id,
                occurredAt: bundle.entries[0].occurredAt,
                kind: .crash,
                signal: 15 // altered
            )
        ]

        let tamperedBundle = CrashReportBundle(
            metadata: bundle.metadata,
            entries: tamperedEntries,
            sha256Digest: bundle.sha256Digest,
            bundleSignature: bundle.bundleSignature
        )

        let isValid = CrashReportPackager.verify(bundle: tamperedBundle)
        #expect(!isValid)
    }
}
