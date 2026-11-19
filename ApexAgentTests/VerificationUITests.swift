import XCTest
import Foundation
@testable import ApexAgentCore

final class VerificationUITests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        RunTraceManager.shared.reset()
    }

    override func tearDown() async throws {
        RunTraceManager.shared.reset()
        try await super.tearDown()
    }

    // MARK: - Test 1: Artifact List Rendering from Real Run Trace

    func test_artifactList_rendersEveryArtifactFromRealRunTrace_withCorrectState() throws {
        let runId = "test-run-artifacts-\(UUID().uuidString.prefix(8))"
        let traceEvents: [RunTraceEvent] = [
            RunTraceEvent.modelCall(
                sequence: 1,
                model: "appleOnDevice",
                prompt: "Execute plan to fix compilation errors in Package.swift"
            ),
            RunTraceEvent.toolCall(
                sequence: 2,
                toolName: "apply_patch",
                arguments: "Package.swift patch",
                result: "1 hunk applied"
            ),
            RunTraceEvent.approval(
                sequence: 3,
                toolName: "apply_patch",
                approved: true,
                source: .autoReview,
                rule: "safe_patch"
            )
        ]

        let trace = RunTrace(
            id: runId,
            status: "completed",
            events: traceEvents,
            metadata: [
                "plan": "Step 1: Check dependencies\nStep 2: Apply patch\nStep 3: Verify build",
                "diff": "--- a/Package.swift\n+++ b/Package.swift\n+ // fixed",
                "checklist": "✓ Dependencies checked\n✓ Patch applied\n✓ Build clean"
            ]
        )

        let artifacts = VerificationArtifactExtractor.extractArtifacts(from: trace)

        // Must produce plan, diff, and checklist
        XCTAssertEqual(artifacts.count, 3, "Expected 3 extracted artifacts for plan, diff, and checklist")

        let planArtifact = try XCTUnwrap(artifacts.first { $0.kind == .plan })
        XCTAssertEqual(planArtifact.effectiveStatus, .passed)
        XCTAssertTrue(planArtifact.content?.contains("Step 1") == true)

        let diffArtifact = try XCTUnwrap(artifacts.first { $0.kind == .diff })
        XCTAssertEqual(diffArtifact.effectiveStatus, .passed)
        XCTAssertTrue(diffArtifact.content?.contains("Package.swift") == true)

        let checklistArtifact = try XCTUnwrap(artifacts.first { $0.kind == .checklist })
        XCTAssertEqual(checklistArtifact.effectiveStatus, .passed)
        XCTAssertTrue(checklistArtifact.content?.contains("Build clean") == true)
    }

    // MARK: - Test 2: Comment Attachment & Disk Reload Persistence

    func test_commentAttachesToRightArtifact_andSurvivesReloadFromDiskTrace() throws {
        let tempWS = FileManager.default.temporaryDirectory.appendingPathComponent("ApexAgent-CommentTest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempWS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempWS) }

        let runId = "run-comment-persist-\(UUID().uuidString.prefix(8))"
        let initialPlan = VerificationArtifact(
            id: "\(runId)-plan",
            runId: runId,
            kind: .plan,
            status: .passed,
            content: "Initial plan content"
        )
        let initialDiff = VerificationArtifact(
            id: "\(runId)-diff",
            runId: runId,
            kind: .diff,
            status: .passed,
            content: "Initial diff content"
        )

        var trace = RunTrace(id: runId, status: "completed")
        trace.artifacts = [initialPlan, initialDiff]
        try RunTraceStorage.saveTrace(trace, workspacePath: tempWS.path)

        // Attach comment to diff artifact
        let commentText = "LGTM: verified hunk applies cleanly."
        let commentAuthor = "Daniel"
        let comment = VerificationComment(author: commentAuthor, text: commentText)

        let updatedArtifact = try RunTraceManager.shared.attachComment(
            to: initialDiff.id,
            runId: runId,
            comment: comment,
            workspacePath: tempWS.path
        )
        XCTAssertEqual(updatedArtifact.comments.count, 1)
        XCTAssertEqual(updatedArtifact.comments.first?.text, commentText)
        XCTAssertEqual(updatedArtifact.comments.first?.author, commentAuthor)

        // Cold reload from disk
        guard let reloadedTrace = try RunTraceStorage.loadTrace(for: runId, workspacePath: tempWS.path) else {
            XCTFail("Failed to reload trace from disk")
            return
        }

        let reloadedDiff = try XCTUnwrap(reloadedTrace.artifacts.first { $0.id == initialDiff.id })
        XCTAssertEqual(reloadedDiff.comments.count, 1)
        XCTAssertEqual(reloadedDiff.comments.first?.text, commentText)
        XCTAssertEqual(reloadedDiff.comments.first?.author, commentAuthor)

        let reloadedPlan = try XCTUnwrap(reloadedTrace.artifacts.first { $0.id == initialPlan.id })
        XCTAssertEqual(reloadedPlan.comments.count, 0, "Plan artifact should have 0 comments")
    }

    // MARK: - Test 3: Artifact with No Content is Missing, Not Passed

    func test_artifactWithNoContent_isShownAsMissing_notAsPassed() {
        // Case 1: nil content and nil path
        let emptyArtifact = VerificationArtifact(
            id: "art-empty-1",
            runId: "run-1",
            kind: .plan,
            status: .passed, // Intentionally request passed
            content: nil,
            path: nil
        )
        XCTAssertEqual(emptyArtifact.status, .missing, "Artifact with nil content and path must be missing")
        XCTAssertEqual(emptyArtifact.effectiveStatus, .missing)

        // Case 2: empty string content
        let whitespaceArtifact = VerificationArtifact(
            id: "art-empty-2",
            runId: "run-1",
            kind: .diff,
            status: .passed,
            content: "    \n\t   ",
            path: ""
        )
        XCTAssertEqual(whitespaceArtifact.status, .missing, "Artifact with whitespace content must be missing")
        XCTAssertEqual(whitespaceArtifact.effectiveStatus, .missing)

        // Case 3: non-existent file path
        let nonexistentFileArtifact = VerificationArtifact(
            id: "art-empty-3",
            runId: "run-1",
            kind: .screenshot,
            status: .passed,
            content: nil,
            path: "/tmp/nonexistent-file-\(UUID().uuidString).png"
        )
        XCTAssertEqual(nonexistentFileArtifact.status, .missing, "Artifact with missing file must be missing")
        XCTAssertEqual(nonexistentFileArtifact.effectiveStatus, .missing)

        // Case 4: Valid content should keep passed status
        let validArtifact = VerificationArtifact(
            id: "art-valid",
            runId: "run-1",
            kind: .checklist,
            status: .passed,
            content: "✓ All checks passed"
        )
        XCTAssertEqual(validArtifact.status, .passed)
        XCTAssertEqual(validArtifact.effectiveStatus, .passed)
    }

    // MARK: - Test 4: Extraction from Real EvalTrialExecution

    func test_extractArtifactsFromRealEvalTrialExecution_producesPlanDiffAndChecklist() {
        let taskId = "task-eval-extraction-001"
        let task = EvalTask(
            id: taskId,
            title: "Generate greeting module",
            prompt: "Write a greeting python script hello.py that outputs hello world",
            expectedOutcome: EvalExpectedOutcome(
                description: "Script hello.py exists and returns exit code 0",
                expectedExitCode: 0,
                requiredFilePaths: ["hello.py"]
            ),
            graderType: .deterministicExact
        )

        let trial = EvalTrialExecution(
            trialId: "trial-abc-123",
            taskId: taskId,
            trialIndex: 1,
            containerId: "cnt-456",
            stdout: "Hello world\n",
            exitCode: 0,
            duration: 0.42,
            workspaceFiles: ["hello.py": "print('Hello world')\n"]
        )

        let verdict = EvalGradeVerdict.pass(reason: "Exact output match")
        let artifacts = VerificationArtifactExtractor.extractArtifacts(from: trial, task: task, verdict: verdict)

        XCTAssertEqual(artifacts.count, 3)

        let plan = try? XCTUnwrap(artifacts.first { $0.kind == .plan })
        XCTAssertTrue(plan?.content?.contains("Generate greeting module") == true)
        XCTAssertEqual(plan?.effectiveStatus, .passed)

        let diff = try? XCTUnwrap(artifacts.first { $0.kind == .diff })
        XCTAssertTrue(diff?.content?.contains("hello.py") == true)
        XCTAssertEqual(diff?.effectiveStatus, .passed)

        let checklist = try? XCTUnwrap(artifacts.first { $0.kind == .checklist })
        XCTAssertTrue(checklist?.content?.contains("Exit Code 0 == 0") == true)
        XCTAssertEqual(checklist?.effectiveStatus, .passed)
    }

    // MARK: - Test 5: UI ViewModel Selects Run, Attaches Comment, and Reloads

    @MainActor
    func test_verificationUIViewModel_selectsRun_attachesComment_andReloadsFromDisk() throws {
        let tempWS = FileManager.default.temporaryDirectory.appendingPathComponent("ApexAgent-UIModelTest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempWS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempWS) }

        let runId = "run-vm-test-\(UUID().uuidString.prefix(8))"
        let artifact = VerificationArtifact(
            id: "\(runId)-checklist",
            runId: runId,
            kind: .checklist,
            status: .passed,
            content: "✓ 100% tests passing"
        )
        var trace = RunTrace(id: runId, status: "completed")
        trace.artifacts = [artifact]
        try RunTraceStorage.saveTrace(trace, workspacePath: tempWS.path)

        let viewModel = RunVerificationViewModel(workspacePath: tempWS.path, initialRunId: runId)
        XCTAssertEqual(viewModel.selectedRunId, runId)
        XCTAssertEqual(viewModel.artifacts.count, 1)

        // Attach comment through ViewModel
        let commentText = "ViewModel comment test passed."
        viewModel.newCommentTexts[artifact.id] = commentText
        viewModel.commentAuthor = "VerifierUI"
        viewModel.attachComment(to: artifact.id)

        XCTAssertEqual(viewModel.artifacts.first?.comments.count, 1)
        XCTAssertEqual(viewModel.artifacts.first?.comments.first?.text, commentText)

        // Reload
        viewModel.reload()
        XCTAssertEqual(viewModel.artifacts.first?.comments.count, 1)
        XCTAssertEqual(viewModel.artifacts.first?.comments.first?.text, commentText)
    }
}
