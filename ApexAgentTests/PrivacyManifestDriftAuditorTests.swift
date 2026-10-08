import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Privacy Manifest Drift Auditor Tests (Batch 42)")
struct PrivacyManifestDriftAuditorTests {

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Live repository Required-Reason API usage in ApexAgent/ matches PrivacyInfo.xcprivacy declarations")
    func liveWorkspacePassesPrivacyManifestDriftAudit() {
        let report = PrivacyManifestDriftAuditor.auditWorkspace(at: repoRootURL)
        #expect(report.passed, "Findings: \(report.findings.map(\.message))")
        #expect(report.scannedFileCount > 100)
        #expect(report.detectedCategories.contains(PrivacyManifestInspector.userDefaultsCategory))
        #expect(report.missingCategories.isEmpty)
        #expect(report.invalidReasonCodes.isEmpty)
        #expect(report.toMarkdown().contains("Privacy Manifest Drift Audit (`PASS`)"))
    }

    @Test("Detects undeclared Required-Reason API categories used in Swift source")
    func detectsUndeclaredRequiredReasonAPICategories() {
        let manifest = PrivacyManifestReport(
            trackingEnabled: false,
            trackingDomains: [],
            accessedAPITypes: [
                PrivacyAccessedAPIDeclaration(
                    apiType: PrivacyManifestInspector.userDefaultsCategory,
                    reasons: ["CA92.1"]
                )
            ],
            collectedDataTypes: []
        )

        let bootCall = "let up = ProcessInfo.processInfo." + "systemUptime"
        let report = PrivacyManifestDriftAuditor.evaluate(
            manifest: manifest,
            sourcesByPath: [
                "ApexAgent/Services/TelemetryService.swift": """
                import Foundation
                func sampleUptime() {
                    \(bootCall)
                }
                """
            ]
        )

        #expect(!report.passed)
        #expect(report.missingCategories == [PrivacyManifestInspector.systemBootTimeCategory])
        #expect(report.findings.contains { $0.category == PrivacyManifestInspector.systemBootTimeCategory })
    }

    @Test("Flags invalid Apple Required-Reason codes and empty collected data purposes")
    func flagsInvalidReasonCodesAndEmptyCollectedPurposes() {
        let manifest = PrivacyManifestReport(
            trackingEnabled: false,
            trackingDomains: [],
            accessedAPITypes: [
                PrivacyAccessedAPIDeclaration(
                    apiType: PrivacyManifestInspector.userDefaultsCategory,
                    reasons: ["INVALID.99"]
                )
            ],
            collectedDataTypes: [
                PrivacyCollectedDataDeclaration(
                    dataType: "NSPrivacyCollectedDataTypeCrashData",
                    linked: false,
                    tracking: false,
                    purposes: []
                )
            ]
        )

        let report = PrivacyManifestDriftAuditor.evaluate(
            manifest: manifest,
            sourcesByPath: [
                "ApexAgent/UI/SettingsView.swift": "let x = UserDefaults.standard.bool(forKey: \"k\")"
            ]
        )

        #expect(!report.passed)
        #expect(report.invalidReasonCodes == ["\(PrivacyManifestInspector.userDefaultsCategory):INVALID.99"])
        #expect(report.findings.count == 2)
    }
}
