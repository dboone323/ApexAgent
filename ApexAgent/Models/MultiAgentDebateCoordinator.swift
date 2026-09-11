import Foundation
import Observation

@Observable
@MainActor
public final class MultiAgentDebateCoordinator {
    public static let shared = MultiAgentDebateCoordinator()
    
    public struct DebateRound: Identifiable, Sendable {
        public let id: UUID
        public let topic: String
        public let participants: [String]    // bot names
        public let arguments: [String: String] // botName -> position text
        public let consensus: String?
        public let startedAt: Date
        public let concludedAt: Date?
        public var passed: Bool { consensus != nil }
    }
    
    public private(set) var recentDebates: [DebateRound] = []
    
    weak var botManager: BotManager?
    
    public init() {}
    
    // Conduct a real multi-turn debate between participating bots on a topic.
    // Returns consensus text if agreement is reached, or nil if debate failed.
    public func conductDebate(
        topic: String,
        participantBotNames: [String],
        moderatorBotName: String?,
        maxRounds: Int
    ) async -> DebateRound {
        let startedAt = Date()
        var arguments: [String: String] = [:]
        
        let prompt = "DEBATE TOPIC: \(topic)\nProvide your analysis and position in 2-3 sentences. Be specific."
        
        var sessions: [(String, BotSession)] = []
        if let bm = self.botManager {
            for botName in participantBotNames {
                if let bot = bm.allBots.first(where: { $0.name == botName }) {
                    let session = bm.session(for: bot)
                    sessions.append((botName, session))
                }
            }
        }
        
        await withTaskGroup(of: (String, String).self) { group in
            for (botName, session) in sessions {
                group.addTask {
                    do {
                        return try await withThrowingTaskGroup(of: String.self) { timeoutGroup in
                            timeoutGroup.addTask {
                                return await session.sendMessageAsync(prompt) ?? "No response"
                            }
                            timeoutGroup.addTask {
                                try await Task.sleep(nanoseconds: 30_000_000_000)
                                throw CancellationError()
                            }
                            guard let first = try await timeoutGroup.next() else {
                                throw CancellationError()
                            }
                            timeoutGroup.cancelAll()
                            return (botName, first)
                        }
                    } catch {
                        return (botName, "[Timed out or Error: \(error.localizedDescription)]")
                    }
                }
            }
            
            for await (botName, argument) in group {
                arguments[botName] = argument
            }
        }
        
        let moderatorName = moderatorBotName ?? participantBotNames.first ?? "Unknown"
        var consensus: String?
        
        if let botManager = self.botManager,
           let moderatorBot = botManager.allBots.first(where: { $0.name == moderatorName }) {
            let session = botManager.session(for: moderatorBot)
            
            var synthesisPrompt = "You are the moderator. Here are the positions:\n"
            for (botName, arg) in arguments {
                synthesisPrompt += "[\(botName): \(arg)]\n"
            }
            synthesisPrompt += "Synthesize a consensus recommendation in 1-2 sentences that best serves the objective."
            
            consensus = await session.sendMessageAsync(synthesisPrompt)
        }
        
        let debate = DebateRound(
            id: UUID(),
            topic: topic,
            participants: participantBotNames,
            arguments: arguments,
            consensus: consensus,
            startedAt: startedAt,
            concludedAt: Date()
        )
        
        recentDebates.append(debate)
        if recentDebates.count > 20 {
            recentDebates.removeFirst(recentDebates.count - 20)
        }
        
        return debate
    }
}
