import Foundation
import FoundationModels

// MARK: - Discord Webhook Post Tool
// Posts messages to a Discord channel via incoming webhook URL.
// No bot token needed — webhook URLs are channel-specific and carry
// the channel's identity. Configure WEBHOOK_URL in environment or
// UserDefaults (key: "apex.discordWebhookUrl").
//
// Usage from another tool or the orchestrator:
//   let tool = DiscordWebhookTool(orchestrator: self)
//   let result = try await tool.call(arguments: .init(message: "Hello from ApexAgent"))
//

struct DiscordWebhookTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "discord_webhook"
    let description = """
        Posts a message to a Discord channel via an incoming webhook URL.
        No bot token required — the webhook URL carries the channel identity.
        Configure the webhook URL in environment variable DISCORD_WEBHOOK_URL
        or UserDefaults key "apex.discordWebhookUrl".
        """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Message content to post to Discord (supports basic markdown)")
        var message: String

        @Guide(description: "Optional username to display as the webhook sender")
        var username: String?

        @Guide(description: "Optional avatar URL for the webhook sender")
        var avatarUrl: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let urlString = ProcessInfo.processInfo.environment["DISCORD_WEBHOOK_URL"]
                ?? UserDefaults.standard.string(forKey: "apex.discordWebhookUrl")
            guard let urlString, let url = URL(string: urlString) else {
                throw NSError(domain: "DiscordWebhook", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No webhook URL configured. Set DISCORD_WEBHOOK_URL env var or apex.discordWebhookUrl in UserDefaults."])
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10

            var payload: [String: Any] = ["content": arguments.message]
            if let username = arguments.username, !username.isEmpty {
                payload["username"] = username
            }
            if let avatarUrl = arguments.avatarUrl, !avatarUrl.isEmpty {
                payload["avatar_url"] = avatarUrl
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "DiscordWebhook", code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Discord webhook POST failed with status \(statusCode)"])
            }

            return "✅ Message posted to Discord via webhook."
        }
    }

    private func getWebhookUrl() -> String? {
        ProcessInfo.processInfo.environment["DISCORD_WEBHOOK_URL"]
            ?? UserDefaults.standard.string(forKey: "apex.discordWebhookUrl")
    }
}
