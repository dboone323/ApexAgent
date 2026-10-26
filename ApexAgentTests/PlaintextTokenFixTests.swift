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
}
