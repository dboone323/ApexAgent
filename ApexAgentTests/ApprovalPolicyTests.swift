import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O3: ApprovalPolicy

@Suite("ApprovalPolicyTests")
struct ApprovalPolicyTests {

    @Test func destructiveGuardAlwaysBlocks() {
        let v = ApprovalPolicy.verdict(tool: "run_shell_command", summary: "rm -rf /tmp/x", autoApprove: true)
        #expect(v.approve == nil)
        #expect(v.source == .destructiveGuard)
    }

    @Test func sensitiveGuardBlocksEnvRead() {
        let v = ApprovalPolicy.verdict(tool: "run_shell_command", summary: "cat ~/project/.env", alwaysAllow: ["run_shell_command:cat"])
        #expect(v.approve == nil)
        #expect(v.source == .sensitiveGuard)
    }

    @Test func alwaysAllowApprovesForSpecificProgram() {
        let key = ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "git status")
        #expect(key == "run_shell_command:git")
        let v = ApprovalPolicy.verdict(tool: "run_shell_command", summary: "git status", alwaysAllow: [key])
        #expect(v.source == .alwaysAllow)
        #expect(v.approve != nil)
    }

    @Test func alwaysAllowNeverCoversDifferentProgram() {
        let v = ApprovalPolicy.verdict(tool: "run_shell_command", summary: "rm file.txt", alwaysAllow: ["run_shell_command:git"])
        #expect(v.approve == nil)
    }

    @Test func approvalKeySkipsEnvAndSudo() {
        #expect(ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "ENV=1 sudo /usr/bin/git push")
            == "run_shell_command:git")
        #expect(ApprovalPolicy.approvalKey(tool: "read_file", summary: "whatever") == "read_file")
        #expect(ApprovalPolicy.approvalKey(tool: "mcp__filesystem__read_file", summary: "x") == "mcp__filesystem__read_file")
    }

    @Test func autoModeApprovesSafeTools() {
        let v = ApprovalPolicy.verdict(tool: "read_file", summary: "read /a/b.txt", autoApprove: true)
        #expect(v.source == .autoMode)
        #expect(v.approve != nil)
    }

    @Test func noGrantAsks() {
        let v = ApprovalPolicy.verdict(tool: "read_file", summary: "read /a/b.txt")
        #expect(v.approve == nil)
        #expect(v.source == .noGrant)
    }

    @Test func unattendedBlocksEvenAnAlwaysAllowGrant() {
        let key = ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "git status")
        let v = ApprovalPolicy.verdict(
            tool: "run_shell_command", summary: "git status",
            alwaysAllow: [key], unattended: true)
        #expect(v.approve == nil)
        #expect(v.source == .unattendedBlock)
        #expect(v.rule == key)
    }

    @Test func localScopeBlocksGrantUnlessAutoMode() {
        let key = ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "git status")
        let v = ApprovalPolicy.verdict(tool: "run_shell_command", summary: "git status", alwaysAllow: [key], localScope: true)
        #expect(v.approve == nil)
        #expect(v.source == .localComputerBlock)
    }
}
