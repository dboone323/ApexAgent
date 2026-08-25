import Foundation
import FoundationModels

// MARK: - Discord Bot Tool (2-way communication via bot token)
//
// Posts, reads, replies, edits, deletes, and reacts to messages in a
// Discord channel using a bot token. Uses DISCORD_APEX_TOKEN env var or
// UserDefaults key "apex.discordBotToken".
//
// Bot identity: @ApexAgent (ID: 1537957778998431775).
// Mirrors the patterns used by Hermes/OpenClaw Discord adapters
// (Authorization: Bot *** REST API calls to Discord).

struct DiscordBotTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "discord_bot"
    let description = """
        Two-way Discord communication via bot token.
        Posts, reads, replies, edits, deletes, and reacts to messages
        in a Discord channel. Configure the bot token in environment
        variable DISCORD_APEX_TOKEN or UserDefaults key
        "apex.discordBotToken". Bot identity: @ApexAgent
        (ID: 1537957778998431775).
        """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Discord channel ID to interact with (numeric string)")
        var channelId: String

        @Guide(description: "Action to perform: 'post', 'read', 'reply', 'edit', 'delete', or 'react'")
        var action: String

        @Guide(description: "Message content to post/reply/edit (required for post/reply/edit)")
        var message: String?

        @Guide(description: "Message ID to reply to / edit / delete (required for reply/edit/delete)")
        var messageId: String?

        @Guide(description: "Reaction emoji to add (required for 'react' action, e.g. '👍', '✅', '🔥')")
        var emoji: String?

        @Guide(description: "Number of recent messages to read (default 10, for 'read' action)")
        var limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let token = getBotToken()
            guard let token, !token.isEmpty else {
                throw NSError(domain: "DiscordBot", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No bot token configured. Set DISCORD_APEX_TOKEN env var or apex.discordBotToken in UserDefaults."])
            }

            let channelId = arguments.channelId
            guard !channelId.isEmpty else {
                throw NSError(domain: "DiscordBot", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No channel ID specified."])
            }

            switch arguments.action {
            case "post":
                guard let message = arguments.message, !message.isEmpty else {
                    throw NSError(domain: "DiscordBot", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "No message content provided for post action."])
                }
                return try await postMessage(token: token, channelId: channelId, message: message)

            case "read":
                let limit = arguments.limit ?? 10
                return try await readMessages(token: token, channelId: channelId, limit: limit)

            case "reply":
                guard let message = arguments.message, !message.isEmpty else {
                    throw NSError(domain: "DiscordBot", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "No message content provided for reply action."])
                }
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    throw NSError(domain: "DiscordBot", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "No message ID provided for reply action."])
                }
                return try await replyToMessage(token: token, channelId: channelId, messageId: messageId, message: message)

            case "edit":
                guard let message = arguments.message, !message.isEmpty else {
                    throw NSError(domain: "DiscordBot", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "No message content provided for edit action."])
                }
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    throw NSError(domain: "DiscordBot", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "No message ID provided for edit action."])
                }
                return try await editMessage(token: token, channelId: channelId, messageId: messageId, message: message)

            case "delete":
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    throw NSError(domain: "DiscordBot", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "No message ID provided for delete action."])
                }
                return try await deleteMessage(token: token, channelId: channelId, messageId: messageId)

            case "react":
                guard let emoji = arguments.emoji, !emoji.isEmpty else {
                    throw NSError(domain: "DiscordBot", code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "No emoji provided for react action."])
                }
                guard let messageId = arguments.messageId, !messageId.isEmpty else {
                    throw NSError(domain: "DiscordBot", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "No message ID provided for react action."])
                }
                return try await addReaction(token: token, channelId: channelId, messageId: messageId, emoji: emoji)

            default:
                throw NSError(domain: "DiscordBot", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown action '\(arguments.action)'. Use: post, read, reply, edit, delete, react."])
            }
        }
    }

    // MARK: - Bot Token

    private func getBotToken() -> String? {
        ProcessInfo.processInfo.environment["DISCORD_APEX_TOKEN"]
            ?? UserDefaults.standard.string(forKey: "apex.discordBotToken")
    }

    // MARK: - POST Message

    private func postMessage(token: String, channelId: String, message: String) async throws -> String {
        guard let url = URL(string: "https://discord.com/api/v10/channels/\(channelId)/messages") else {
            throw NSError(domain: "DiscordBot", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid channel URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let payload: [String: Any] = ["content": message]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "DiscordBot", code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "POST failed with status \(statusCode)"])
        }

        return "✅ Posted to #\(channelId): \"\(message)\""
    }

    // MARK: - READ Messages

    private func readMessages(token: String, channelId: String, limit: Int) async throws -> String {
        guard let url = URL(string: "https://discord.com/api/v10/channels/\(channelId)/messages?limit=\(limit)") else {
            throw NSError(domain: "DiscordBot", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid channel URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "DiscordBot", code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GET failed with status \(statusCode)"])
        }

        let messages: [[String: Any]]
        do {
            messages = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        } catch {
            throw NSError(domain: "DiscordBot", code: 20, userInfo: [NSLocalizedDescriptionKey: "Failed to parse response: \(error.localizedDescription)"])
        }

        if messages.isEmpty {
            return "📭 No messages found in channel #\(channelId)."
        }

        var output = "📋 Recent messages in #\(channelId) (\(messages.count) found):\n"
        for msg in messages {
            let author = msg["author"] as? [String: Any] ?? [:]
            let authorName = author["username"] as? String ?? "unknown"
            let authorId = author["id"] as? String ?? "?"
            let content = msg["content"] as? String ?? "(empty)"
            let timestamp = msg["timestamp"] as? String ?? "?"
            let isBot = author["bot"] as? Bool ?? false
            output += "  [\(timestamp)] @\(authorName) (\(authorId), bot=\(isBot)): \(content)\n"
        }
        return output
    }

    // MARK: - REPLY to Message

    private func replyToMessage(token: String, channelId: String, messageId: String, message: String) async throws -> String {
        guard let url = URL(string: "https://discord.com/api/v10/channels/\(channelId)/messages") else {
            throw NSError(domain: "DiscordBot", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid channel URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let payload: [String: Any] = [
            "content": message,
            "message_reference": ["message_id": messageId]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "DiscordBot", code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Reply failed with status \(statusCode)"])
        }

        return "✅ Replied to #\(channelId) message \(messageId): \"\(message)\""
    }

    // MARK: - EDIT Message

    private func editMessage(token: String, channelId: String, messageId: String, message: String) async throws -> String {
        guard let url = URL(string: "https://discord.com/api/v10/channels/\(channelId)/messages/\(messageId)") else {
            throw NSError(domain: "DiscordBot", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid channel URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let payload: [String: Any] = ["content": message]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "DiscordBot", code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Edit failed with status \(statusCode)"])
        }

        return "✅ Edited #\(channelId) message \(messageId): \"\(message)\""
    }

    // MARK: - DELETE Message

    private func deleteMessage(token: String, channelId: String, messageId: String) async throws -> String {
        guard let url = URL(string: "https://discord.com/api/v10/channels/\(channelId)/messages/\(messageId)") else {
            throw NSError(domain: "DiscordBot", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid channel URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "DiscordBot", code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Delete failed with status \(statusCode)"])
        }

        return "✅ Deleted #\(channelId) message \(messageId)"
    }

    // MARK: - ADD REACTION

    private func addReaction(token: String, channelId: String, messageId: String, emoji: String) async throws -> String {
        // Discord uses the emoji name without colons for custom emojis,
        // but for standard Unicode emojis we use the emoji itself.
        // URL-encode the emoji for the path.
        guard let encodedEmoji = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://discord.com/api/v10/channels/\(channelId)/messages/\(messageId)/reactions/\(encodedEmoji)/@me") else {
            throw NSError(domain: "DiscordBot", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid URL for reaction."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "DiscordBot", code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "React failed with status \(statusCode)"])
        }

        return "✅ Reacted \(emoji) to #\(channelId) message \(messageId)"
    }
}
