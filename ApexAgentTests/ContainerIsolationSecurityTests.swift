import Testing
import Foundation
@testable import ApexAgentCore

@Suite("ContainerIsolationSecurityTests")
struct ContainerIsolationSecurityTests {

    // MARK: - 1. Container Isolation Levels

    @Test func testContainerIsolationLevelEnumValues() {
        #expect(ContainerIsolationLevel.strict.rawValue == "strict")
        #expect(ContainerIsolationLevel.standard.rawValue == "standard")
        #expect(ContainerIsolationLevel.ephemeralOverlay.rawValue == "overlay")
        #expect(ContainerIsolationLevel.allCases.count == 3)
    }

    @MainActor
    @Test func testContainerManagerIsolationLevelPersistence() {
        let manager = ContainerManager.shared
        let originalLevel = manager.isolationLevel

        manager.isolationLevel = .strict
        #expect(manager.isolationLevel == .strict)

        manager.isolationLevel = .ephemeralOverlay
        #expect(manager.isolationLevel == .ephemeralOverlay)

        manager.isolationLevel = .standard
        #expect(manager.isolationLevel == .standard)

        // Restore original
        manager.isolationLevel = originalLevel
    }

    // MARK: - 2. Checkpoint & Snapshot APFS CoW Lifecycle

    @MainActor
    @Test func testContainerSnapshotLifecycle() async throws {
        let manager = ContainerManager.shared
        let testContainerId = "test-sandbox-\(UUID().uuidString.prefix(6).lowercased())"
        let snapshotName = "checkpoint-baseline-\(UUID().uuidString.prefix(4))"

        // 1. Create snapshot
        let created = try await manager.createSnapshot(
            name: snapshotName,
            description: "Baseline container snapshot before test execution",
            containerId: testContainerId
        )

        #expect(created.name == snapshotName)
        #expect(created.containerId == testContainerId)
        #expect(created.id.hasPrefix("snap-"))
        #expect(created.description == "Baseline container snapshot before test execution")

        // 2. List snapshots
        let list = await manager.listSnapshots(containerId: testContainerId)
        #expect(list.contains(where: { $0.id == created.id && $0.name == snapshotName }))

        // 3. Restore snapshot
        try await manager.restoreSnapshot(id: created.id, containerId: testContainerId)

        // 4. Rollback to snapshot by name
        try await manager.rollbackToSnapshot(nameOrId: snapshotName, containerId: testContainerId)

        // 5. Delete snapshot
        try await manager.deleteSnapshot(id: created.id, containerId: testContainerId)

        // 6. Verify deletion
        let afterDelete = await manager.listSnapshots(containerId: testContainerId)
        #expect(!afterDelete.contains(where: { $0.id == created.id }))

        // Clean up test container directory
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let root = paths.first!.appendingPathComponent("com.apexagent.containers")
        let testDir = root.appendingPathComponent("imagestore/containers/\(testContainerId)")
        let testSnapDir = root.appendingPathComponent("imagestore/snapshots/\(testContainerId)")
        try? FileManager.default.removeItem(at: testDir)
        try? FileManager.default.removeItem(at: testSnapDir)
    }

    @MainActor
    @Test func testSnapshotErrorHandling() async {
        let manager = ContainerManager.shared
        
        // Empty snapshot name throws error
        do {
            _ = try await manager.createSnapshot(name: "   ")
            Issue.record("createSnapshot with empty name should throw")
        } catch let err as NSError {
            #expect(err.code == -11)
        }

        // Restoring non-existent snapshot throws 404
        do {
            try await manager.restoreSnapshot(id: "non-existent-snap-id")
            Issue.record("restoreSnapshot for non-existent snapshot should throw")
        } catch let err as NSError {
            #expect(err.code == -404)
        }

        // Deleting non-existent snapshot throws 404
        do {
            try await manager.deleteSnapshot(id: "non-existent-snap-id")
            Issue.record("deleteSnapshot for non-existent snapshot should throw")
        } catch let err as NSError {
            #expect(err.code == -404)
        }
    }

    // MARK: - 3. Workspace Mount Safety Guards

    @MainActor
    @Test func testWorkspaceMountSafetyRejectsSystemDirectories() {
        let manager = ContainerManager.shared

        // Disallow root /
        #expect(throws: SecuritySandboxError.self) {
            try manager.verifyWorkspaceMountSafety("/")
        }

