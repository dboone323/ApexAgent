import SwiftUI

// MARK: - Ambient Approval Surface & Decision Inbox (Phase 7)

/// Global ambient surface that monitors all pending human-in-the-loop decisions
/// (Playbook approval cards and peer-to-peer delegation requests) across any active workspace
/// (Bots, Spaces, or General Chat).
struct AmbientApprovalSurfaceView: View {
    @Environment(BotManager.self) private var botManager

    private var activeBotIdString: String? {
        botManager.activeSession?.bot.id.uuidString
    }

    /// Peer approvals that are NOT currently rendered in the active 1:1 BotChatView
    var ambientPeerApprovals: [PendingPeerApproval] {
        if let currentBotId = activeBotIdString {
            return botManager.pendingPeerApprovals.filter { $0.fromBotId != currentBotId }
        } else {
            return botManager.pendingPeerApprovals
        }
    }

    /// Playbook runners awaiting approval that are NOT currently rendered in the active 1:1 BotChatView
    var ambientPlaybookApprovals: [(card: PlaybookApprovalCard, runner: PlaybookRunner)] {
        let runnersWithCards = botManager.activePlaybookRunners.compactMap { runner -> (PlaybookApprovalCard, PlaybookRunner)? in
            runner.pendingApprovalCard.map { ($0, runner) }
        }
        if botManager.activeSession != nil, let activeRunner = botManager.activePlaybookRunner, let activeCard = activeRunner.pendingApprovalCard {
            return runnersWithCards.filter { $0.0.id != activeCard.id }
        } else {
            return runnersWithCards
        }
    }

    var body: some View {
        let peerApprovals = ambientPeerApprovals
        let playbookApprovals = ambientPlaybookApprovals
        let totalCount = peerApprovals.count + playbookApprovals.count

        if totalCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 13, weight: .bold))
                    Text("Decision Inbox")
                        .font(.system(size: 13, weight: .semibold))
                    Text("(\(totalCount) pending)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                ForEach(peerApprovals) { request in
                    PeerApprovalCard(request: request, botManager: botManager)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                }

                ForEach(playbookApprovals, id: \.card.id) { pair in
                    PlaybookApprovalBannerView(card: pair.card, runner: pair.runner)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                }

                Divider()
                    .padding(.top, 4)
            }
            .background(Color.orange.opacity(0.08))
            .accessibilityIdentifier("ambientApprovalSurface")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
