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


public struct CompressionMetrics: Sendable, Equatable {
    public let originalTokens: Int
    public let compressedTokens: Int
    public let tokensSaved: Int

    public var compressionRatio: Double {
        originalTokens > 0 ? Double(compressedTokens) / Double(originalTokens) : 1.0
    }

    public var savingsPercentage: Double {
        (1.0 - compressionRatio) * 100.0
    }

    public func summary() -> String {
        "Saved \(tokensSaved) tokens (\(String(format: "%.1f%%", savingsPercentage)) reduction)"
    }
}

extension MessageCompressionHelper {
    public static func compressWithMetrics(_ messages: [ChatMessage], keepRecent: Int = 4) -> (compressed: [ChatMessage], metrics: CompressionMetrics) {
        let origTokens = estimateTokenCount(messages: messages)
        let compressed = compressMessages(messages, keepRecent: keepRecent)
        let compTokens = estimateTokenCount(messages: compressed)
        let saved = max(0, origTokens - compTokens)

        let metrics = CompressionMetrics(
            originalTokens: origTokens,
            compressedTokens: compTokens,
            tokensSaved: saved
        )
        return (compressed, metrics)
    }
}
