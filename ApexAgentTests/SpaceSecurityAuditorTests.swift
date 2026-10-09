import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 75 — Collaborative Spaces & AppGroup Shared Bus Gate Tests")
struct SpaceSecurityAuditorTests {

    @Test("RBAC role permissions properly restrict and authorize actions")
    func rbacPermissionsEnforced() {
        // Owner can do everything
        for action in SpaceAction.allCases {
            #expect(SpaceSecurityAuditor.isActionPermitted(role: .owner, action: action))
        }

        // Admin cannot delete space but can manage participants and settings
        #expect(!SpaceSecurityAuditor.isActionPermitted(role: .admin, action: .deleteSpace))
        #expect(SpaceSecurityAuditor.isActionPermitted(role: .admin, action: .manageParticipants))
        #expect(SpaceSecurityAuditor.isActionPermitted(role: .admin, action: .modifySettings))

        // Guest cannot invoke autonomous tools or modify settings
        #expect(!SpaceSecurityAuditor.isActionPermitted(role: .guest, action: .invokeAutonomousTools))
        #expect(!SpaceSecurityAuditor.isActionPermitted(role: .guest, action: .modifySettings))
        #expect(SpaceSecurityAuditor.isActionPermitted(role: .guest, action: .postMessage))
        #expect(SpaceSecurityAuditor.isActionPermitted(role: .guest, action: .readHistory))

        // Member and AgentTeammate can invoke tools and post messages
        #expect(SpaceSecurityAuditor.isActionPermitted(role: .member, action: .invokeAutonomousTools))
        #expect(SpaceSecurityAuditor.isActionPermitted(role: .agentTeammate, action: .invokeAutonomousTools))
    }

    @Test("AppGroup path traversal attempts are detected and rejected")
    func pathTraversalRejected() {
        let rootURL = URL(fileURLWithPath: "/Users/shared/AppGroup/group.com.apexagent")
        let safeSubpath = rootURL.appendingPathComponent("spaces/space-alpha/state.json")
        let maliciousEscaping = rootURL.appendingPathComponent("../../Library/Keychains/login.keychain")

        #expect(SpaceSecurityAuditor.verifyPathContainment(targetURL: safeSubpath, appGroupRootURL: rootURL))
        #expect(!SpaceSecurityAuditor.verifyPathContainment(targetURL: maliciousEscaping, appGroupRootURL: rootURL))
    }

    @Test("Distributed lock lease expires after timeout and is reclaimable")
    func distributedLockLeaseLifecycle() {
        let now = Date()
        // Lock acquired 45 seconds ago with 30s lease
        let oldDate = now.addingTimeInterval(-45.0)
        let staleLock = DistributedSpaceLock(
            lockId: "lock-session-123",
            holderId: "crashed-agent-worker",
            acquiredAt: oldDate,
            leaseDurationSeconds: 30.0
        )

        let status = SpaceSecurityAuditor.auditDistributedLock(staleLock, now: now)
        #expect(status.isExpired)
        #expect(status.canBeReclaimed)
        #expect(status.ageSeconds >= 45.0)

        // Fresh lock acquired 5 seconds ago
        let freshLock = DistributedSpaceLock(
            lockId: "lock-session-456",
            holderId: "active-agent-worker",
            acquiredAt: now.addingTimeInterval(-5.0),
            leaseDurationSeconds: 30.0
        )
        let freshStatus = SpaceSecurityAuditor.auditDistributedLock(freshLock, now: now)
        #expect(!freshStatus.isExpired)
        #expect(!freshStatus.canBeReclaimed)
    }

    @Test("Compliant space audit passes with 100% score")
    func compliantSpaceAuditPasses() {
        let rootURL = URL(fileURLWithPath: "/tmp/group.com.apexagent")
        let descriptor = SpaceAuditDescriptor(
            spaceId: "space-001",
            name: "Core Engineering",
            ownerId: "human-dan",
            participantCount: 5,
            storageRelativePath: "spaces/space-001",
            activeLocks: []
        )

        let report = SpaceSecurityAuditor.auditSpace(descriptor, appGroupRootURL: rootURL)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.pathContainmentValid)
        #expect(report.violations.isEmpty)
        #expect(report.staleLocksDetected == 0)
    }
}
