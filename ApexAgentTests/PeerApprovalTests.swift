import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O9: Peer approval gate

@Suite("PeerApprovalTests")
struct PeerApprovalTests {

    @Test func allowKeyFormat() {
        #expect(peerAllowKey(action: .askBot, senderBotId: "bot-2", targetBotId: "bot-7") == "ask_bot:bot-2:bot-7")
        #expect(peerAllowKey(action: .delegateBot, senderBotId: "bot-2", targetBotId: "bot-7") == "delegate_bot:bot-2:bot-7")
    }

    @Test func requestWithoutGrantRaisesCardThenResolves() {
        let coordinator = PeerApprovalCoordinator()
        guard case .pendingCard(let requestId) = coordinator.requestApproval(
            fromBotId: "research", toBotId: "comms", action: .askBot, message: "need numbers") else {
            Issue.record("expected a pending card")
            return
        }
        #expect(coordinator.pendingCount == 1)
        let outcome = coordinator.resolve(requestId: requestId, allow: true)
        #expect(outcome == .resolved(allowed: true))
        #expect(coordinator.pendingCount == 0)
        #expect(coordinator.resolve(requestId: requestId, allow: false) == .unknownRequest)
    }

    @Test func existingGrantAllowsImmediately() {
        let coordinator = PeerApprovalCoordinator()
        coordinator.addGrant(action: .delegateBot, senderBotId: "chief", targetBotId: "writer")
        let outcome = coordinator.requestApproval(
            fromBotId: "chief", toBotId: "writer", action: .delegateBot, message: "draft it")
        #expect(outcome == .allowedByExistingGrant)
        #expect(coordinator.pendingCount == 0)
    }

    @Test func alwaysAllowRememberedOnResolveGrantsFutureAsks() {
        let coordinator = PeerApprovalCoordinator()
        guard case .pendingCard(let id) = coordinator.requestApproval(
            fromBotId: "a", toBotId: "b", action: .askBot, message: "hi") else {
            Issue.record("expected pending")
            return
        }
        _ = coordinator.resolve(requestId: id, allow: true, rememberGrant: true)
        #expect(coordinator.hasGrant(action: .askBot, senderBotId: "a", targetBotId: "b"))

        let next = coordinator.requestApproval(fromBotId: "a", toBotId: "b", action: .askBot, message: "again")
        #expect(next == .allowedByExistingGrant)

        // A different target still needs its own approval.
        let other = coordinator.requestApproval(fromBotId: "a", toBotId: "c", action: .askBot, message: "hi c")
        #expect(other != .allowedByExistingGrant)
        let otherSender = coordinator.requestApproval(fromBotId: "c", toBotId: "b", action: .askBot, message: "hi b")
        #expect(otherSender != .allowedByExistingGrant)
    }

    @Test func staleCardsAutoDeny() {
        let now = Date()
        let coordinator = PeerApprovalCoordinator()
        _ = coordinator.requestApproval(fromBotId: "a", toBotId: "b", action: .askBot,
                                        message: "old", now: now.addingTimeInterval(-3600))
        _ = coordinator.requestApproval(fromBotId: "a", toBotId: "c", action: .askBot,
                                        message: "fresh", now: now)

        let expired = coordinator.expireStale(now: now)
        #expect(expired.count == 1)
        #expect(expired.first?.toBotId == "b")
        #expect(coordinator.pendingCount == 1)
    }
}
