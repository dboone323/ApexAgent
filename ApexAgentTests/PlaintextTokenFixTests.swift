import XCTest
@testable import ApexAgentCore

final class PlaintextTokenFixTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainManager.delete(key: "githubToken")
        KeychainManager.delete(key: "collabToken")
        UserDefaults.standard.removeObject(forKey: "apex.model.copilotToken")
        UserDefaults.standard.removeObject(forKey: "apex.collabToken")
    }
    func testCopilotTokenMigratesFromUserDefaultsToKeychain() {
        let legacy = "ghp_test_copilot_token_123"
        UserDefaults.standard.set(legacy, forKey: "apex.model.copilotToken")
        // Trigger migration
        let resolved = ModelRegistry.copilotToken()
        XCTAssertEqual(resolved, legacy)
        XCTAssertNil(UserDefaults.standard.string(forKey: "apex.model.copilotToken"))
        XCTAssertEqual(KeychainManager.get(key: "githubToken"), legacy)
    }

    func testCollabTokenMigratesFromUserDefaultsToKeychain() {
        let legacy = "collab-legacy-token-456"
        UserDefaults.standard.set(legacy, forKey: "apex.collabToken")
        let resolved = ModelRegistry.collabToken()
        XCTAssertEqual(resolved, legacy)
        XCTAssertNil(UserDefaults.standard.string(forKey: "apex.collabToken"))
        XCTAssertEqual(KeychainManager.get(key: "collabToken"), legacy)
    }

    func testSetCopilotTokenDoesNotLeavePlaintext() {
        ModelRegistry.setCopilotToken("new-copilot-token")
        XCTAssertNil(UserDefaults.standard.string(forKey: "apex.model.copilotToken"))
        XCTAssertEqual(KeychainManager.get(key: "githubToken"), "new-copilot-token")
    }

    @MainActor
    func testGitHubToolAuthTokenSubActionIsDenied() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = GitHubTool(orchestrator: orchestrator)
        let args = GitHubTool.Arguments(
            action: "auth",
            subAction: "token",
            repo: nil,
            number: nil,
            title: nil,
            body: nil,
            labels: nil,
            assignees: nil,
            state: nil,
            limit: nil,
            endpoint: nil,
            method: nil
        )
        let result = try await tool.call(arguments: args)
        // Must be denied and must not leak a raw token.
        XCTAssertTrue(result.contains("disabled to prevent token leakage"),
                      "Expected denial, got: \(result)")
        XCTAssertFalse(result.contains("ghp_"))
        XCTAssertFalse(result.lowercased().contains("gh auth token"))
    }

    // MARK: - Issue #121: Keychain Credential Migration Tests

    @MainActor
    func testDiscordWebhookUrlMigratesFromUserDefaultsToKeychain() {
        let sentinelUrl = "https://example.invalid/fake-webhook-for-tests"
        UserDefaults.standard.set(sentinelUrl, forKey: "apex.discordWebhookUrl")
        KeychainManager.delete(key: "discordWebhookUrl")
        defer {
            UserDefaults.standard.removeObject(forKey: "apex.discordWebhookUrl")
            KeychainManager.delete(key: "discordWebhookUrl")
        }

        let orchestrator = AgentOrchestrator()
        let tool = DiscordWebhookTool(orchestrator: orchestrator)

        // Trigger migration via getter
        let resolved = tool.getWebhookUrl()

        // 1. Value is returned/available from new store (Keychain)
        XCTAssertEqual(resolved, sentinelUrl)
        XCTAssertEqual(KeychainManager.get(key: "discordWebhookUrl"), sentinelUrl)

        // 2. Legacy UserDefaults key is deleted
        XCTAssertNil(UserDefaults.standard.string(forKey: "apex.discordWebhookUrl"))

        // 3. Pre-existing Keychain value is never overwritten by a legacy one
        let preExistingKeychain = "https://example.invalid/pre-existing-keychain-webhook"
        KeychainManager.save(key: "discordWebhookUrl", value: preExistingKeychain)
        let newLegacyValue = "https://example.invalid/new-legacy-webhook"
        UserDefaults.standard.set(newLegacyValue, forKey: "apex.discordWebhookUrl")

        let secondResolved = tool.getWebhookUrl()
        XCTAssertEqual(secondResolved, preExistingKeychain)
        XCTAssertEqual(KeychainManager.get(key: "discordWebhookUrl"), preExistingKeychain)
        XCTAssertNil(UserDefaults.standard.string(forKey: "apex.discordWebhookUrl"))
    }

    @MainActor
    func testTavilyAPIKeyMigratesFromUserDefaultsToKeychain() {
        let sentinelKey = "fake-tavily-key-for-tests"
        UserDefaults.standard.set(sentinelKey, forKey: "apex.tavilyAPIKey")
        KeychainManager.delete(key: "tavilyAPIKey")
        defer {
            UserDefaults.standard.removeObject(forKey: "apex.tavilyAPIKey")
            KeychainManager.delete(key: "tavilyAPIKey")
        }

        let orchestrator = AgentOrchestrator()
        let tool = WebSearchTool(orchestrator: orchestrator)

        // Trigger migration via getter
        let resolved = tool.getTavilyAPIKey()

        // 1. Value is returned/available from new store (Keychain)
        XCTAssertEqual(resolved, sentinelKey)
        XCTAssertEqual(KeychainManager.get(key: "tavilyAPIKey"), sentinelKey)

        // 2. Legacy UserDefaults key is deleted
        XCTAssertNil(UserDefaults.standard.string(forKey: "apex.tavilyAPIKey"))

        // 3. Pre-existing Keychain value is never overwritten by a legacy one
        let preExistingKeychain = "pre-existing-tavily-keychain-val"
        KeychainManager.save(key: "tavilyAPIKey", value: preExistingKeychain)
        let newLegacyValue = "new-legacy-tavily-val"
        UserDefaults.standard.set(newLegacyValue, forKey: "apex.tavilyAPIKey")

        let secondResolved = tool.getTavilyAPIKey()
        XCTAssertEqual(secondResolved, preExistingKeychain)
        XCTAssertEqual(KeychainManager.get(key: "tavilyAPIKey"), preExistingKeychain)
        XCTAssertNil(UserDefaults.standard.string(forKey: "apex.tavilyAPIKey"))
    }

    @MainActor
    func testBraveAPIKeyMigratesFromUserDefaultsToKeychain() {
        let sentinelKey = "fake-brave-key-for-tests"
        UserDefaults.standard.set(sentinelKey, forKey: "apex.braveSearchAPIKey")
        KeychainManager.delete(key: "braveSearchAPIKey")
        defer {
            UserDefaults.standard.removeObject(forKey: "apex.braveSearchAPIKey")
            KeychainManager.delete(key: "braveSearchAPIKey")
        }

        let orchestrator = AgentOrchestrator()
        let tool = WebSearchTool(orchestrator: orchestrator)

        // Trigger migration via getter
        let resolved = tool.getBraveAPIKey()

        // 1. Value is returned/available from new store (Keychain)
        XCTAssertEqual(resolved, sentinelKey)
        XCTAssertEqual(KeychainManager.get(key: "braveSearchAPIKey"), sentinelKey)

        // 2. Legacy UserDefaults key is deleted
        XCTAssertNil(UserDefaults.standard.string(forKey: "apex.braveSearchAPIKey"))

        // 3. Pre-existing Keychain value is never overwritten by a legacy one
        let preExistingKeychain = "pre-existing-brave-keychain-val"
        KeychainManager.save(key: "braveSearchAPIKey", value: preExistingKeychain)
        let newLegacyValue = "new-legacy-brave-val"
        UserDefaults.standard.set(newLegacyValue, forKey: "apex.braveSearchAPIKey")

        let secondResolved = tool.getBraveAPIKey()
        XCTAssertEqual(secondResolved, preExistingKeychain)
        XCTAssertEqual(KeychainManager.get(key: "braveSearchAPIKey"), preExistingKeychain)
        XCTAssertNil(UserDefaults.standard.string(forKey: "apex.braveSearchAPIKey"))
    }
}
