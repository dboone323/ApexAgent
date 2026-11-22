import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Issue #102: Isolated Parallel Workspaces & Merge Review Tests (G2)")
struct TaskWorkspaceTests {

    @Test("Two parallel tasks in separate workspaces cannot corrupt each other")
    func testParallelWorkspacesIsolationAndNonCorruption() async throws {
        let baseTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_parallel_workspaces_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: baseTemp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseTemp) }

        let wsA = try await TaskWorkspaceManager.shared.createWorkspace(
            taskID: "task-test-a-\(UUID().uuidString.prefix(6))",
            baseDirectory: baseTemp.path,
            isolationType: .ephemeralDirectory,
            retentionPolicy: .cleanupAlways
        )
        let wsB = try await TaskWorkspaceManager.shared.createWorkspace(
            taskID: "task-test-b-\(UUID().uuidString.prefix(6))",
            baseDirectory: baseTemp.path,
            isolationType: .ephemeralDirectory,
            retentionPolicy: .cleanupAlways
        )
        defer {
            Task {
                try? await TaskWorkspaceManager.shared.teardownWorkspace(taskID: wsA.id)
                try? await TaskWorkspaceManager.shared.teardownWorkspace(taskID: wsB.id)
            }
        }

        #expect(wsA.workspacePath != wsB.workspacePath)
        #expect(FileManager.default.fileExists(atPath: wsA.workspacePath))
        #expect(FileManager.default.fileExists(atPath: wsB.workspacePath))

        // Write a file exclusively in Task A
        let fileA = "task_a_data.txt"
        let contentA = "Data from Task A: 12345"
        try wsA.writeFile(relativePath: fileA, content: contentA)

        // Write a same-named file in Task B with completely different content
        let contentB = "Data from Task B: 67890"
        try wsB.writeFile(relativePath: fileA, content: contentB)

        // Verify Task A sees content A, Task B sees content B without corruption
        let readA = try wsA.readFile(relativePath: fileA)
        let readB = try wsB.readFile(relativePath: fileA)
        #expect(readA == contentA)
        #expect(readB == contentB)

        // Write a unique file in Task A; verify it does NOT exist in Task B
        let uniqueA = "unique_to_a.json"
        try wsA.writeFile(relativePath: uniqueA, content: "{\"task\":\"A\"}")
        #expect(wsA.fileExists(relativePath: uniqueA))
        #expect(!wsB.fileExists(relativePath: uniqueA))
    }

    @Test("A task cannot escape its workspace path via traversal or absolute paths")
    func testTaskCannotEscapeWorkspacePath() async throws {
        let baseTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_confinement_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: baseTemp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseTemp) }

        let ws = try await TaskWorkspaceManager.shared.createWorkspace(
            taskID: "task-confinement-\(UUID().uuidString.prefix(6))",
            baseDirectory: baseTemp.path,
            isolationType: .ephemeralDirectory,
            retentionPolicy: .cleanupAlways
        )
        defer {
            Task { try? await TaskWorkspaceManager.shared.teardownWorkspace(taskID: ws.id) }
        }

        // Relative path inside workspace succeeds
        let validRelative = "sub/folder/file.txt"
        let resolved = try ws.resolvePath(validRelative)
        #expect(resolved.hasPrefix(ws.workspacePath))

        // Directory traversal escape must throw TaskWorkspaceError.pathEscape
        #expect(throws: TaskWorkspaceError.self) {
            try ws.resolvePath("../escaped.txt")
        }

        #expect(throws: TaskWorkspaceError.self) {
            try ws.resolvePath("../../parent_escape.txt")
        }

        // Arbitrary system absolute path must throw
        #expect(throws: TaskWorkspaceError.self) {
            try ws.resolvePath("/etc/passwd")
        }

        #expect(throws: TaskWorkspaceError.self) {
            try ws.writeFile(relativePath: "../malicious.txt", content: "forbidden")
        }
    }

    @Test("Task workspace is cleaned up or retained per retention policy")
    func testRetentionPolicyCleanupAndRetained() async throws {
        let baseTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_retention_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: baseTemp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseTemp) }

        // 1. .cleanupAlways -> should be removed on teardown
        let wsCleanup = try await TaskWorkspaceManager.shared.createWorkspace(
            taskID: "task-cleanup-\(UUID().uuidString.prefix(6))",
            baseDirectory: baseTemp.path,
            isolationType: .ephemeralDirectory,
            retentionPolicy: .cleanupAlways
        )
        let cleanupPath = wsCleanup.workspacePath
        #expect(FileManager.default.fileExists(atPath: cleanupPath))
        try await TaskWorkspaceManager.shared.teardownWorkspace(taskID: wsCleanup.id, status: .succeeded)
        #expect(!FileManager.default.fileExists(atPath: cleanupPath))
        #expect(wsCleanup.state == .cleanedUp)

        // 2. .keepOnFailure -> should be retained if status is failed
        let wsKeepOnFail = try await TaskWorkspaceManager.shared.createWorkspace(
            taskID: "task-fail-\(UUID().uuidString.prefix(6))",
            baseDirectory: baseTemp.path,
            isolationType: .ephemeralDirectory,
            retentionPolicy: .keepOnFailure
        )
        let failPath = wsKeepOnFail.workspacePath
        #expect(FileManager.default.fileExists(atPath: failPath))
        try await TaskWorkspaceManager.shared.teardownWorkspace(taskID: wsKeepOnFail.id, status: .failed)
        #expect(FileManager.default.fileExists(atPath: failPath))
        #expect(wsKeepOnFail.state == .retained)
        try? FileManager.default.removeItem(atPath: failPath)

        // 3. .retained -> always retained
        let wsRetained = try await TaskWorkspaceManager.shared.createWorkspace(
            taskID: "task-retained-\(UUID().uuidString.prefix(6))",
            baseDirectory: baseTemp.path,
            isolationType: .ephemeralDirectory,
            retentionPolicy: .retained
        )
        let retainedPath = wsRetained.workspacePath
        #expect(FileManager.default.fileExists(atPath: retainedPath))
        try await TaskWorkspaceManager.shared.teardownWorkspace(taskID: wsRetained.id, status: .succeeded)
        #expect(FileManager.default.fileExists(atPath: retainedPath))
        #expect(wsRetained.state == .retained)
        try? FileManager.default.removeItem(atPath: retainedPath)
    }

    @Test("Merge/review step refuses to land work that fails review")
    func testMergeReviewStepRefusesToLandFailingReview() async throws {
        let baseTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_merge_reject_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: baseTemp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseTemp) }

        let targetLanding = baseTemp.appendingPathComponent("target_repo")
        try FileManager.default.createDirectory(at: targetLanding, withIntermediateDirectories: true)

        let ws = try await TaskWorkspaceManager.shared.createWorkspace(
            taskID: "task-reject-\(UUID().uuidString.prefix(6))",
            baseDirectory: baseTemp.path,
            isolationType: .ephemeralDirectory,
            retentionPolicy: .cleanupAlways
        )
        defer {
            Task { try? await TaskWorkspaceManager.shared.teardownWorkspace(taskID: ws.id) }
        }

        // Task creates a file
        let newFile = "UntestedFeature.swift"
        try ws.writeFile(relativePath: newFile, content: "// Untested code")

        // Merge/review proposal shows the change
        let proposal = try await TaskMergeReviewService.shared.createReviewProposal(for: ws.id)
        #expect(!proposal.changedFiles.isEmpty)
        #expect(proposal.changedFiles.contains { $0.path == newFile })
        #expect(proposal.isEligibleForLanding)

        // Reviewer rejects landing
        let result = try await TaskMergeReviewService.shared.land(
            taskID: ws.id,
            reviewerApproval: false,
            reviewerNotes: "Missing unit tests and fails safety check",
            targetWorkspacePath: targetLanding.path
        )

        #expect(!result.succeeded)
        #expect(result.reason.contains("rejected by reviewer"))
        #expect(result.landedFiles.isEmpty)

        // Target workspace must NOT have the file
        let landedFilePath = targetLanding.appendingPathComponent(newFile).path
        #expect(!FileManager.default.fileExists(atPath: landedFilePath))
        #expect(ws.state == .rejected)
    }

    @Test("Merge/review step lands approved changes cleanly into target workspace")
    func testMergeReviewStepLandsApprovedChangesCleanly() async throws {
        let baseTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_merge_approve_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: baseTemp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseTemp) }

        let targetLanding = baseTemp.appendingPathComponent("target_repo")
        try FileManager.default.createDirectory(at: targetLanding, withIntermediateDirectories: true)

        let ws = try await TaskWorkspaceManager.shared.createWorkspace(
            taskID: "task-approve-\(UUID().uuidString.prefix(6))",
            baseDirectory: baseTemp.path,
            isolationType: .ephemeralDirectory,
            retentionPolicy: .cleanupAlways
        )
        defer {
            Task { try? await TaskWorkspaceManager.shared.teardownWorkspace(taskID: ws.id) }
        }

        let verifiedFile = "ApprovedFeature.swift"
        let verifiedContent = "// Verified feature code\npublic struct VerifiedFeature {}\n"
        try ws.writeFile(relativePath: verifiedFile, content: verifiedContent)

        // Reviewer approves landing
        let result = try await TaskMergeReviewService.shared.land(
            taskID: ws.id,
            reviewerApproval: true,
            reviewerNotes: "Passed all verifications cleanly",
            targetWorkspacePath: targetLanding.path
        )

        #expect(result.succeeded)
        #expect(result.landedFiles.contains(verifiedFile))

        // Target workspace MUST have the file with exact content
        let landedFilePath = targetLanding.appendingPathComponent(verifiedFile).path
        #expect(FileManager.default.fileExists(atPath: landedFilePath))
        let targetContent = try String(contentsOfFile: landedFilePath, encoding: .utf8)
        #expect(targetContent == verifiedContent)
        #expect(ws.state == .landed)
    }
}
