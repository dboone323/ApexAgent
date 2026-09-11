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
}
