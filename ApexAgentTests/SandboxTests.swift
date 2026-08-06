import Testing
import Foundation
@testable import ApexAgentCore

@Suite("SandboxTests") @MainActor
struct SandboxTests {

    @Test func testPathRejectedForArbitraryOutsideWorkspace() {
        let orchestrator = AgentOrchestrator()
        #expect(!orchestrator.isPathAllowed("/var/denied-path"))
    }

    @Test func testCommandRejectedWhenDesktopRestricted() {
        let orchestrator = AgentOrchestrator()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let desktop = (home as NSString).appendingPathComponent("Desktop")
        orchestrator.permissions = AppPermissions(desktopFolderAllowed: false)
        #expect(!orchestrator.isCommandOrScriptAllowed("ls " + desktop))
    }

    @Test func testCommandDeniedWhenPermissionsUnset() {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = nil
        #expect(!orchestrator.isCommandOrScriptAllowed("echo hello"))
    }

    @Test func testPathRejectionThrowsSecuritySandboxError() {
        let orchestrator = AgentOrchestrator()
        do {
            try orchestrator.verifyPathAllowed("/var/denied-path")
            Issue.record("Expected pathViolation error")
        } catch let error as SecuritySandboxError {
            if case .pathViolation = error {} else {
                Issue.record("Expected pathViolation, got \(error)")
            }
        } catch {
            Issue.record("Expected SecuritySandboxError, got \(error)")
        }
    }
}
