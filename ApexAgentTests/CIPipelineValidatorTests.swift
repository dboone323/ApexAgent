import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 35 — CI Pipeline & xcresult Quality Gate Synchronization Tests")
struct CIPipelineValidatorTests {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Live repository CI workflow (.gitlab-ci.yml) and Makefile pass full CI pipeline synchronization audit")
    func liveRepositoryPipelineAuditPasses() {
        let report = CIPipelineValidator.validateRepositoryPipeline(atRepoRoot: repoRoot)
        #expect(report.passed, "\(report.formatSummary())")
        #expect(report.missingWorkflowSteps.isEmpty)
        #expect(report.missingMakefileTargets.isEmpty)
        #expect(report.formatSummary().hasPrefix("PASS:"))
    }

    @Test("Validator detects missing CI workflow steps and missing Makefile targets")
    func detectsPipelineDrift() {
        let incompleteYAML = """
        name: Swift CI
        jobs:
          build:
            steps:
              - run: swift build -c release
        """
        let missingSteps = CIPipelineValidator.validateCIWorkflowYAML(incompleteYAML)
        #expect(missingSteps.contains("make hygiene"))
        #expect(missingSteps.contains("make lint"))
        #expect(missingSteps.contains("apexflow"))
        #expect(missingSteps.contains("xcodebuild test"))
        #expect(missingSteps.contains("xcresult-report.sh"))

        let incompleteMakefile = """
        SWIFT ?= xcrun swift
        build:
        \t$(SWIFT) build
        test:
        \t$(SWIFT) test
        """
        let missingTargets = CIPipelineValidator.validateMakefile(incompleteMakefile)
        #expect(missingTargets.contains("hygiene"))
        #expect(missingTargets.contains("lint"))
        #expect(missingTargets.contains("pre-push"))
        #expect(missingTargets.contains("full"))
        #expect(missingTargets.contains("test-deep"))
    }

    @Test("parseXCResultSummaryJSON parses real xcresulttool summary JSON and enforces quality gate")
    func parsesXCResultSummaryAndEvaluatesQualityGate() throws {
        let passingJSON = """
        {
          "devicesAndConfigurations" : [
            {
              "device" : {
                "architecture" : "arm64",
                "deviceName" : "My Mac",
                "osVersion" : "27.2",
                "platform" : "macOS"
              },
              "expectedFailures" : 0,
              "failedTests" : 0,
              "passedTests" : 1072,
              "skippedTests" : 0
            }
          ],
          "environmentDescription" : "ApexAgent-UnitTests · Built with macOS 27.2",
          "expectedFailures" : 0,
          "failedTests" : 0,
          "finishTime" : 1791471400.0,
          "passedTests" : 1072,
          "result" : "Passed",
          "skippedTests" : 0,
          "startTime" : 1791471330.0,
          "title" : "Test - ApexAgent-UnitTests",
          "totalTestCount" : 1072
        }
        """

        let passingReport = try CIPipelineValidator.parseXCResultSummaryJSON(passingJSON)
        #expect(passingReport.result == "Passed")
        #expect(passingReport.totalTestCount == 1072)
        #expect(passingReport.passedTests == 1072)
        #expect(passingReport.failedTests == 0)
        #expect(passingReport.meetsQualityGate)
        #expect(abs(passingReport.passRatePercent - 100.0) < 0.001)

        let failingJSON = """
        {
          "expectedFailures" : 0,
          "failedTests" : 2,
          "passedTests" : 1070,
          "result" : "Failed",
          "skippedTests" : 0,
          "totalTestCount" : 1072
        }
        """
        let failingReport = try CIPipelineValidator.parseXCResultSummaryJSON(failingJSON)
        #expect(!failingReport.meetsQualityGate)
        #expect(failingReport.failedTests == 2)
        #expect(failingReport.passRatePercent < 100.0)
    }
}
