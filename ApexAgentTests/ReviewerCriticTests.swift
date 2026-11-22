import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Reviewer Critic Tests (Issue #103, G3)")
@MainActor
struct ReviewerCriticTests {

    @Test("Reviewer catches a planted defect with cited artifact and location")
    func testReviewerCatchesPlantedDefectWithCitedLocation() async {
        let reviewer = ReviewerAgent()
        let fileContent = """
        import Foundation

        public struct FeatureConfig {
            // Defect: timeout is set to 10 instead of required 60
            public static let timeoutSeconds = 10
        }
        """
        let artifact = ReviewArtifact(path: "FeatureConfig.swift", content: fileContent)
        let claims = [
            ReviewClaim(
                claimText: "FeatureConfig sets timeout to 60s",
                requiredArtifactPath: "FeatureConfig.swift",
                contradictionPattern: "timeoutSeconds = 10"
            ),
            ReviewClaim(
                claimText: "FeatureDocumentation.md explains config options",
                requiredArtifactPath: "FeatureDocumentation.md"
            )
        ]
        let request = ReviewRequest(
            requestDescription: "Configure timeout to 60s and write documentation",
            claims: claims,
            requiredArtifactPaths: ["FeatureConfig.swift", "FeatureDocumentation.md"],
            artifacts: [artifact]
        )

        let report = await reviewer.review(request: request, recordToTrace: false)

        #expect(!report.isPassed)
        #expect(report.verdict == .fail)
        #expect(report.findings.count == 2)

        let contradictionFinding = report.findings.first { $0.kind == .contradictoryArtifact }
        #expect(contradictionFinding != nil)
        #expect(contradictionFinding?.artifactPath == "FeatureConfig.swift")
        #expect(contradictionFinding?.location == "FeatureConfig.swift:5")

        let missingFinding = report.findings.first { $0.kind == .missingRequiredArtifact }
        #expect(missingFinding != nil)
        #expect(missingFinding?.artifactPath == "FeatureDocumentation.md")
        #expect(missingFinding?.location == "FeatureDocumentation.md:1")
    }

    @Test("Reviewer passes clean work with empty findings and records pass verdict in trace")
    func testReviewerPassesCleanWorkAndRecordsTrace() async {
        let reviewer = ReviewerAgent()
        let fileContent = """
        import Foundation

        public struct AppEnvironment {
            public static let environmentName = "production"
            public static let portNumber = 8080
        }
        """
        let artifact = ReviewArtifact(path: "AppEnvironment.swift", content: fileContent)
        let claims = [
            ReviewClaim(
                claimText: "Environment is production",
                requiredArtifactPath: "AppEnvironment.swift",
                expectedPattern: "environmentName = \"production\""
            ),
            ReviewClaim(
                claimText: "Port is 8080",
                requiredArtifactPath: "AppEnvironment.swift",
                expectedPattern: "portNumber = 8080"
            )
        ]
        let request = ReviewRequest(
            requestDescription: "Set production environment and port 8080",
            claims: claims,
            requiredArtifactPaths: ["AppEnvironment.swift"],
            artifacts: [artifact]
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgent-ReviewTraceTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runId = RunTrace.generateRunId()
        RunTraceManager.shared.startRun(runId: runId, workspacePath: tempDir.path)

        let report = await reviewer.review(request: request, recordToTrace: true)

        let activeTrace = RunTraceManager.shared.activeRecorder?.currentTraceSnapshot()
        RunTraceManager.shared.endRun(runId: runId)

        #expect(report.isPassed)
        #expect(report.verdict == .pass)
        #expect(report.findings.isEmpty)

        let reviewEvent = activeTrace?.events.first { $0.kind == .reviewCheckpoint }
        #expect(reviewEvent != nil)
        #expect(reviewEvent?.reviewVerdict == "pass")
        #expect(reviewEvent?.findingsCount == 0)
    }

    @Test("Reviewer reports missing required artifact as finding rather than silently passing")
    func testReviewerReportsMissingArtifactAsFinding() async {
        let reviewer = ReviewerAgent()
        let request = ReviewRequest(
            requestDescription: "Build release bundle at dist/release.zip",
            claims: [],
            requiredArtifactPaths: ["dist/release.zip"],
            artifacts: []
        )

        let report = await reviewer.review(request: request, recordToTrace: false)

        #expect(!report.isPassed)
        #expect(report.verdict == .fail)
        #expect(report.findings.count == 1)
        #expect(report.findings[0].kind == .missingRequiredArtifact)
        #expect(report.findings[0].artifactPath == "dist/release.zip")
        #expect(report.findings[0].location == "dist/release.zip:1")
    }

    @Test("Reviewer checkpoint fail verdict blocks done claim in ConfirmCompletionTool workflow")
    func testReviewerFailVerdictBlocksDoneClaim() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgent-DoneBlockTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = tempDir.path

        let tool = ConfirmCompletionTool(orchestrator: orchestrator)
        // Intentionally reference a non-existent file and failing verification results
        let args = ConfirmCompletionTool.Arguments(
            summary: "Completed billing engine update",
            filesModified: "MissingBillingService.swift",
            verificationResults: "Unit tests failed with exit code 1"
        )

        let result = try await tool.call(arguments: args)

        #expect(result.contains("REVIEW_BLOCKED:"))
        #expect(result.contains("Verdict: FAIL"))
        #expect(result.contains("MissingBillingService.swift:1"))
        #expect(!result.contains("SUCCESS: The user has approved task completion"))
    }

    @Test("ReviewArtifactsTool executes direct inspection and returns formatted report")
    func testReviewArtifactsToolExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = ReviewArtifactsTool(orchestrator: orchestrator)

        let artifactsJSON = """
        [{"path": "Service.swift", "content": "class Service { let active = true }"}]
        """
        let claimsJSON = """
        [{"claimText": "Service is active", "requiredArtifactPath": "Service.swift", "expectedPattern": "active = true"}]
        """

        let args = ReviewArtifactsTool.Arguments(
            request: "Verify service active flag",
            artifactPaths: "Service.swift",
            claimsJSON: claimsJSON,
            artifactsJSON: artifactsJSON
        )

        let toolResult = try await tool.call(arguments: args)

        #expect(toolResult.contains("=== Reviewer / Critic Verdict: PASS ==="))
        #expect(toolResult.contains("Findings: None"))
    }
}
