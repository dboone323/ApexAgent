import Testing
import Foundation
@testable import ApexAgentCore

@Suite("SandboxTests") @MainActor
struct SandboxTests {

    @Test func testPathRejectedForArbitraryOutsideWorkspace() {
        let orchestrator = AgentOrchestrator()
        #expect(!orchestrator.isPathAllowed("/var/denied-path"))
    }

    @Test func testRelativeAndDotPathsAllowedInWorkspace() {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions()
        let ws = orchestrator.currentWorkspacePath
        #expect(orchestrator.isPathAllowed("."))
        #expect(orchestrator.isPathAllowed("./"))
        #expect(orchestrator.isPathAllowed(""))
        #expect(orchestrator.isPathAllowed(ws))
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

    @Test func testCommandAllowedWhenContainerSandboxedEvenIfDesktopPathReferenced() {
        let orchestrator = AgentOrchestrator()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let desktop = (home as NSString).appendingPathComponent("Desktop")
        orchestrator.permissions = AppPermissions(desktopFolderAllowed: false)
        
        // On host: blocked
        #expect(!orchestrator.isCommandOrScriptAllowed("ls " + desktop, isContainerSandboxed: false))
        
        // In container sandbox: allowed (isolated micro-VM guest)
        #expect(orchestrator.isCommandOrScriptAllowed("ls " + desktop, isContainerSandboxed: true))
    }

    @Test func testApprovalPolicyAutoApprovesInContainerSandbox() {
        // Privileged commands inside the container are auto-approved
        let verdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "sudo apt-get install -y build-essential && rm -rf /tmp/build",
            isContainerSandboxed: true
        )
        #expect(verdict.approve != nil)
        #expect(verdict.source == .containerSandbox)
    }

    @Test func testApprovalPolicyBlocksHostDiskEraseEvenInContainerSandbox() {
        // Catastrophic host disk destruction is guarded regardless
        let verdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "diskutil eraseDisk APFS CleanDisk /dev/disk2",
            isContainerSandboxed: true
        )
        #expect(verdict.approve == nil)
        #expect(verdict.source == .destructiveGuard)
    }

    @Test func testApprovalPolicyRetainsDestructiveGuardOnHost() {
        // Host execution without container sandbox blocks destructive rm -rf
        let verdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "rm -rf /Users/test/project",
            isContainerSandboxed: false
        )
        #expect(verdict.approve == nil)
        #expect(verdict.source == .destructiveGuard)
    }

    @Test func testListDirectoryWithDotAndRelativePath() async throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions()
        let tool = ListDirectoryTool(orchestrator: orchestrator)

        let dotResult = try await tool.call(arguments: ListDirectoryTool.Arguments(path: ".", showHidden: false, depth: 1))
        #expect(!dotResult.contains("ERROR: Access to path is disabled in settings"))
        #expect(dotResult.hasPrefix("Directory:"))

        let emptyResult = try await tool.call(arguments: ListDirectoryTool.Arguments(path: "", showHidden: false, depth: 1))
        #expect(!emptyResult.contains("ERROR: Access to path is disabled in settings"))
        #expect(emptyResult.hasPrefix("Directory:"))
    }
}

