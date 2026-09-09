import Foundation

public struct CompactionInput {
    public let messages: [(role: String, content: String)]
    public let maxTokenBudget: Int       // target max approximate tokens to keep
    public let pinnedSystemPrompt: String // always preserved verbatim
    public let recentTurnsToPreserve: Int // last N user+assistant turns kept verbatim
}

public struct CompactionResult {
    public let compactedMessages: [(role: String, content: String)]
    public let summarizedTurnCount: Int
    public let approximateTokensSaved: Int
    public let summary: String  // the synthesized digest of removed turns
}

public actor ContextCompactor {
    public static let shared = ContextCompactor()
    
    private init() {}
    
    // Approximate token count (chars / 4 heuristic for English + code)
    public func approximateTokenCount(_ text: String) -> Int {
        return max(1, text.count / 4)
    }
    
    // Compact a message sequence to stay within budget
    public func compact(_ input: CompactionInput) -> CompactionResult {
        var compacted: [(role: String, content: String)] = []
        compacted.append((role: "system", content: input.pinnedSystemPrompt))
        
        // Filter user and assistant messages, ignore system messages for now
        let conversationMessages = input.messages.filter { $0.role != "system" }
        
        let turnsToKeep = input.recentTurnsToPreserve * 2 // each turn is usually user + assistant
        let startIndexForVerbatim = max(0, conversationMessages.count - turnsToKeep)
        let verbatimMessages = Array(conversationMessages[startIndexForVerbatim...])
        let olderMessages = Array(conversationMessages[..<startIndexForVerbatim])
        
        var bulletPoints = ""
        var originalTokens = 0
        var summarizedTurnCount = 0
        
        if !olderMessages.isEmpty {
            for i in stride(from: 0, to: olderMessages.count, by: 1) {
                let msg = olderMessages[i]
                originalTokens += approximateTokenCount(msg.content)
                summarizedTurnCount += 1
                let prefix = String(msg.content.prefix(100)).replacingOccurrences(of: "\n", with: " ")
                bulletPoints += "• [\(msg.role)]: \(prefix)...\n"
            }
            
            let summaryText = "[Context Summary — \(summarizedTurnCount) older turns]:\n\(bulletPoints)"
            compacted.append((role: "system", content: summaryText))
        }
        
        compacted.append(contentsOf: verbatimMessages)
        
        let newSummaryTokens = bulletPoints.isEmpty ? 0 : approximateTokenCount("[Context Summary — \(summarizedTurnCount) older turns]:\n\(bulletPoints)")
        let tokensSaved = max(0, originalTokens - newSummaryTokens)
        
        return CompactionResult(
            compactedMessages: compacted,
            summarizedTurnCount: summarizedTurnCount,
            approximateTokensSaved: tokensSaved,
            summary: bulletPoints
        )
    }
    
    // Should we compact? Returns true if estimated tokens exceed threshold
    public func shouldCompact(messages: [(role: String, content: String)], threshold: Int) -> Bool {
        let totalTokens = messages.reduce(0) { $0 + approximateTokenCount($1.content) }
        return totalTokens > threshold
    }
}
