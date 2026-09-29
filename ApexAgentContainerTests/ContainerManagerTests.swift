import Testing
import Foundation
@testable import ApexAgentCore

@Suite("ContainerManagerTests") final class ContainerManagerTests {
    
    @MainActor
    @Test func testContainerManagerDefaultState() {
        let manager = ContainerManager.shared
        #expect(manager.state == .idle)
    }
    
    @MainActor
    @Test func testContainerManagerConfigurationUpdates() {
        let manager = ContainerManager.shared
        
        let originalCPUs = manager.containerCPUs
        let originalMemory = manager.containerMemoryMB
        let originalImage = manager.appleContainerImage
        
        manager.containerCPUs = 2
        manager.containerMemoryMB = 2048
        manager.appleContainerImage = "alpine:latest"
        
        #expect(manager.containerCPUs == 2)
        #expect(manager.containerMemoryMB == 2048)
        // The getter normalizes bare Docker-Hub names to fully-qualified
        // references (Containerization's ImageStore rejects bare names).
        #expect(manager.appleContainerImage == "docker.io/library/alpine:latest")
        
        // Restore defaults
        manager.containerCPUs = originalCPUs
        manager.containerMemoryMB = originalMemory
        manager.appleContainerImage = originalImage
    }
    
    @MainActor
    @Test func testContainerExecFailsWhenIdle() async throws {
        let manager = ContainerManager.shared
        // ContainerManager starts in .idle state; exec should throw a domain error
        do {
            _ = try await manager.exec("echo hello")
            Issue.record("exec() should throw when container is not running")
        } catch let error as NSError {
            #expect(error.domain == "ContainerManager")
            #expect(error.code == -3)
        }
    }

    @MainActor
    @Test func testContainerHostDiagnostics() {
        let diagnostics = ContainerManager.checkHostCapabilities()
        #expect(!diagnostics.macOSVersionString.isEmpty)
        #expect(diagnostics.availableDiskSpaceBytes >= 0)
        #expect(!diagnostics.statusMessage.isEmpty)
        #if arch(arm64)
        #expect(diagnostics.isAppleSilicon == true)
        #endif
    }

    @MainActor
    @Test func testContainerIsolationLevelAndStateTransitions() {
        let manager = ContainerManager.shared
        let originalLevel = manager.isolationLevel
        defer { manager.isolationLevel = originalLevel }

        manager.isolationLevel = .strict
        #expect(manager.isolationLevel == .strict)

        manager.isolationLevel = .standard
        #expect(manager.isolationLevel == .standard)

        #expect(ContainerManager.State.idle.description == "Idle")
        #expect(ContainerManager.State.starting.description == "Starting Sandbox...")
        #expect(ContainerManager.State.running.description == "Sandbox Running")
        #expect(ContainerManager.State.stopping.description == "Stopping Sandbox...")
        #expect(ContainerManager.State.downloadingKernel(0.5).description == "Downloading Kernel (50%)")
        #expect(ContainerManager.State.pullingImage(0.85).description == "Pulling Image (85%)")
        #expect(ContainerManager.State.errored("network timeout").description == "Error: network timeout")
    }

    @Test func testContainerSnapshotRecordModel() {
        let now = Date()
        let record = ContainerSnapshotRecord(
            id: "snap-001",
            name: "Initial Baseline",
            description: "Clean state before test run",
            containerId: "apex-sandbox-vm",
            createdAt: now,
            imageRef: "docker.io/library/alpine:latest",
            sizeInBytes: 1024 * 1024 * 12,
            isolationLevel: .standard
        )

        #expect(record.id == "snap-001")
        #expect(record.name == "Initial Baseline")
        #expect(record.containerId == "apex-sandbox-vm")
        #expect(record.sizeInBytes == 12582912)
        #expect(record.isolationLevel == .standard)
    }

    @MainActor
    @Test func testContainerSnapshotLifecycleAndAutomaticRollback() async throws {
        let manager = ContainerManager.shared
        let testContainerId = "test-container-\(UUID().uuidString.prefix(8))"

        let snap1 = try await manager.createSnapshot(name: "Pre-Task Baseline", description: "State 1", containerId: testContainerId)
        #expect(!snap1.id.isEmpty)
        #expect(snap1.name == "Pre-Task Baseline")

        // Wait a brief moment to ensure distinct timestamp ordering
        try? await Task.sleep(for: .milliseconds(20))

        let snap2 = try await manager.createSnapshot(name: "Post-Task Mutation", description: "State 2", containerId: testContainerId)
        #expect(!snap2.id.isEmpty)
        #expect(snap2.name == "Post-Task Mutation")

        let allSnaps = await manager.listSnapshots(containerId: testContainerId)
        #expect(allSnaps.count >= 2)
        #expect(allSnaps.contains(where: { $0.id == snap1.id }))
        #expect(allSnaps.contains(where: { $0.id == snap2.id }))

        // Test automatic rollback to last snapshot
        let rollbackSuccess = try await manager.rollbackToLastSnapshot(containerId: testContainerId)
        #expect(rollbackSuccess == true)

        // Clean up
        try await manager.deleteSnapshot(id: snap1.id, containerId: testContainerId)
        try await manager.deleteSnapshot(id: snap2.id, containerId: testContainerId)
    }
}