        // Disallow system directories
        let systemDirs = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/dev", "/Volumes"]
        for sys in systemDirs {
            #expect(throws: SecuritySandboxError.self) {
                try manager.verifyWorkspaceMountSafety(sys)
            }
        }

        // Disallow user home root
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(throws: SecuritySandboxError.self) {
            try manager.verifyWorkspaceMountSafety(home)
        }

        // Disallow sensitive user root folders directly
        let desktop = (home as NSString).appendingPathComponent("Desktop")
        let documents = (home as NSString).appendingPathComponent("Documents")
        let downloads = (home as NSString).appendingPathComponent("Downloads")
        let music = (home as NSString).appendingPathComponent("Music")

        #expect(throws: SecuritySandboxError.self) {
            try manager.verifyWorkspaceMountSafety(desktop)
        }
        #expect(throws: SecuritySandboxError.self) {
            try manager.verifyWorkspaceMountSafety(documents)
        }
        #expect(throws: SecuritySandboxError.self) {
            try manager.verifyWorkspaceMountSafety(downloads)
        }
        #expect(throws: SecuritySandboxError.self) {
            try manager.verifyWorkspaceMountSafety(music)
        }
    }

    @MainActor
    @Test func testWorkspaceMountSafetyAllowsValidSubdirectory() throws {
        let manager = ContainerManager.shared
        let tempSubDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("valid_container_workspace_\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(atPath: tempSubDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempSubDir) }

        // Valid sub-workspace should succeed without error
        try manager.verifyWorkspaceMountSafety(tempSubDir)
    }

    // MARK: - 4. Security Governance Profiles

    @Test func testSecurityGovernanceProfilePresets() {
        let hostStrict = SecurityGovernanceProfile.hostStrict
        #expect(hostStrict.scope == .host)
        #expect(hostStrict.isolationLevel == .strict)
        #expect(!hostStrict.allowNetwork)
        #expect(!hostStrict.allowHostFilesystemMount)
        #expect(hostStrict.blockDestructiveHostCommands)
        #expect(hostStrict.blockSensitiveFileAccess)

        let hostDev = SecurityGovernanceProfile.hostDeveloper
        #expect(hostDev.scope == .host)
        #expect(hostDev.isolationLevel == .standard)
        #expect(hostDev.allowNetwork)
        #expect(hostDev.allowHostFilesystemMount)

        let contStd = SecurityGovernanceProfile.containerStandard
        #expect(contStd.scope == .container)
        #expect(contStd.isolationLevel == .standard)
        #expect(contStd.allowNetwork)
        #expect(contStd.autoApprovePackageInstall)

        let contStrict = SecurityGovernanceProfile.containerStrict
        #expect(contStrict.scope == .container)
        #expect(contStrict.isolationLevel == .strict)
        #expect(!contStrict.allowNetwork)
        #expect(contStrict.blockSensitiveFileAccess)

        #expect(SecurityGovernanceProfile.profile(for: .hostStrict) == .hostStrict)
        #expect(SecurityGovernanceProfile.profile(for: .hostDeveloper) == .hostDeveloper)
        #expect(SecurityGovernanceProfile.profile(for: .containerStandard) == .containerStandard)
        #expect(SecurityGovernanceProfile.profile(for: .containerStrict) == .containerStrict)
    }

    @Test func testSecurityGovernanceProfileValidation() {
        let hostStrict = SecurityGovernanceProfile.hostStrict

        // System root is rejected
        #expect(throws: SecuritySandboxError.self) {
            try hostStrict.validateFilesystemAccess(path: "/")
        }

        // System directories are rejected
        #expect(throws: SecuritySandboxError.self) {
            try hostStrict.validateFilesystemAccess(path: "/System/Library")
        }

        // Desktop is rejected
        #expect(throws: SecuritySandboxError.self) {
            try hostStrict.validateFilesystemAccess(path: "~/Desktop/secret.txt")
        }

        // Network command blocked in hostStrict
        #expect(!hostStrict.validateCommand(command: "curl https://example.com"))
        #expect(!hostStrict.validateCommand(command: "ssh user@host"))

        // Destructive command blocked in hostStrict
        #expect(!hostStrict.validateCommand(command: "rm -rf /"))

        // Container standard allows package installations
        let contStd = SecurityGovernanceProfile.containerStandard
        #expect(contStd.validateCommand(command: "apt-get update && apt-get install -y git", isContainerSandboxed: true))
    }

    // MARK: - 5. ApprovalPolicy Integration with Governance Profiles

    @Test func testApprovalPolicyWithGovernanceProfiles() {
        // 1. Host Strict Governance Profile blocks network and sensitive operations
        let hostStrictVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "curl https://malicious.example.com",
            governanceProfile: .hostStrict
        )
        #expect(hostStrictVerdict.approve == nil)
        #expect(hostStrictVerdict.source == .governanceBlock)

        // 2. Container Standard Governance Profile auto-approves safe package installations
        let contStdVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "apt-get install -y clang build-essential",
            governanceProfile: .containerStandard
        )
        #expect(contStdVerdict.approve != nil)
        #expect(contStdVerdict.source == .containerSandbox)

        // 3. Container Standard Governance Profile blocks host disk destruction
        let destructiveVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "diskutil eraseVolume APFS Blank /dev/disk0s2",
            governanceProfile: .containerStandard
        )
        #expect(destructiveVerdict.approve == nil)
        #expect(destructiveVerdict.source == .destructiveGuard)

        // 4. Container Strict Governance Profile blocks sensitive key reading
        let contStrictVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "cat ~/.ssh/id_rsa",
            governanceProfile: .containerStrict
        )
        #expect(contStrictVerdict.approve == nil)
        #expect(contStrictVerdict.source == .sensitiveGuard)
    }

    // MARK: - 6. Symlink Traversal Detection in AgentOrchestrator

    @MainActor
    @Test func testSymlinkTraversalDetection() throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions(
            musicFolderAllowed: false,
            desktopFolderAllowed: false,
            documentsFolderAllowed: false,
            downloadsFolderAllowed: false
        )

        let fm = FileManager.default
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("symlink_test_workspace_\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        orchestrator.currentWorkspacePath = tempDir

        // 1. Create a legitimate file inside workspace -> allowed
        let legitFile = (tempDir as NSString).appendingPathComponent("file.txt")
        try "hello".write(toFile: legitFile, atomically: true, encoding: .utf8)
        #expect(orchestrator.isPathAllowed(legitFile))

        // 2. Create a symlink inside workspace pointing OUTSIDE workspace to /etc
        let maliciousLink = (tempDir as NSString).appendingPathComponent("etc_link")
        try fm.createSymbolicLink(atPath: maliciousLink, withDestinationPath: "/etc")

        // 3. Verifying the symlink must throw .symlinkTraversal
        #expect(throws: SecuritySandboxError.self) {
            try orchestrator.verifyPathAllowed(maliciousLink)
        }

        do {
            try orchestrator.verifyPathAllowed(maliciousLink)
            Issue.record("Symlink pointing outside workspace should throw .symlinkTraversal")
        } catch SecuritySandboxError.symlinkTraversal(let path) {
            #expect(path == maliciousLink)
        } catch {
            Issue.record("Expected SecuritySandboxError.symlinkTraversal but got \(error)")
        }

        #expect(!orchestrator.isPathAllowed(maliciousLink))
    }

    // MARK: - 7. Strict Host Filesystem Boundaries

    @MainActor
    @Test func testStrictHostFilesystemBoundaries() {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions(
            musicFolderAllowed: false,
            desktopFolderAllowed: false,
            documentsFolderAllowed: false,
            downloadsFolderAllowed: false
        )

        // System roots are rejected
        #expect(!orchestrator.isPathAllowed("/"))
        #expect(!orchestrator.isPathAllowed("/System"))
        #expect(!orchestrator.isPathAllowed("/Library"))
        #expect(!orchestrator.isPathAllowed("/etc"))
        #expect(!orchestrator.isPathAllowed("/var"))
        #expect(!orchestrator.isPathAllowed("/usr/bin"))

        // User folders with disabled permissions are rejected
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let desktop = (home as NSString).appendingPathComponent("Desktop")
        let documents = (home as NSString).appendingPathComponent("Documents")
        let downloads = (home as NSString).appendingPathComponent("Downloads")
        let music = (home as NSString).appendingPathComponent("Music")

        #expect(!orchestrator.isPathAllowed(desktop))
        #expect(!orchestrator.isPathAllowed(documents))
        #expect(!orchestrator.isPathAllowed(downloads))
        #expect(!orchestrator.isPathAllowed(music))

        // Command validation checks tilde expansion and absolute paths
        #expect(!orchestrator.isCommandOrScriptAllowed("cat ~/Desktop/passwords.txt"))
        #expect(!orchestrator.isCommandOrScriptAllowed("ls " + documents))
        #expect(!orchestrator.isCommandOrScriptAllowed("rm ~/Downloads/archive.zip"))
        #expect(!orchestrator.isCommandOrScriptAllowed("open ~/Music/song.mp3"))

        // Inside container sandbox, guest commands referencing workspace names are allowed
        #expect(orchestrator.isCommandOrScriptAllowed("ls ~/Desktop", isContainerSandboxed: true))
    }

    // MARK: - 8. Snapshot Codable & Metadata Roundtrip

    @Test func testSnapshotRecordCodableRoundtrip() throws {
        let record = ContainerSnapshotRecord(
            id: "snap-abc12345",
            name: "unit-test-snapshot",
            containerId: "apex-sandbox",
            imageRef: "docker.io/library/swift:latest",
            createdAt: Date(),
            sizeInBytes: 1048576,
            isolationLevel: .ephemeralOverlay,
            description: "Test snapshot for verification"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ContainerSnapshotRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.name == record.name)
        #expect(decoded.containerId == record.containerId)
        #expect(decoded.imageRef == record.imageRef)
        #expect(decoded.sizeInBytes == record.sizeInBytes)
        #expect(decoded.isolationLevel == record.isolationLevel)
        #expect(decoded.description == record.description)
    }

    // MARK: - 9. Governance Profile Filesystem Access for Custom Paths

    @Test func testGovernanceProfileCustomAllowedPaths() throws {
        let profile = SecurityGovernanceProfile(
            id: "custom-test-profile",
            name: "Custom Test Profile",
            scope: .host,
            isolationLevel: .standard,
            allowNetwork: true,
            allowHostFilesystemMount: true,
            autoApprovePackageInstall: false,
            blockDestructiveHostCommands: true,
            blockSensitiveFileAccess: true,
            restrictedHostPaths: ["~/Desktop", "~/Documents"],
            customAllowedPaths: ["/tmp/allowed_project"]
        )

        #expect(profile.id == "custom-test-profile")
        #expect(profile.customAllowedPaths == ["/tmp/allowed_project"])
        #expect(profile.restrictedHostPaths.contains("~/Desktop"))
    }
}

