import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Code Coverage Gate Tests (Batch 41)")
struct CodeCoverageGateTests {

    @Test("Parses llvm-cov export JSON and enforces overall and changed-file coverage floors")
    func parsesLLVMCovAndEnforcesThresholds() throws {
        let llvmCovJSON = """
        {
          "version": "2.0.1",
          "type": "llvm.coverage.json.export",
          "data": [
            {
              "totals": {
                "lines": { "count": 200, "covered": 160, "percent": 80.0 },
                "functions": { "count": 40, "covered": 34, "percent": 85.0 }
              },
              "files": [
                {
                  "filename": "/workspace/ApexAgent/Models/CodeCoverageGate.swift",
                  "summary": {
                    "lines": { "count": 100, "covered": 92, "percent": 92.0 },
                    "functions": { "count": 10, "covered": 9, "percent": 90.0 }
                  }
                },
                {
                  "filename": "/workspace/ApexAgent/Security/DependencyLockAuditor.swift",
                  "summary": {
                    "lines": { "count": 100, "covered": 68, "percent": 68.0 },
                    "functions": { "count": 30, "covered": 25, "percent": 83.33 }
                  }
                }
              ]
            }
          ]
        }
        """

        let snapshot = try CodeCoverageGate.parseCoverageJSON(Data(llvmCovJSON.utf8))
        #expect(snapshot.format == "llvm-cov")
        #expect(snapshot.totalCoveredLines == 160)
        #expect(snapshot.totalExecutableLines == 200)
        #expect(snapshot.lineCoveragePercent == 80.0)
        #expect(snapshot.files.count == 2)

        // 1. Passing evaluation when changed file has 92% >= 75% floor
        let passingEval = CodeCoverageGate.evaluate(
            snapshot: snapshot,
            changedFilePaths: ["ApexAgent/Models/CodeCoverageGate.swift"],
            minimumOverallLineCoverage: 70.0,
            minimumOverallFunctionCoverage: 75.0,
            minimumChangedFileCoverage: 75.0
        )
        #expect(passingEval.passed)
        #expect(passingEval.evaluatedChangedFiles.count == 1)
        #expect(passingEval.underCoveredChangedFiles.isEmpty)
        #expect(passingEval.toMarkdown().contains("Code Coverage Gate (`PASS`)"))

        // 2. Failing evaluation when changed file has 68% < 75% floor
        let failingEval = CodeCoverageGate.evaluate(
            snapshot: snapshot,
            changedFilePaths: ["ApexAgent/Security/DependencyLockAuditor.swift"],
            minimumOverallLineCoverage: 70.0,
            minimumOverallFunctionCoverage: 75.0,
            minimumChangedFileCoverage: 75.0
        )
        #expect(!failingEval.passed)
        #expect(failingEval.underCoveredChangedFiles.count == 1)
        #expect(failingEval.findings.contains { $0.contains("DependencyLockAuditor.swift") })
    }

    @Test("Parses xccov view --report --json format and skips test bundle targets")
    func parsesXCCovJSONFormat() throws {
        let xccovJSON = """
        {
          "coveredLines": 850,
          "executableLines": 1000,
          "lineCoverage": 0.85,
          "targets": [
            {
              "name": "ApexAgentCore.framework",
              "files": [
                {
                  "path": "/Users/dev/ApexAgent/ApexAgent/Models/ApexCLIRouter.swift",
                  "coveredLines": 90,
                  "executableLines": 100,
                  "lineCoverage": 0.90,
                  "functions": [
                    { "name": "runDoctor", "executionCount": 4 },
                    { "name": "runHelp", "executionCount": 2 }
                  ]
                }
              ]
            },
            {
              "name": "ApexAgentTests.xctest",
              "files": [
                {
                  "path": "/Users/dev/ApexAgent/ApexAgentTests/ApexCLIRouterTests.swift",
                  "coveredLines": 50,
                  "executableLines": 50,
                  "lineCoverage": 1.0,
                  "functions": []
                }
              ]
            }
          ]
        }
        """

        let snapshot = try CodeCoverageGate.parseCoverageJSON(Data(xccovJSON.utf8))
        #expect(snapshot.format == "xccov")
        #expect(snapshot.lineCoveragePercent == 85.0)
        // Test target (.xctest) is excluded from production file metrics
        #expect(snapshot.files.count == 1)
        #expect(snapshot.files.first?.functionCoveragePercent == 100.0)
    }

    @Test("Rejects malformed or unsupported JSON coverage payloads")
    func rejectsInvalidCoveragePayloads() {
        #expect(throws: CodeCoverageGateError.invalidJSON) {
            _ = try CodeCoverageGate.parseCoverageJSON(Data("not json".utf8))
        }
        #expect(throws: CodeCoverageGateError.unsupportedCoverageFormat) {
            _ = try CodeCoverageGate.parseCoverageJSON(Data("{\"foo\": \"bar\"}".utf8))
        }
    }
}
