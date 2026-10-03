import Foundation
import FoundationModels
import AppKit

// MARK: - Bot-to-Bot Calling Tool (WS4)
//
// Allows an AI agent to query another Bot teammate during execution.
// The peer approval coordinator gates each call: if an "always allow" grant
// is not recorded, execution pauses with a pending approval card raised to the user.
//
// All cross-bot transcripts are subject to secret redaction (SecretRedactor)
// before delivery, ensuring no leaked keys or environment variables traverse agents.

struct AskBotTool: Tool {
    let orchestrator: OrchestratorProvider
    var currentBotId: UUID?

    init(orchestrator: OrchestratorProvider, currentBotId: UUID? = nil) {
        self.orchestrator = orchestrator
        self.currentBotId = currentBotId
    }

    let name = "ask_bot"
    let description = """
    Sends a query to a named Bot teammate and returns their response. \
    Use this to delegate subtasks to specialized bots (e.g. asking the Code Architect \
    to review a snippet, or asking the Researcher for domain knowledge). \
    If peer approval is required, the call will pause until the user decides.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The name or UUID of the Bot teammate to query.")
        var targetBot: String

        @Guide(description: "The message or task prompt to send to the Bot.")
        var message: String
    }

    enum PreflightResult {
        case allowed(targetId: UUID, targetName: String)
        case blocked(requestId: String, targetName: String)
        case targetNotFound(String)
        case senderNotFound
        case managerUnavailable
    }

    func call(arguments: Arguments) async throws -> String {
        try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            // 1. Resolve target bot & check peer approval on MainActor
            let preflight: PreflightResult = await MainActor.run {
                let bm = self.orchestrator.orchestrator.botManager
                guard let bm else { return .managerUnavailable }

                guard let target = resolveTarget(targetBot: arguments.targetBot, botManager: bm) else {
                    return .targetNotFound(arguments.targetBot)
                }

                // Resolve sender bot
                let senderId = self.currentBotId ?? bm.activeBotId
                guard let senderId, let sender = bm.bot(byId: senderId) else {
                    return .senderNotFound
                }

                // Check peer-to-peer delivery decision
                switch bm.peerDeliveryDecision(from: sender, to: target, message: arguments.message) {
                case .blockedPendingCard(let requestId):
                    return .blocked(requestId: requestId, targetName: target.name)
                case .deliver:
                    return .allowed(targetId: target.id, targetName: target.name)
                }
            }

            switch preflight {
            case .targetNotFound(let name):
                return "ERROR: Target bot '\(name)' not found."
            case .senderNotFound:
                return "ERROR: No active sender bot found."
            case .blocked(let requestId, let targetName):
                return "Peer approval required: A pending approval card (ID: \(requestId)) has been raised to contact '\(targetName)'."
            case .allowed(let targetId, let targetName):
                let sanitizedInbound = SecretRedactor.redact(text: arguments.message)
                let finalResponse = await sendToBot(targetId: targetId, message: sanitizedInbound)

                if let text = finalResponse, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return SecretRedactor.redact(text: text)
                }
                return "Bot '\(targetName)' finished processing with no output."
            case .managerUnavailable:
                return "ERROR: BotManager is not available."
            }
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func sendToBot(targetId: UUID, message: String) async -> String? {
        let bm = self.orchestrator.orchestrator.botManager
        guard let bm, let bot = bm.bot(byId: targetId) else { return nil }
        let session = bm.session(for: bot)
        return await session.sendMessageAsync(message)
    }

    @MainActor
    private func resolveTarget(targetBot: String, botManager: BotManager) -> BotProfile? {
        if let uuid = UUID(uuidString: targetBot) {
            return botManager.bot(byId: uuid)
        }
        return botManager.botByName(targetBot)
    }
}
