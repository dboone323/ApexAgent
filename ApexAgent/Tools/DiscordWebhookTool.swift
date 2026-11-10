import Foundation
import FoundationModels

// MARK: - Discord Webhook Post Tool
// Posts messages to a Discord channel via incoming webhook URL.
// No bot token needed — webhook URLs are channel-specific and carry
// the channel's identity. Configure WEBHOOK_URL in environment or
// Keychain (key: "discordWebhookUrl").
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
        or Keychain (key: "discordWebhookUrl").
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
            let urlString = getWebhookUrl()
            guard let urlString, let url = URL(string: urlString) else {
                throw NSError(domain: "DiscordWebhook", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No webhook URL configured. Set DISCORD_WEBHOOK_URL env var or configure in Keychain."])
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

    private func migrateWebhookUrlIfNeeded() {
        let defaults = UserDefaults.standard
        let legacyKey = "apex.discordWebhookUrl"
        guard let legacy = defaults.string(forKey: legacyKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty else {
            return
        }
        if let existing = KeychainManager.get(key: "discordWebhookUrl"), !existing.isEmpty {
            defaults.removeObject(forKey: legacyKey)
            return
        }
        guard KeychainManager.save(key: "discordWebhookUrl", value: legacy) else {
            AppLog.error(.discord, "Discord webhook URL migration from UserDefaults to Keychain failed; legacy entry was retained.")
            return
        }
        defaults.removeObject(forKey: legacyKey)
    }

    func getWebhookUrl() -> String? {
        migrateWebhookUrlIfNeeded()
        if let envUrl = ProcessInfo.processInfo.environment["DISCORD_WEBHOOK_URL"], !envUrl.isEmpty {
            return envUrl
        }
        if let keychainUrl = KeychainManager.get(key: "discordWebhookUrl"), !keychainUrl.isEmpty {
            return keychainUrl
        }
        return nil
    }
}
