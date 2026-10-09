import Foundation

// MARK: - Collaborative Spaces & AppGroup Shared Bus Gate (Batch 75)

/// Actions that can be performed within a collaborative Space.
public enum SpaceAction: String, Sendable, Codable, CaseIterable {
    case deleteSpace = "delete_space"
    case modifySettings = "modify_settings"
    case manageParticipants = "manage_participants"
    case invokeAutonomousTools = "invoke_autonomous_tools"
    case postMessage = "post_message"
    case readHistory = "read_history"
    case acquireSharedLock = "acquire_shared_lock"
}

/// Status of a distributed lock lease.
public struct LockLeaseStatus: Sendable, Codable, Equatable {
    public let lockId: String
    public let holderId: String
    public let isExpired: Bool
    public let ageSeconds: TimeInterval
    public let canBeReclaimed: Bool
}

/// Representation of a distributed lock held in AppGroup shared storage.
public struct DistributedSpaceLock: Sendable, Codable, Equatable {
    public let lockId: String
    public let holderId: String
    public let acquiredAt: Date
    public let leaseDurationSeconds: TimeInterval

    public init(lockId: String, holderId: String, acquiredAt: Date, leaseDurationSeconds: TimeInterval = 30.0) {
        self.lockId = lockId
        self.holderId = holderId
        self.acquiredAt = acquiredAt
        self.leaseDurationSeconds = leaseDurationSeconds
    }
}

/// Violation detected during Space security auditing.
public struct SpaceSecurityViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Descriptor of a collaborative space for security audit.
public struct SpaceAuditDescriptor: Sendable, Codable, Equatable {
    public let spaceId: String
    public let name: String
    public let ownerId: String
    public let participantCount: Int
    public let storageRelativePath: String
    public let activeLocks: [DistributedSpaceLock]

    public init(
        spaceId: String,
        name: String,
        ownerId: String,
        participantCount: Int,
        storageRelativePath: String,
        activeLocks: [DistributedSpaceLock] = []
    ) {
        self.spaceId = spaceId
        self.name = name
        self.ownerId = ownerId
        self.participantCount = participantCount
        self.storageRelativePath = storageRelativePath
        self.activeLocks = activeLocks
    }
}

/// Complete report of Space security audit.
public struct SpaceSecurityAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let violations: [SpaceSecurityViolation]
    public let pathContainmentValid: Bool
    public let staleLocksDetected: Int

    public init(
        passed: Bool,
        score: Double,
        violations: [SpaceSecurityViolation],
        pathContainmentValid: Bool,
        staleLocksDetected: Int
    ) {
        self.passed = passed
        self.score = score
        self.violations = violations
        self.pathContainmentValid = pathContainmentValid
        self.staleLocksDetected = staleLocksDetected
    }
}

/// Security auditor for collaborative Spaces, participant RBAC, and AppGroup shared bus.
public enum SpaceSecurityAuditor {

    public static let defaultAppGroupIdentifier = "group.com.apexagent"

    // MARK: - RBAC Action Verification

    /// Evaluates if a given role is permitted to perform a target SpaceAction.
    public static func isActionPermitted(role: SpaceParticipantRole, action: SpaceAction) -> Bool {
        switch role {
        case .owner:
            return true
        case .admin:
            return action != .deleteSpace
        case .member:
            return action == .postMessage || action == .readHistory || action == .acquireSharedLock || action == .invokeAutonomousTools
        case .guest:
            return action == .postMessage || action == .readHistory
        case .agentTeammate:
            return action == .postMessage || action == .readHistory || action == .invokeAutonomousTools || action == .acquireSharedLock
        }
    }

    // MARK: - Path Sandboxing Verification

    /// Verifies that a target URL is strictly contained within the allowed AppGroup storage root.
    public static func verifyPathContainment(targetURL: URL, appGroupRootURL: URL) -> Bool {
        let normalizedTarget = targetURL.standardizedFileURL.path
        let normalizedRoot = appGroupRootURL.standardizedFileURL.path

        if normalizedTarget.contains("..") {
            return false
        }
        return normalizedTarget == normalizedRoot || normalizedTarget.hasPrefix(normalizedRoot + "/")
    }

    // MARK: - Distributed Lock Lease Audit

    /// Audits a distributed lock lease to determine if it has expired and can safely be reclaimed.
    public static func auditDistributedLock(
        _ lock: DistributedSpaceLock,
        now: Date = Date(),
        maxLeaseSeconds: TimeInterval = 30.0
    ) -> LockLeaseStatus {
        let age = max(0.0, now.timeIntervalSince(lock.acquiredAt))
        let effectiveLease = min(lock.leaseDurationSeconds, maxLeaseSeconds)
        let isExpired = age >= effectiveLease
        let canBeReclaimed = isExpired

        return LockLeaseStatus(
            lockId: lock.lockId,
            holderId: lock.holderId,
            isExpired: isExpired,
            ageSeconds: age,
            canBeReclaimed: canBeReclaimed
        )
    }

    // MARK: - Space Descriptor Audit

    /// Audits a space descriptor for storage path escaping, stale locks, and structural security.
    public static func auditSpace(
        _ descriptor: SpaceAuditDescriptor,
        appGroupRootURL: URL,
        now: Date = Date()
    ) -> SpaceSecurityAuditReport {
        var violations: [SpaceSecurityViolation] = []
        var staleLocksCount = 0

        // 1. Storage path validation
        let targetStorageURL = appGroupRootURL.appendingPathComponent(descriptor.storageRelativePath)
        let pathValid = verifyPathContainment(targetURL: targetStorageURL, appGroupRootURL: appGroupRootURL)
        if !pathValid {
            violations.append(SpaceSecurityViolation(
                code: "STORAGE_PATH_TRAVERSAL",
                message: "Relative path '\(descriptor.storageRelativePath)' escapes AppGroup root containment."
            ))
        }

        // 2. Lock leases audit
        for lock in descriptor.activeLocks {
            let leaseStatus = auditDistributedLock(lock, now: now)
            if leaseStatus.isExpired {
                staleLocksCount += 1
                violations.append(SpaceSecurityViolation(
                    code: "STALE_DISTRIBUTED_LOCK",
                    message: "Lock '\(lock.lockId)' held by '\(lock.holderId)' has expired (\(String(format: "%.1f", leaseStatus.ageSeconds))s old).",
                    isFatal: false
                ))
            }
        }

        let passed = violations.filter(\.isFatal).isEmpty
        let score = violations.isEmpty ? 100.0 : max(0.0, 100.0 - Double(violations.count) * 30.0)

        return SpaceSecurityAuditReport(
            passed: passed,
            score: score,
            violations: violations,
            pathContainmentValid: pathValid,
            staleLocksDetected: staleLocksCount
        )
    }
}
