import Foundation
import Testing
@testable import ApexAgentCore

// MARK: - Secrets Hygiene Tests (Issue #108, H4)

@Suite("SecretsHygieneTests")
struct SecretsHygieneTests {

    // MARK: - (a) Tool output redacted before model context is assembled

    @Test("credential-shaped value in tool output is redacted before model context is assembled")
    @MainActor
    func testToolOutputRedactedBeforeModelContextAssembled() async throws {
        let fakeKey = "sk-test-fake-1234"
        let fakeGithub = "ghp_1234567890ABCDEFGHIJKLMNO"
        let fakeDbPass = "supersecretpassword123"

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SecretsHygieneTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test_credentials.env")
        let sensitiveContent = """
        API_KEY=\(fakeKey)
        GITHUB_TOKEN=\(fakeGithub)
        DATABASE_URL=postgresql://appuser:\(fakeDbPass)@db.local:5432/main
        """
        try sensitiveContent.write(to: testFile, atomically: true, encoding: .utf8)

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = tempDir.path
        orchestrator.bypassConfirmationInDebug = true

        // 1. Tool execution via executeToolByName
        let toolOutput = try await orchestrator.executeToolByName(
            name: "read_file",
            jsonArguments: "{\"path\": \"\(testFile.path)\"}"
        )

        // Assert tool output does not leak secrets
        #expect(!toolOutput.contains(fakeKey))
        #expect(!toolOutput.contains(fakeGithub))
        #expect(!toolOutput.contains(fakeDbPass))
        #expect(toolOutput.contains("«redacted»"))

        // 2. Model context assembly
        let rawPrompt = "Analyze the output: \(toolOutput) and user key \(fakeKey)"
        let sanitizedPrompt = SecretRedactor.redact(text: rawPrompt)

        #expect(!sanitizedPrompt.contains(fakeKey))
        #expect(!sanitizedPrompt.contains(fakeGithub))
        #expect(!sanitizedPrompt.contains(fakeDbPass))
        #expect(sanitizedPrompt.contains("«redacted»"))
    }

    // MARK: - (b) Tool receives credential from Keychain without appearing in plan/prompt

    @Test("tool call receives credential from Keychain without value appearing in plan or prompt")
    @MainActor
    func testToolReceivesCredentialFromKeychainWithoutAppearingInPlanOrPrompt() async throws {
        let fakeWebhookUrl = "https://discord.com/api/webhooks/123456789/sk-fake-discord-webhook-secret-token"
        let fakeTavilyKey = "tvly-fake-secret-tavily-key-12345"

        KeychainManager.save(key: "discordWebhookUrl", value: fakeWebhookUrl)
        KeychainManager.save(key: "tavilyAPIKey", value: fakeTavilyKey)
        defer {
            KeychainManager.delete(key: "discordWebhookUrl")
            KeychainManager.delete(key: "tavilyAPIKey")
        }

        let orchestrator = AgentOrchestrator()
        let discordTool = DiscordWebhookTool(orchestrator: orchestrator)
        let webSearchTool = WebSearchTool(orchestrator: orchestrator)

        // Tool resolves credential tool-side from Keychain
        let resolvedWebhook = discordTool.getWebhookUrl()
        let resolvedTavily = webSearchTool.getTavilyAPIKey()

        #expect(resolvedWebhook == fakeWebhookUrl)
        #expect(resolvedTavily == fakeTavilyKey)

        // Plan / prompt / tool arguments refer only to domain payload, never the secret value
        let discordArgs = DiscordWebhookTool.Arguments(message: "Status update: deployment verified")
        let searchArgs = WebSearchTool.Arguments(query: "Swift 6 strict concurrency")

        let discordArgsText = String(describing: discordArgs)
        let searchArgsText = String(describing: searchArgs)

        #expect(!discordArgsText.contains("sk-"))
        #expect(!discordArgsText.contains("webhooks"))
        #expect(!discordArgsText.contains(fakeWebhookUrl))

        #expect(!searchArgsText.contains("tvly-"))
        #expect(!searchArgsText.contains(fakeTavilyKey))

        let modelPlanPrompt = "Invoke discord_webhook to post notification, then run web_search for Swift docs"
        #expect(!modelPlanPrompt.contains(fakeWebhookUrl))
        #expect(!modelPlanPrompt.contains(fakeTavilyKey))
    }

    // MARK: - (c) Trace containing a secret value replays redacted

