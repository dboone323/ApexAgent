import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 93 — Simctl Tool Simulator State Lifecycle Gate Tests")
struct SimctlSecurityAuditorTests {

    let sampleUUID = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"

    @Test("Valid boot command with RFC 4122 UUID passes security audit with 100% score")
    func validBootPasses() {
        let report = SimctlSecurityAuditor.auditSimctlRequest(
            action: "boot",
            deviceId: sampleUUID,
            currentlyBootedCount: 0,
            maxBootedCount: 2
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.sanitizedArgs == ["simctl", "boot", sampleUUID])
        #expect(report.violations.isEmpty)
    }

    @Test("Valid install and launch actions construct correct argument vectors")
    func validInstallAndLaunchPass() {
        let installReport = SimctlSecurityAuditor.auditSimctlRequest(
            action: "install",
            deviceId: sampleUUID,
            appPath: "/tmp/Build/Products/Debug-iphonesimulator/MyApp.app"
        )
        #expect(installReport.passed)
        #expect(installReport.sanitizedArgs?.contains(sampleUUID) == true)
        #expect(installReport.sanitizedArgs?.contains("/tmp/Build/Products/Debug-iphonesimulator/MyApp.app") == true)

        let launchReport = SimctlSecurityAuditor.auditSimctlRequest(
            action: "launch",
            deviceId: sampleUUID,
            bundleId: "com.example.MyApp"
        )
        #expect(launchReport.passed)
        #expect(launchReport.sanitizedArgs == ["simctl", "launch", sampleUUID, "com.example.MyApp"])
    }

    @Test("Exceeding concurrent booted simulators ceiling is rejected")
    func concurrentBootCeilingEnforced() {
        let report = SimctlSecurityAuditor.auditSimctlRequest(
            action: "boot",
            deviceId: sampleUUID,
            currentlyBootedCount: 2,
            maxBootedCount: 2
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "CONCURRENT_BOOT_LIMIT_EXCEEDED" })
    }

    @Test("Invalid UDID syntax fails with INVALID_DEVICE_UDID")
    func invalidUDIDFails() {
        let report = SimctlSecurityAuditor.auditSimctlRequest(
            action: "boot",
            deviceId: "not-a-valid-uuid"
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "INVALID_DEVICE_UDID" })
    }

    @Test("Non-.app file path for install action fails with INVALID_APP_BUNDLE_EXTENSION")
    func invalidAppPathFails() {
        let report = SimctlSecurityAuditor.auditSimctlRequest(
            action: "install",
            deviceId: sampleUUID,
            appPath: "/tmp/MyApp.zip"
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "INVALID_APP_BUNDLE_EXTENSION" })
    }

    @Test("Invalid bundle ID syntax fails with INVALID_BUNDLE_ID_SYNTAX")
    func invalidBundleIdFails() {
        let report = SimctlSecurityAuditor.auditSimctlRequest(
            action: "launch",
            deviceId: sampleUUID,
            bundleId: "invalid_bundle_no_dots"
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "INVALID_BUNDLE_ID_SYNTAX" })
    }

    @Test("Simulator lifecycle state transitions are enforced correctly")
    func simulatorLifecycleTransitions() {
        #expect(SimctlSecurityAuditor.validateStateTransition(from: .shutdown, to: .booting))
        #expect(SimctlSecurityAuditor.validateStateTransition(from: .shutdown, to: .booted))
        #expect(SimctlSecurityAuditor.validateStateTransition(from: .booted, to: .shuttingDown))
        #expect(SimctlSecurityAuditor.validateStateTransition(from: .shuttingDown, to: .shutdown))

        // Invalid: Shutdown directly to Shutting Down
        #expect(!SimctlSecurityAuditor.validateStateTransition(from: .shutdown, to: .shuttingDown))
    }
}
