import Testing
import Foundation
@testable import ApexAgentCore

@Suite("HardeningLoopBatch14Tests")
struct HardeningLoopBatch14Tests {
    @Test func testGroupToolPermissionBadges() {
        #expect(GroupToolPermission.allowed.badge.contains("Allowed"))
        #expect(GroupToolPermission.allowed.isActionable)
        #expect(GroupToolPermission.needsApproval.isActionable)
        if case .denied(let r) = GroupToolPermission.denied(reason: "x") {
            #expect(r == "x")
        } else { Issue.record("expected denied") }
        #expect(!GroupToolPermission.denied(reason: "x").isActionable)
    }

    @Test func testDiagnosticSummary() {
        let items = [
            DiagnosticItem(name: "Git", category: "CLI", status: .pass, message: "ok"),
            DiagnosticItem(name: "Node", category: "CLI", status: .warning, message: "missing"),
            DiagnosticItem(name: "Xcode", category: "CLI", status: .fail, message: "missing")
        ]
        let md = DiagnosticItem.summarizeAsMarkdown(items)
        #expect(md.contains("3 checks"))
        #expect(md.contains("1 failing"))
        #expect(DiagnosticItem.summarizeAsMarkdown([]).contains("No diagnostic"))
    }

    @Test @MainActor func testCapabilityGuards() {
        #expect(EphemeralCapabilityManager.ttlError(-5) != nil)
        #expect(EphemeralCapabilityManager.ttlError(0) != nil)
        #expect(EphemeralCapabilityManager.ttlError(60) == nil)
        #expect(EphemeralCapabilityManager.ttlError(7200) != nil)
        #expect(EphemeralCapabilityManager.requiresToken(toolName: "delete_file"))
        #expect(!EphemeralCapabilityManager.requiresToken(toolName: "web_search"))
        let tok = EphemeralCapabilityManager.shared.issueToken(for: "delete_file", botName: nil, ttlSeconds: 60)
        #expect(tok.remainingLifetime > 0 && tok.remainingLifetime <= 60)
        let md = tok.formatAsMarkdown()
        #expect(md.contains("delete_file"))
        #expect(!md.contains(tok.hmac))
        EphemeralCapabilityManager.shared.revokeAll(for: "delete_file")
    }

    @Test func testGroupAllowlistProbe() {
        #expect(DefaultGroupToolAllowlist.isAllowed("web_search"))
        #expect(!DefaultGroupToolAllowlist.isAllowed("run_shell_command"))
    }
}