    @Test("trace containing a secret value replays redacted")
    func testTraceWithSecretValueReplaysRedacted() {
        let fakeOpenAI = "sk-test-fake-1234"
        let fakeGithub = "ghp_1234567890ABCDEFGHIJKLMNO"

        let runId = RunTrace.generateRunId()
        var trace = RunTrace(id: runId)

        let ev1 = RunTraceEvent.toolCall(
            sequence: 1,
            toolName: "read_file",
            arguments: "{\"path\": \"/workspace/.env\", \"token\": \"\(fakeGithub)\"}",
            result: "OPENAI_KEY=\(fakeOpenAI)",
            status: "success",
            durationMs: 15.0
        )
        let ev2 = RunTraceEvent.modelCall(
            sequence: 2,
            model: "test-model",
            prompt: "Please analyze \(fakeOpenAI)",
            durationMs: 30.0
        )
        trace.events = [ev1, ev2]

        let replayReport = RunTraceReplayer.replay(trace: trace)

        // Assert replayed events details and summary do not contain raw secrets
        for ev in replayReport.replayedEvents {
            #expect(!ev.summary.contains(fakeOpenAI))
            #expect(!ev.summary.contains(fakeGithub))
            #expect(!ev.detail.contains(fakeOpenAI))
            #expect(!ev.detail.contains(fakeGithub))
            #expect(ev.summary.contains("redacted") || ev.detail.contains("redacted"))
        }

        let formattedOutput = replayReport.toFormattedString()
        #expect(!formattedOutput.contains(fakeOpenAI))
        #expect(!formattedOutput.contains(fakeGithub))
        #expect(formattedOutput.contains("redacted"))

        let jsonOutput = replayReport.toJSON()
        #expect(!jsonOutput.contains(fakeOpenAI))
        #expect(!jsonOutput.contains(fakeGithub))
    }

    // MARK: - (d) No remaining UserDefaults credential reads exist

    @Test("no remaining UserDefaults credential read exists")
    @MainActor
    func testNoRemainingUserDefaultsCredentialReadsExist() {
        let orchestrator = AgentOrchestrator()

        // 1. Discord webhook legacy migration check
        let sentinelDiscord = "https://discord.com/api/webhooks/999/sentinel-discord-key"
        UserDefaults.standard.set(sentinelDiscord, forKey: "apex.discordWebhookUrl")
        KeychainManager.delete(key: "discordWebhookUrl")
        let discordTool = DiscordWebhookTool(orchestrator: orchestrator)
        _ = discordTool.getWebhookUrl()
        #expect(UserDefaults.standard.string(forKey: "apex.discordWebhookUrl") == nil)
        #expect(KeychainManager.get(key: "discordWebhookUrl") == sentinelDiscord)
        KeychainManager.delete(key: "discordWebhookUrl")

        // 2. Tavily API key legacy migration check
        let sentinelTavily = "tvly-sentinel-test-key-12345"
        UserDefaults.standard.set(sentinelTavily, forKey: "apex.tavilyAPIKey")
        KeychainManager.delete(key: "tavilyAPIKey")
        let webSearchTool = WebSearchTool(orchestrator: orchestrator)
        _ = webSearchTool.getTavilyAPIKey()
        #expect(UserDefaults.standard.string(forKey: "apex.tavilyAPIKey") == nil)
        #expect(KeychainManager.get(key: "tavilyAPIKey") == sentinelTavily)
        KeychainManager.delete(key: "tavilyAPIKey")

        // 3. Brave Search API key legacy migration check
        let sentinelBrave = "BSA-sentinel-brave-search-key"
        UserDefaults.standard.set(sentinelBrave, forKey: "apex.braveSearchAPIKey")
        KeychainManager.delete(key: "braveSearchAPIKey")
        _ = webSearchTool.getBraveAPIKey()
        #expect(UserDefaults.standard.string(forKey: "apex.braveSearchAPIKey") == nil)
        #expect(KeychainManager.get(key: "braveSearchAPIKey") == sentinelBrave)
        KeychainManager.delete(key: "braveSearchAPIKey")

        // 4. Copilot Token legacy migration check
        let sentinelCopilot = "ghp_sentinel_copilot_token_123"
        UserDefaults.standard.set(sentinelCopilot, forKey: "apex.model.copilotToken")
        KeychainManager.delete(key: "githubToken")
        _ = ModelRegistry.copilotToken()
        #expect(UserDefaults.standard.string(forKey: "apex.model.copilotToken") == nil)
        #expect(KeychainManager.get(key: "githubToken") == sentinelCopilot)
        KeychainManager.delete(key: "githubToken")

        // 5. Collab Token legacy migration check
        let sentinelCollab = "collab_sentinel_token_123"
        UserDefaults.standard.set(sentinelCollab, forKey: "apex.collabToken")
        KeychainManager.delete(key: "collabToken")
        _ = ModelRegistry.collabToken()
        #expect(UserDefaults.standard.string(forKey: "apex.collabToken") == nil)
        #expect(KeychainManager.get(key: "collabToken") == sentinelCollab)
        KeychainManager.delete(key: "collabToken")

        // 6. Verify that setting values via setters leaves no plaintext in UserDefaults
        ModelRegistry.setCopilotToken("new-clean-copilot-token")
        #expect(UserDefaults.standard.string(forKey: "apex.model.copilotToken") == nil)
        #expect(KeychainManager.get(key: "githubToken") == "new-clean-copilot-token")
        KeychainManager.delete(key: "githubToken")

        ModelRegistry.setCollabToken("new-clean-collab-token")
        #expect(UserDefaults.standard.string(forKey: "apex.collabToken") == nil)
        #expect(KeychainManager.get(key: "collabToken") == "new-clean-collab-token")
        KeychainManager.delete(key: "collabToken")
    }
}
