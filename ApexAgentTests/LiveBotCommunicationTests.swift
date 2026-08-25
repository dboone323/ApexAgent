import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - LIVE bot-to-bot communication (real-world verification)
//
// These tests exercise the PRODUCTION paths — BotManager routing,
// peer-approval gating, BotMessageSender, AgentEngine streaming against the
// real on-device Foundation Model — not mocks. They are skipped unless
// APEX_LIVE_BOTS=1 so normal `swift test` stays fast and hermetic.
//
// Run for real-world verification:
//   APEX_LIVE_BOTS=1 swift test --filter LiveBotCommunicationTests
@MainActor
@Suite("LiveBotCommunicationTests")
struct LiveBotCommunicationTests {

    /// Poll until the bot produced a finished assistant reply, or time out.
    private func waitForReply(
        _ session: BotSession,
        afterMessageCount baseline: Int,
        timeout: TimeInterval = 120
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let last = session.messages.last(where: { $0.role == .assistant }),
               session.messages.count > baseline,
               !last.isStreaming,
               !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return last.content
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        struct ReplyTimeout: Error {}
        throw ReplyTimeout()
    }

    @Test("specialist bot answers a direct hand-off through the live model",
          .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_BOTS"] == "1"))
    func specialistAnswersDirectHandoff() async throws {
        let manager = BotManager(orchestrator: AgentOrchestrator(), computer: Computer())
        let writer = manager.createBot(
            name: "Writer",
            title: "Copywriter",
            descriptionText: "You are terse. Always answer with exactly one short sentence.")
        let session = manager.session(for: writer)

        let baseline = session.messages.count
        manager.sendMessageTo(writer, text: "Confirm you received this hand-off by saying READY.")

        let reply = try await waitForReply(session, afterMessageCount: baseline)
        #expect(!reply.isEmpty)
        #expect(!reply.contains("⚠️"))          // engine errors surface as ⚠️
        #expect(reply.lowercased().contains("ready"))
    }

    @Test("peer-gated chief hand-off unblocks after approval and gets a reply",
          .enabled(if: ProcessInfo.processInfo.environment["APEX_LIVE_BOTS"] == "1"))
    func peerGatedHandoffUnblocksAfterApproval() async throws {
        let manager = BotManager(orchestrator: AgentOrchestrator(), computer: Computer())
        let chief = manager.createBot(name: "Chief", title: "Coordinator", descriptionText: "Coordinates work.")
        let researcher = manager.createBot(
            name: "Researcher",
            title: "Analyst",
            descriptionText: "You are terse. Always answer with exactly one short sentence.")

        // Chief (bot-initiated) contacts Researcher without a grant → held.
        guard case .blockedPendingCard(let requestId) =
            manager.peerDeliveryDecision(from: chief, to: researcher, message: "Are you online? Say ONLINE.") else {
            Issue.record("expected the first peer contact to be gated"); return
        }
        #expect(manager.session(for: chief).needsAttention)
        #expect(manager.session(for: researcher).messages.isEmpty)

        // Human approves (remembering the grant).
        #expect(manager.resolvePeerRequest(requestId: requestId, allow: true, remember: true))

        // Now deliver the held message through the real sender.
        let session = manager.session(for: researcher)
        let baseline = session.messages.count
        manager.sendMessageTo(researcher, text: "Are you online? Say ONLINE.")

        let reply = try await waitForReply(session, afterMessageCount: baseline)
        #expect(!reply.contains("⚠️"))
        #expect(reply.lowercased().contains("online"))

        // The grant must now cover future asks silently.
        #expect(manager.peerDeliveryDecision(from: chief, to: researcher, message: "again") == .deliver)
    }
}
