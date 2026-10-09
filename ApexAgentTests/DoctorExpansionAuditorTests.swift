import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 99 — Unified 12-Check Doctor Subsystem Matrix Tests")
struct DoctorExpansionAuditorTests {

    @Test("DoctorExpansionAuditor live audit verifies all 8 autonomous hardening gates successfully")
    func liveAuditPassesAllHardeningGates() {
        let report = DoctorExpansionAuditor.auditHardeningSubsystems()

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)

        let expectedAuditors = [
            "BrowserSecurityAuditor",
            "VisualPerceptionAuditor",
            "SimctlSecurityAuditor",
            "AppleScriptSecurityAuditor",
            "ProductivityAutomationAuditor",
            "CompanionPairingSecurityAuditor",
            "SwarmConcurrencyAuditor",
            "TurnWatchdogAuditor"
        ]

        for auditor in expectedAuditors {
            #expect(report.activeAuditors.contains(auditor))
        }
    }

    @Test("ApexCLIRouter.runDoctor incorporates the 12th autonomous hardening check and passes cleanly")
    func unified12CheckDoctorPasses() {
        let report = ApexCLIRouter.runDoctor()

        #expect(report.overallPassed)
        #expect(report.checks.count == 12)

        let check12 = report.checks.first { $0.id == "autonomous_hardening_matrix" }
        #expect(check12 != nil)
        #expect(check12?.passed == true)
        #expect(check12?.title == "Autonomous Hardening & Runtime Watchdog Matrix")
        #expect(check12?.detail.contains("12-check matrix complete") == true)
    }
}
