import Foundation

// MARK: - PeerApproval: harness-native bot-to-bot contact gate (O9, port of OpenMausBot peer-approval.ts + peer-approval-key.ts)
//
// A bot without an existing grant may not contact or delegate to another bot
// until a human approves that specific pair+action. The approval is a pending
// card keyed by requestId; "Always allow" rides on the same per-bot grant list
// the permission system already uses, so both sides can never disagree about
// what was granted. Pending state lives only in memory — restarting cancels
// every in-flight ask, exactly like provider permissions do.

enum PeerAction: String, Codable, Sendable {
    case askBot = "ask_bot"
    case delegateBot = "delegate_bot"
}

/// Stable persisted grant for one peer action and one target bot.
func peerAllowKey(action: PeerAction, senderBotId: String, targetBotId: String) -> String {
    "\(action.rawValue):\(senderBotId):\(targetBotId)"
}

struct PendingPeerApproval: Identifiable, Equatable, Sendable {
    let id: String           // requestId
    let fromBotId: String
    let toBotId: String
    let action: PeerAction
    let message: String
    let createdAt: Date
}

enum PeerRequestOutcome: Equatable {
    /// A remembered always-allow grant covered this pair — proceed silently.
    case allowedByExistingGrant
    /// A card was raised; answer via resolve(requestId:allow:).
    case pendingCard(requestId: String)
}

enum PeerResolveOutcome: Equatable {
    case resolved(allowed: Bool)
    /// Unknown or already-expired requestId.
    case unknownRequest
}

final class PeerApprovalCoordinator: @unchecked Sendable {
    /// How long a card may sit unanswered before it auto-denies.
    static let approvalTimeout: TimeInterval = 15 * 60

    private let lock = NSLock()
    private var pending: [String: PendingPeerApproval] = [:]
    private var grants: Set<String> = []   // peerAllowKey strings

    // MARK: Grants ("Always allow")

    func hasGrant(action: PeerAction, senderBotId: String, targetBotId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return grants.contains(peerAllowKey(action: action, senderBotId: senderBotId, targetBotId: targetBotId))
    }

    func addGrant(action: PeerAction, senderBotId: String, targetBotId: String) {
        lock.lock()
        defer { lock.unlock() }
        grants.insert(peerAllowKey(action: action, senderBotId: senderBotId, targetBotId: targetBotId))
    }

    func revokeGrant(action: PeerAction, senderBotId: String, targetBotId: String) {
        lock.lock()
        defer { lock.unlock() }
        grants.remove(peerAllowKey(action: action, senderBotId: senderBotId, targetBotId: targetBotId))
    }

    func grantKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return grants.sorted()
    }

    // MARK: Request lifecycle

    /// Ask whether `from` may `action` `to`. If an always-allow grant already
    /// covers the (action, sender, target) tuple this returns immediately; otherwise a
    /// pending card is raised.
    func requestApproval(
        fromBotId: String,
        toBotId: String,
        action: PeerAction,
        message: String,
        now: Date = Date()
    ) -> PeerRequestOutcome {
        if hasGrant(action: action, senderBotId: fromBotId, targetBotId: toBotId) {
            return .allowedByExistingGrant
        }
        lock.lock()
        defer { lock.unlock() }
        let requestId = "pa_" + UUID().uuidString
        pending[requestId] = PendingPeerApproval(
            id: requestId,
            fromBotId: fromBotId,
            toBotId: toBotId,
            action: action,
            message: message,
            createdAt: now)
        return .pendingCard(requestId: requestId)
    }

    /// Answer a card. An "allow" also remembers the grant when requested.
    @discardableResult
    func resolve(requestId: String, allow: Bool, rememberGrant: Bool = false) -> PeerResolveOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let request = pending.removeValue(forKey: requestId) else { return .unknownRequest }
        if allow && rememberGrant {
            grants.insert(peerAllowKey(
                action: request.action,
                senderBotId: request.fromBotId,
                targetBotId: request.toBotId
            ))
        }
        return .resolved(allowed: allow)
    }

    /// Auto-deny cards older than the timeout (call on a timer or per turn).
    func expireStale(now: Date = Date()) -> [PendingPeerApproval] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Self.approvalTimeout)
        let stale = pending.values.filter { $0.createdAt < cutoff }
        for request in stale {
            pending.removeValue(forKey: request.id)
        }
        return stale
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    var pendingRequests: [PendingPeerApproval] {
        lock.lock()
        defer { lock.unlock() }
        return pending.values.sorted { $0.createdAt < $1.createdAt }
    }

    func pendingRequest(id: String) -> PendingPeerApproval? {
        lock.lock()
        defer { lock.unlock() }
        return pending[id]
    }
}
