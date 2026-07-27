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
}
