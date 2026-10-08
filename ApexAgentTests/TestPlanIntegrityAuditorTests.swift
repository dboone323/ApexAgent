import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Xcode Test Plan Integrity Auditor Tests (Batch 47)")
struct TestPlanIntegrityAuditorTests {

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Live repository ApexAgent-UnitTests.xctestplan and ApexAgent-UITests.xctestplan pass all integrity checks")
    func liveRepositoryTestPlansPassIntegrityAudit() {
        let report = TestPlanIntegrityAuditor.auditRepositoryTestPlans(atRepoRoot: repoRootURL)
        #expect(report.passed, "Findings: \(report.findings)")
        #expect(report.plans.count == 2)
        #expect(report.plans[0].testModeEnvironmentEnabled)
        #expect(report.plans[0].testTimeoutsEnabled)
        #expect(report.plans[0].coverageTargetNames.contains("ApexAgentCore"))
        #expect(report.plans[0].testTargetNames == [
            "ApexAgentTests",
            "ApexAgentIntelligenceTests",
            "ApexAgentContainerTests",
        ])
        #expect(report.plans[1].testTargetNames == ["ApexAgentUITests"])
        #expect(report.toMarkdown().contains("Xcode Test Plan Integrity Audit (`PASS`)"))
    }

    @Test("Flags missing APEX_TEST_MODE=1, disabled timeouts, missing targets, and skippedTests")
    func flagsDriftedTestPlanConfigurations() throws {
        let driftedUnitJSON = """
        {
          "configurations": [
            { "name": "Default", "options": { "environmentVariableEntries": [] } }
          ],
          "defaultOptions": {
            "testTimeoutsEnabled": false,
            "defaultTestExecutionTimeAllowance": 0,
            "maximumTestExecutionTimeAllowance": 999
          },
          "testTargets": [
            {
              "target": { "name": "ApexAgentTests" },
              "skippedTests": ["SomeFlakyTest/testFoo()"]
            }
          ],
          "version": 1
        }
        """

        let driftedUnit = try TestPlanIntegrityAuditor.parseTestPlan(
            data: Data(driftedUnitJSON.utf8),
            name: "DriftedUnit.xctestplan"
        )
        let validUI = ParsedTestPlan(
            name: "ApexAgent-UITests.xctestplan",
            version: 1,
            testModeEnvironmentEnabled: true,
            testTimeoutsEnabled: true,
            defaultTimeoutSeconds: 120,
            maximumTimeoutSeconds: 240,
            coverageTargetNames: [],
            testTargetNames: ["ApexAgentUITests"],
            skippedTests: []
        )

        let report = TestPlanIntegrityAuditor.evaluate(unitPlan: driftedUnit, uiPlan: validUI)
        #expect(!report.passed)
        #expect(report.findings.contains { $0.contains("APEX_TEST_MODE=1") })
        #expect(report.findings.contains { $0.contains("testTimeoutsEnabled") })
        #expect(report.findings.contains { $0.contains("skippedTests") })
        #expect(report.findings.contains { $0.contains("ApexAgentCore") })
        #expect(report.findings.contains { $0.contains("ApexAgentIntelligenceTests") })
    }
}
