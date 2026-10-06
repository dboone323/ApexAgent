import Testing
import Foundation
import FoundationModels
import AppKit
@testable import ApexAgentCore

// MARK: - Group tool permission badges & allowlist probe

@Suite("GroupToolPermissionTests")
struct GroupToolPermissionTests {
    @Test func groupToolPermissionBadges() {
        #expect(GroupToolPermission.allowed.badge.contains("Allowed"))
        #expect(GroupToolPermission.allowed.isActionable)
        #expect(GroupToolPermission.needsApproval.isActionable)
        if case .denied(let r) = GroupToolPermission.denied(reason: "x") {
            #expect(r == "x")
        } else { Issue.record("expected denied") }
        #expect(!GroupToolPermission.denied(reason: "x").isActionable)
    }

    @Test func groupAllowlistProbe() {
        #expect(DefaultGroupToolAllowlist.isAllowed("web_search"))
        #expect(!DefaultGroupToolAllowlist.isAllowed("run_shell_command"))
    }
}
