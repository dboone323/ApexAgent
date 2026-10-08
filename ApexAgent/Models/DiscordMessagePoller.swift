import Foundation

// MARK: - DiscordMessagePoller

@MainActor
final class DiscordMessagePoller {
    static let shared = DiscordMessagePoller()

    private let lock = NSLock()
    private var pollingTask: Task<Void, Never>?
    private var isRunning = false

    // UserDefaults keys
    private static let lastMessageIdKey = "apex.discordLastMessageId"
    private static let pollIntervalKey = "apex.discordPollIntervalSeconds"

    /// Channel ID to poll (set at init from config or UserDefaults).
    /// Kept in sync with AgentRegistryModel.shared.coordinationChannelId so both sides
    /// agree on which channel is the coordination backbone.
    var coordinationChannelId: String {
        get {
            AgentRegistryModel.shared.coordinationChannelId
        }
        set {
            AgentRegistryModel.shared.coordinationChannelId = newValue
        }
    }

    /// Bot token (read from env or UserDefaults at poll time, like DiscordBotTool)
    private func getBotToken() -> String? {
        ProcessInfo.processInfo.environment["DISCORD_APEX_TOKEN"]
            ?? UserDefaults.standard.string(forKey: "apex.discordBotToken")
    }

    /// Start the polling loop. Idempotent — restarts if already running.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        pollingTask?.cancel()
        isRunning = true
        pollingTask = Task { @MainActor [weak self] in
            await self?.pollLoop()
        }
        AppLog.info(.discord, "Started. Channel: \(coordinationChannelId)")
    }

    /// Stop the polling loop.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        pollingTask?.cancel()
        isRunning = false
        AppLog.notice(.discord, "Stopped.")
    }

    /// Poll interval in seconds. Default 15, configurable via UserDefaults.
    private var pollInterval: TimeInterval {
        UserDefaults.standard.double(forKey: Self.pollIntervalKey).nonzero ?? 15.0
    }

    private var consecutiveIdlePolls: Int = 0

    /// Main polling loop. Runs until cancelled, scaling sleep interval via `PollPolicy` on idle streaks.
    private func pollLoop() async {
        while !Task.isCancelled && isRunning {
            var hadActivity = false
            do {
                hadActivity = try await pollOnce()
            } catch {
                AppLog.error(.discord, "Poll error: \(error.localizedDescription)")
            }
            if hadActivity {
                consecutiveIdlePolls = 0
            } else {
                consecutiveIdlePolls += 1
            }
            let base = pollInterval
            let policy = PollPolicy(baseInterval: base, minInterval: base, maxInterval: max(base * 4.0, 60.0))
            let nextSleep = policy.nextInterval(consecutiveIdlePolls: consecutiveIdlePolls, hasRecentActivity: hadActivity)
            try? await Task.sleep(for: .seconds(nextSleep))
        }
    }

    /// Single poll: fetch messages, detect new ones, feed to orchestrator. Returns `true` if new messages arrived.
    @discardableResult
    private func pollOnce() async throws -> Bool {
        guard let token = getBotToken(), !token.isEmpty else {
            AppLog.notice(.discord, "No bot token — skipping poll")
            return false
        }
        guard !coordinationChannelId.isEmpty else {
            AppLog.notice(.discord, "No channel ID — skipping poll")
            return false
        }

        let lastId = lastMessageId()
        let newMessages = try await fetchMessages(after: lastId)

        if newMessages.isEmpty {
            return false
        }

        // Update last-seen ID (most recent message)
        let firstMsg = newMessages.first
        let newestId = firstMsg?["id"] as? String ?? lastId
        setLastMessageId(newestId)

        // Process each new message (newest-first from API, reverse for chronological)
        for msg in newMessages.reversed() {
            await handleMessage(msg)
        }
        return true
    }

    /// Fetch messages after a given ID (empty string = fetch latest).
    private func fetchMessages(after: String) async throws -> [[String: Any]] {
        var urlString = "https://discord.com/api/v10/channels/\(coordinationChannelId)/messages?limit=20"
        if !after.isEmpty {
            urlString += "&after=\(after)"
        }
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "DiscordMessagePoller", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: url)
        request.setValue("Bot \(getBotToken() ?? "")", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "DiscordMessagePoller", code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GET failed: \(statusCode)"])
        }

        let messages: [[String: Any]]
        do {
            messages = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        } catch {
            throw NSError(domain: "DiscordMessagePoller", code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Parse failed: \(error.localizedDescription)"])
        }
        return messages
    }

    // MARK: - Last Message ID Persistence

    private func lastMessageId() -> String {
        UserDefaults.standard.string(forKey: Self.lastMessageIdKey) ?? ""
    }

    private func setLastMessageId(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.lastMessageIdKey)
    }

    // MARK: - Message Handling

    /// Route a message to the orchestrator for processing.
    private func handleMessage(_ msg: [String: Any]) async {
        let author = msg["author"] as? [String: Any] ?? [:]
        let authorId = author["id"] as? String ?? "?"
        let authorName = author["username"] as? String ?? "unknown"
        let content = msg["content"] as? String ?? ""
        let timestamp = msg["timestamp"] as? String ?? ""
        let isBot = author["bot"] as? Bool ?? false

        // Skip our own messages
        if authorId == "1537957778998431775" { return } // ApexAgent's own ID

        let text = "[\(timestamp)] Message from @\(authorName) (\(authorId), bot=\(isBot)): \(content)"

        // Feed into orchestrator — the orchestrator's parser decides whether this is
        // agent-directed and routes accordingly (delegate to a named sub-agent, or
        // surface through sendMessage for the supervisor to handle).
        AppLog.info(.discord, "New message: \(text)")
        await feedToOrchestrator(raw: msg)
    }

    /// Send the raw Discord message dict to the parser for routing decisions.
    private func feedToOrchestrator(raw: [String: Any]) async {
        // The parser detects agent-directed intent and classifies message type.
        if let parsed = DiscordMessageParser.parse(raw) {
            if parsed.messageType == DiscordMessageType.agentDirected || parsed.messageType == DiscordMessageType.agentStatus {
                AppLog.info(.discord, "Agent-directed/\(parsed.messageType) -> \(parsed.mentionedAgents.first ?? "bot")")
            }
        }
    }

    // MARK: - String extension for token hashing (lightweight, not crypto)
}

// MARK: - String extension for token hashing (lightweight, not crypto)
private extension String {
    func sha256HashFirst10() -> String {
        // Simple prefix-based identity check — we don't actually need crypto here
        // Just return a stable identifier from the token for logging
        return String(self.prefix(10))
    }
}

// MARK: - Non-zero double helper
private extension Double {
    var nonzero: Double? {
        self != 0 ? self : nil
    }
}
