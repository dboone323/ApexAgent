import Foundation

// MARK: - DiscordMessageParser
//
// Parses raw Discord messages into structured types for agent routing.
// Handles three message categories:
//   - .agentDirected: directly addresses an agent
//   - .agentStatus:   agent status/broadcast
//   - .humanMessage:  ordinary user chatter

enum DiscordMessageType: String, Codable, Sendable {
    case agentDirected
    case agentStatus
    case humanMessage
}

struct DiscordParsedMessage: Sendable {
    let mentionedAgents: [String]
    let messageType: DiscordMessageType
    let rawContent: String
    let senderName: String
    let senderId: String
}

    // MARK: - Parser

enum DiscordMessageParser {

    // Known agent handles (lowercased for matching)
    private static let knownAgentHandles: Set<String> = [
        "apexagent", "clawd", "kodi",
    ]

    // Map of Discord numeric user IDs -> canonical handle names
    private static let knownAgentIds: [String: String] = [
        "1537957778998431775": "ApexAgent",
        "1445949064465223690": "Clawd",
        "1484763946195095642": "Kodi",
    ]

    /// Parse a raw Discord API message dict
    static func parse(_ message: [String: Any]) -> DiscordParsedMessage? {
        guard let author = message["author"] as? [String: Any],
              let senderId = author["id"] as? String,
              let senderName = author["username"] as? String,
              let rawContent = message["content"] as? String else {
            return nil
        }

        let mentionedAgents = extractMentionedAgents(from: rawContent)
        let messageType = classify(rawContent: rawContent, mentionedAgents: mentionedAgents)

        return DiscordParsedMessage(
            mentionedAgents: mentionedAgents,
            messageType: messageType,
            rawContent: rawContent,
            senderName: senderName,
            senderId: senderId
        )
    }

    /// Parse from pre-extracted strings
    static func parse(content: String, senderName: String, senderId: String) -> DiscordParsedMessage {
        let mentionedAgents = extractMentionedAgents(from: content)
        let messageType = classify(rawContent: content, mentionedAgents: mentionedAgents)

        return DiscordParsedMessage(
            mentionedAgents: mentionedAgents,
            messageType: messageType,
            rawContent: content,
            senderName: senderName,
            senderId: senderId
        )
    }

    // MARK: - Extraction

    private static func extractMentionedAgents(from content: String) -> [String] {
        var agents: [String] = []

        // 1. Numeric mention syntax <@123456789> or <@!123456789>
        if let numericPattern = try? NSRegularExpression(pattern: #"<@!?(\d+)>"#) {
            let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
            let matches = numericPattern.matches(in: content, range: nsRange)
            for match in matches where match.numberOfRanges > 1 {
                if let r = Range(match.range(at: 1), in: content) {
                    let numericId = String(content[r])
                    if let name = knownAgentIds[numericId], !agents.contains(name) {
                        agents.append(name)
                    }
                }
            }
        }

        // 2. Word mentions @handle
        if let atPattern = try? NSRegularExpression(pattern: #"@([A-Za-z0-9_]+)"#) {
            let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
            let matches = atPattern.matches(in: content, range: nsRange)
            for match in matches where match.numberOfRanges > 1 {
                if let r = Range(match.range(at: 1), in: content) {
                    let handle = String(content[r])
                    let lowered = handle.lowercased()
                    if knownAgentHandles.contains(lowered) && !agents.contains(handle) {
                        agents.append(handle)
                    }
                }
            }
        }

        // 3. Bracket mentions [handle]
        if let bracketPattern = try? NSRegularExpression(pattern: #"\[([A-Za-z0-9_]+)\]"#) {
            let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
            let matches = bracketPattern.matches(in: content, range: nsRange)
            for match in matches where match.numberOfRanges > 1 {
                if let r = Range(match.range(at: 1), in: content) {
                    let handle = String(content[r])
                    let lowered = handle.lowercased()
                    if knownAgentHandles.contains(lowered) && !agents.contains(handle) {
                        agents.append(handle)
                    }
                }
            }
        }

        return agents
    }

    // MARK: - Classification

    private static func classify(rawContent: String, mentionedAgents: [String]) -> DiscordMessageType {
        if let atPattern = try? NSRegularExpression(pattern: #"^@([A-Za-z0-9_]+)$"#) {
            let nsRange = NSRange(rawContent.startIndex..<rawContent.endIndex, in: rawContent)
            if atPattern.firstMatch(in: rawContent, range: nsRange) != nil {
                if mentionedAgents.contains(where: { knownAgentHandles.contains($0.lowercased()) }) {
                    return .agentDirected
                }
            }
        }

        let trimmed = rawContent.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@") {
            let firstWord = trimmed.split(separator: " ").first?.description ?? ""
            let lowered = firstWord.lowercased().replacingOccurrences(of: "@", with: "")
            if knownAgentHandles.contains(lowered) {
                return .agentDirected
            }
        }

        if let bracketPattern = try? NSRegularExpression(pattern: #"\[([A-Za-z0-9_]+)\]"#) {
            let nsRange = NSRange(rawContent.startIndex..<rawContent.endIndex, in: rawContent)
            if let match = bracketPattern.firstMatch(in: rawContent, range: nsRange), match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: rawContent) {
                let handle = String(rawContent[r])
                let lowered = handle.lowercased()
                if knownAgentHandles.contains(lowered) {
                    return .agentStatus
                }
                if match.range.location == 0 {
                    return .agentStatus
                }
            }
        }

        return .humanMessage
    }
}

// MARK: - Equatable for testing

extension DiscordParsedMessage: Equatable {
    static func == (lhs: DiscordParsedMessage, rhs: DiscordParsedMessage) -> Bool {
        lhs.mentionedAgents == rhs.mentionedAgents &&
        lhs.messageType == rhs.messageType &&
        lhs.rawContent == rhs.rawContent &&
        lhs.senderName == rhs.senderName &&
        lhs.senderId == rhs.senderId
    }
}
