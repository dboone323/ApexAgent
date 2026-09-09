import Foundation
import FoundationModels
import Observation

// MARK: - Ask Bot Tool (Inter-Bot Task Delegation)
//
// Enables inter-bot task delegation through BotManager.peerDeliveryDecision,
// respecting peer approval gates and executing requests in the target bot's session.
//
// AskBotTool stores a reference to BotManager (which is @MainActor + @Observable).
// Every access to botManager is serialised through explicit Task { @MainActor in ... }
// hops inside call(), so the method itself is not actor-isolated. This allows the
// AnyExecutableTool wrapper in Tool+Logging.swift to capture it in a @Sendable closure
// without violating Sendable invariants.
//
// @unchecked Sendable: the struct holds a @MainActor-isolated reference, so it cannot
// be provably Sendable. The suppression is justified because all botManager access is
// confined to MainActor hops and the AnyExecutableTool wrapper does not expose the
// tool reference to non-isolated concurrent mutation contexts.

struct AskBotTool: Tool, @unchecked Sendable {
    let botManager: BotManager?

    init(botManager: BotManager?) {
        self.botManager = botManager
    }

    let name = "ask_bot"
    let description = "Delegates a specific task or question to another registered Bot through the peer delivery gate. Returns the bot's response."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The name or UUID of the target bot to delegate to.")
        var targetBot: String

        @Guide(description: "The instructions, prompt, or question to send to the target bot.")
        var message: String
    }

    private enum DelegationPreflight: Sendable {
        case managerUnavailable
        case targetNotFound(String)
        case senderNotFound
        case blocked(requestId: String, targetName: String)
        case allowed(targetId: UUID, targetName: String)
    }

    func call(arguments: Arguments) async throws -> String {
        // Resolved on the main actor — BotManager is @MainActor-isolated.
        // Use an explicit @MainActor hop so the enclosing method is not
        // actor-isolated (required for @Sendable capture in AnyExecutableTool).
        let preflight: DelegationPreflight = await Task { @MainActor in
            guard let botManager else {
                return .managerUnavailable
            }
            guard let target = resolveTarget(targetBot: arguments.targetBot) else {
                return .targetNotFound(arguments.targetBot)
            }

            guard let senderBot = resolveSender() else {
                return .senderNotFound
            }

            let decision = botManager.peerDeliveryDecision(from: senderBot, to: target, message: arguments.message)
            switch decision {
            case .blockedPendingCard(let requestId):
                return .blocked(requestId: requestId, targetName: target.name)
            case .deliver:
                return .allowed(targetId: target.id, targetName: target.name)
            }
        }.value

        switch preflight {
        case .targetNotFound(let name):
            return "ERROR: Target bot '\(name)' not found."
        case .senderNotFound:
            return "ERROR: No active sender bot found."
        case .blocked(let requestId, let targetName):
            return "Peer approval required: A pending approval card (ID: \(requestId)) has been raised to contact '\(targetName)'."
        case .allowed(let targetId, let targetName):
            // Deliver the message to the target bot's session. The session owns
            // the generation; we wait for it to complete and return the result.
            let sanitizedInbound = SecretRedactor.redact(text: arguments.message)
            let response: String? = await Task { @MainActor in
                guard let botManager else { return nil }
                guard let bot = botManager.bot(byId: targetId) else { return nil }
                let session = botManager.session(for: bot)
                return await session.sendMessageAsync(sanitizedInbound)
            }.value

            if let text = response, !text.isEmpty {
                return SecretRedactor.redact(text: text)
            }
            return "Bot '\(targetName)' finished processing with no output."
        case .managerUnavailable:
            // Unreachable — botManager is non-optional and set at init.
            return "ERROR: BotManager is not available."
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func resolveTarget(targetBot: String) -> BotProfile? {
        guard let botManager else { return nil }
        if let uuid = UUID(uuidString: targetBot) {
            return botManager.bot(byId: uuid)
        }
        return botManager.botByName(targetBot)
    }

    @MainActor
    private func resolveSender() -> BotProfile? {
        guard let botManager else { return nil }
        return botManager.activeSession?.bot
            ?? botManager.allBots.first(where: { $0.isChiefOfStaff })
            ?? botManager.allBots.first
    }
}
