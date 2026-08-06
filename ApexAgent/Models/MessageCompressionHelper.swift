import Foundation

enum MessageCompressionHelper {

    /// Compress old tool result and assistant text messages to reduce token pressure.
    /// Preserves the last `keepRecent` messages unchanged.
    static func compressMessages(_ messages: [ChatMessage], keepRecent: Int = 4) -> [ChatMessage] {
        guard messages.count > keepRecent + 1 else { return messages }

        var result: [ChatMessage] = []
        let middleEnd = messages.count - keepRecent

        for i in 0..<middleEnd {
            var msg = messages[i]
            if msg.role == .assistant, msg.content.count > 240 {
                msg.content = String(msg.content.prefix(140)) + "..."
            }
            result.append(msg)
        }

        result.append(contentsOf: messages.suffix(keepRecent))
        return result
    }

    static func estimateTokenCount(messages: [ChatMessage]) -> Int {
        let total = messages.reduce(0) { $0 + $1.content.count }
        return max(1, total / 4)
    }
}
