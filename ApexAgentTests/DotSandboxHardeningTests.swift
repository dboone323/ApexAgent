//
//  DotSandboxHardeningTests.swift
//  ApexAgentTests
//
//  Batch 122: Real functional tests for DotSandboxSnapshotEngine covering disk quotas,
//  symlink jail, environment sanitization, and workspace snapshot/rollback.
//

import XCTest
import Foundation
@testable import ApexAgentCore

final class DotSandboxHardeningTests: XCTestCase {

    // MARK: - 1. Disk Usage Calculation

    func testDiskUsageCalculationIsAccurate() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disk_calc_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        let file3 = tempDir.appendingPathComponent("file3.txt")

        let data1 = Data(repeating: 0x41, count: 100)
        let data2 = Data(repeating: 0x42, count: 200)
        let data3 = Data(repeating: 0x43, count: 300)

        try data1.write(to: file1)
        try data2.write(to: file2)
        try data3.write(to: file3)

        let engine = DotSandboxSnapshotEngine.shared
        let usage = try await engine.currentDiskUsageBytes(at: tempDir)

        XCTAssertGreaterThan(usage, 0)
        XCTAssertEqual(usage, 600)
    }

    // MARK: - 2. Quota Under Limit

    func testQuotaEnforcementAcceptsUnderLimit() async throws {
        let dotId = UUID()
        let root = try DotSandboxManager.shared.ensureSandbox(for: dotId)
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }

        let testFile = root.appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("sample.txt")
        try "small content within quota".write(to: testFile, atomically: true, encoding: .utf8)

        let engine = DotSandboxSnapshotEngine.shared
        do {
            try await engine.assertQuotaNotExceeded(for: dotId)
        } catch {
            XCTFail("assertQuotaNotExceeded threw unexpected error: \(error)")
        }
    }

    // MARK: - 3. Quota Over Limit

    func testQuotaEnforcementRejectsOverLimit() async throws {
        let dotId = UUID()
        let root = try DotSandboxManager.shared.ensureSandbox(for: dotId)
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }

        let testFile = root.appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("minimal.txt")
        try "minimal non-empty payload to exceed 1 byte".write(to: testFile, atomically: true, encoding: .utf8)

        let engine = DotSandboxSnapshotEngine.shared
        do {
            try await engine.assertQuotaNotExceeded(for: dotId, quotaBytes: 1)
            XCTFail("Expected assertQuotaNotExceeded to throw DotSandboxError.quotaExceeded, but it succeeded")
        } catch let DotSandboxError.quotaExceeded(usedBytes, limitBytes) {
            XCTAssertGreaterThan(usedBytes, 1)
            XCTAssertEqual(limitBytes, 1)
        } catch {
            XCTFail("Expected DotSandboxError.quotaExceeded, but got: \(error)")
        }
    }

    // MARK: - 4. Symlink Jail Normal Paths

    func testSymlinkJailAcceptsNormalPaths() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jail_normal_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let engine = DotSandboxSnapshotEngine.shared
        let resolved = try await engine.resolveJailedPath(sandboxRoot: tempRoot, relativePath: "notes/test.md")
        let resolvedRoot = tempRoot.standardizedFileURL.resolvingSymlinksInPath()

        XCTAssertTrue(resolved.path.hasPrefix(resolvedRoot.path))
    }

    // MARK: - 5. Symlink Jail Escape Attempt

    func testSymlinkJailRejectsEscapeAttempt() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jail_escape_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let symlinkURL = tempRoot.appendingPathComponent("hosts_symlink")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))

        let engine = DotSandboxSnapshotEngine.shared
        do {
            _ = try await engine.resolveJailedPath(sandboxRoot: tempRoot, relativePath: "hosts_symlink")
            XCTFail("Expected resolveJailedPath to throw DotSandboxError.symlinkEscapeAttempt, but succeeded")
        } catch let DotSandboxError.symlinkEscapeAttempt(path) {
            XCTAssertEqual(path, "hosts_symlink")
        } catch {
            XCTFail("Expected DotSandboxError.symlinkEscapeAttempt, but got: \(error)")
        }
    }

    // MARK: - 6. Environment Sanitization Removes Sensitive Keys

    func testEnvironmentSanitizationRemovesSensitiveKeys() async throws {
        let input: [String: String] = [
            "GITHUB_TOKEN": "ghp_mocktoken1234567890",
            "AWS_SECRET_ACCESS_KEY": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "HOME": "/Users/developer",
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "DOT_ID": "dot-computer-uuid-1234"
        ]

        let engine = DotSandboxSnapshotEngine.shared
        let sanitized = await engine.sanitizeEnvironment(input)

        XCTAssertNil(sanitized["GITHUB_TOKEN"])
        XCTAssertNil(sanitized["AWS_SECRET_ACCESS_KEY"])
        XCTAssertEqual(sanitized["HOME"], "/Users/developer")
        XCTAssertEqual(sanitized["PATH"], "/usr/local/bin:/usr/bin:/bin")
        XCTAssertEqual(sanitized["DOT_ID"], "dot-computer-uuid-1234")
        XCTAssertEqual(sanitized.count, 3)
    }

    // MARK: - 7. Environment Sanitization Preserves Safe Keys

    func testEnvironmentSanitizationPreservesAllSafeKeys() async throws {
        let input: [String: String] = [
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "COLORTERM": "truecolor"
        ]

        let engine = DotSandboxSnapshotEngine.shared
        let sanitized = await engine.sanitizeEnvironment(input)

        XCTAssertEqual(sanitized["TERM"], "xterm-256color")
        XCTAssertEqual(sanitized["LANG"], "en_US.UTF-8")
        XCTAssertEqual(sanitized["COLORTERM"], "truecolor")
        XCTAssertEqual(sanitized.count, 3)
    }

    // MARK: - 8. Snapshot Creation and Restoration

    func testSnapshotCreationAndRestoration() async throws {
        let dotId = UUID()
        let sandboxManager = DotSandboxManager.shared
        let root = try sandboxManager.ensureSandbox(for: dotId)
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }

        let originalContent = "# Autonomous Plan v1\nStep 1: Discover\nStep 2: Execute\n"
        try sandboxManager.writeSandboxFile(for: dotId, relativePath: "workspace/plan.md", content: originalContent)

        let engine = DotSandboxSnapshotEngine.shared
        let snapshot = try await engine.createSnapshot(for: dotId)
        XCTAssertTrue(snapshot.filePaths.contains("plan.md"))

        // Overwrite workspace/plan.md with modified content
        let modifiedContent = "# Corrupted Plan v2\nStep 1: Fail\n"
        try sandboxManager.writeSandboxFile(for: dotId, relativePath: "workspace/plan.md", content: modifiedContent)

        let intermediateRead = try sandboxManager.readSandboxFile(for: dotId, relativePath: "workspace/plan.md")
        XCTAssertEqual(intermediateRead, modifiedContent)

        // Restore snapshot
        try await engine.restoreSnapshot(snapshot)

        // Verify content matches original
        let restoredContent = try sandboxManager.readSandboxFile(for: dotId, relativePath: "workspace/plan.md")
        XCTAssertEqual(restoredContent, originalContent)
    }

    // MARK: - 9. Snapshot List Ordering

    func testSnapshotListOrdering() async throws {
        let dotId = UUID()
        let sandboxManager = DotSandboxManager.shared
        let root = try sandboxManager.ensureSandbox(for: dotId)
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }

        try sandboxManager.writeSandboxFile(for: dotId, relativePath: "workspace/state.txt", content: "state1")
        let engine = DotSandboxSnapshotEngine.shared
        let snapshot1 = try await engine.createSnapshot(for: dotId)

        try await Task.sleep(for: .milliseconds(50))

        try sandboxManager.writeSandboxFile(for: dotId, relativePath: "workspace/state.txt", content: "state2")
        let snapshot2 = try await engine.createSnapshot(for: dotId)

        let snapshots = try await engine.listSnapshots(for: dotId)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].snapshotId, snapshot2.snapshotId)
        XCTAssertEqual(snapshots[1].snapshotId, snapshot1.snapshotId)
        XCTAssertGreaterThanOrEqual(snapshots[0].createdAt, snapshots[1].createdAt)
    }

    // MARK: - 10. Snapshot Deletion

    func testSnapshotDeletion() async throws {
        let dotId = UUID()
        let sandboxManager = DotSandboxManager.shared
        let root = try sandboxManager.ensureSandbox(for: dotId)
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }

        try sandboxManager.writeSandboxFile(for: dotId, relativePath: "workspace/state.txt", content: "to_delete")
        let engine = DotSandboxSnapshotEngine.shared
        let snapshot = try await engine.createSnapshot(for: dotId)

        var snapshots = try await engine.listSnapshots(for: dotId)
        XCTAssertEqual(snapshots.count, 1)

        try await engine.deleteSnapshot(snapshot)

        snapshots = try await engine.listSnapshots(for: dotId)
        XCTAssertTrue(snapshots.isEmpty)
    }

    // MARK: - 11. Error Description Verification

    func testErrorDescriptionMessages() {
        let errQuota = DotSandboxError.quotaExceeded(usedBytes: 500, limitBytes: 250)
        XCTAssertNotNil(errQuota.errorDescription)
        XCTAssertTrue(errQuota.errorDescription!.contains("500"))
        XCTAssertTrue(errQuota.errorDescription!.contains("250"))

        let errEscape = DotSandboxError.symlinkEscapeAttempt(path: "/etc/shadow")
        XCTAssertNotNil(errEscape.errorDescription)
        XCTAssertTrue(errEscape.errorDescription!.contains("/etc/shadow"))

        let missingId = UUID()
        let errMissing = DotSandboxError.snapshotNotFound(id: missingId)
        XCTAssertNotNil(errMissing.errorDescription)
        XCTAssertTrue(errMissing.errorDescription!.contains(missingId.uuidString))

        let errDir = DotSandboxError.snapshotDirectoryCreationFailed(path: "/invalid/dir")
        XCTAssertNotNil(errDir.errorDescription)
        XCTAssertTrue(errDir.errorDescription!.contains("/invalid/dir"))
    }

    // MARK: - 12. Dot Sandbox Disk Usage for DotId

    func testCurrentDiskUsageForDotId() async throws {
        let dotId = UUID()
        let sandboxManager = DotSandboxManager.shared
        let root = try sandboxManager.ensureSandbox(for: dotId)
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }

        try sandboxManager.writeSandboxFile(for: dotId, relativePath: "workspace/note.txt", content: "Dot sandbox usage check")

        let engine = DotSandboxSnapshotEngine.shared
        let usage = try await engine.currentDiskUsageBytes(for: dotId)
        XCTAssertGreaterThan(usage, 0)
    }

    // MARK: - 13. Restore Non-Existent Snapshot Throws

    func testRestoreSnapshotThrowsWhenSnapshotNotFound() async throws {
        let nonExistentId = UUID()
        let fakeSnapshot = DotWorkspaceSnapshot(
            snapshotId: nonExistentId,
            dotId: UUID(),
            createdAt: Date(),
            snapshotURL: URL(fileURLWithPath: "/tmp/non_existent_snapshot_\(nonExistentId.uuidString)"),
            filePaths: []
        )

        let engine = DotSandboxSnapshotEngine.shared
        do {
            try await engine.restoreSnapshot(fakeSnapshot)
            XCTFail("Expected restoreSnapshot to throw snapshotNotFound, but succeeded")
        } catch let DotSandboxError.snapshotNotFound(id) {
            XCTAssertEqual(id, nonExistentId)
        } catch {
            XCTFail("Expected DotSandboxError.snapshotNotFound, got: \(error)")
        }
    }
}
